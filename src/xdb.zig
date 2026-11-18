//! ip2region xdb v3 读取器（IPv4 / IPv6；Vector / BTree 索引）。
//!
//! ## 文件布局（xdb v3，2025-09 起）
//!
//! | 段 | 大小 | 说明 |
//! |----|------|------|
//! | Header | 256 B | 版本/索引策略/索引起止/IP 版本/指针宽度 |
//! | Vector Index | 512 KiB | 256 × 256 个 `(start_ptr, end_ptr)`，按 IP 前两字节分桶 |
//! | Region Data | 动态 | 去重后的地域字符串（UTF-8） |
//! | Segment Index | 动态 | 二分索引记录（IPv4 14 B / IPv6 38 B） |
//!
//! Header 字段（小端）：`version u16`、`policy u16`、`create_time u32`、
//! `start_index_ptr u32`、`end_index_ptr u32`、`ip_version u16`、`runtime_ptr_bytes u16`。
//!
//! ## 性能取向（相对 Rust 版）
//!
//! - 默认 **mmap 只读映射**（`File.createMemoryMap`），v6 库 37 MiB 不占进程常驻私有内存，
//!   多进程共享同一份页缓存；Windows / POSIX 均由 std 的 `Io` 后端实现（可 `disable_memory_mapping` 退化为普通读）。
//! - 查询**零分配**：`lookup` 返回指向映射数据的切片，不构造 String。
//! - 单次查询 = 一次向量桶定位 + ≤ ceil(log2(桶内记录数)) 次二分，无锁、可跨线程共享。

const std = @import("std");
const ip_mod = @import("ip.zig");
const blob_mod = @import("blob.zig");
const IpAddr = ip_mod.IpAddr;

/// Header 长度。
pub const HEADER_LEN: usize = 256;
const VECTOR_COLS: usize = 256;
const VECTOR_ROWS: usize = 256;
const VECTOR_ENTRY_LEN: usize = 8;
/// 向量索引总长度（512 KiB）。
pub const VECTOR_LEN: usize = VECTOR_COLS * VECTOR_ROWS * VECTOR_ENTRY_LEN;
/// 地域数据段起始偏移（Header + Vector Index）。
pub const REGION_START: usize = HEADER_LEN + VECTOR_LEN;
/// IPv4 二分索引记录长度：start 4 + end 4 + len 2 + ptr 4。
pub const RECORD_LEN_V4: usize = 14;
/// IPv6 二分索引记录长度：start 16 + end 16 + len 2 + ptr 4。
pub const RECORD_LEN_V6: usize = 38;
const XDB_VERSION: u16 = 3;
const POLICY_VECTOR: u16 = 1;
const POLICY_BTREE: u16 = 2;
const PTR_BYTES: u16 = 4;

/// xdb 的 IP 版本。
pub const IpVersion = enum {
    v4,
    v6,

    pub fn ipBytes(self: IpVersion) usize {
        return switch (self) {
            .v4 => 4,
            .v6 => 16,
        };
    }

    pub fn recordLen(self: IpVersion) usize {
        return switch (self) {
            .v4 => RECORD_LEN_V4,
            .v6 => RECORD_LEN_V6,
        };
    }

    pub fn asStr(self: IpVersion) []const u8 {
        return switch (self) {
            .v4 => "IPv4",
            .v6 => "IPv6",
        };
    }
};

/// 索引策略。
pub const IndexPolicy = enum {
    vector,
    btree,

    pub fn asStr(self: IndexPolicy) []const u8 {
        return switch (self) {
            .vector => "VectorIndex",
            .btree => "BTreeIndex",
        };
    }
};

/// 打开/解析错误（文案由调用方补齐路径上下文）。
pub const Error = error{
    /// 文件不存在
    MissingFile,
    /// 文件过小（不足 256 KiB + 256 B）
    FileTooSmall,
    /// 版本不是 v3
    UnsupportedVersion,
    /// 未知索引策略
    UnknownPolicy,
    /// 未知 IP 版本
    UnknownIpVersion,
    /// 索引指针宽度不是 4 字节
    UnsupportedPtrBytes,
    /// 索引起止非法 / 未对齐 / 越界
    BadIndex,
    /// 查询时记录越界或数据不属于 UTF-8
    CorruptRecord,
    /// 文件读入内存失败
    ReadFailed,
    /// mmap 失败
    MapFailed,
    /// 空文件
    EmptyFile,
};

/// 解析出来的 Header。
pub const Header = struct {
    version: u16,
    policy: IndexPolicy,
    create_time: u32,
    start_index: usize,
    end_index: usize,
    ip_version: IpVersion,
};

const Storage = union(enum) {
    borrowed,
    owned: []u8,
    mapped: struct {
        mm: std.Io.File.MemoryMap,
        io: std.Io,
    },
};

/// xdb 读取器（构造后只读，可跨线程共享）。
pub const XdbReader = struct {
    blob: blob_mod.Blob,
    header: Header,

    /// 从文件打开（默认 mmap 只读映射）。
    pub fn open(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !XdbReader {
        return openWith(io, gpa, path, .{});
    }

    pub const OpenOptions = struct {
        /// 不映射，整文件读入堆内存（便于调试 / 受限环境）。
        no_mmap: bool = false,
    };

    /// 从文件打开（可控制是否使用 mmap）。
    pub fn openWith(io: std.Io, gpa: std.mem.Allocator, path: []const u8, options: OpenOptions) !XdbReader {
        var blob = blob_mod.Blob.open(io, gpa, path, .{ .no_mmap = options.no_mmap }) catch |err| switch (err) {
            error.MissingFile => return Error.MissingFile,
            error.EmptyFile => return Error.EmptyFile,
            error.ReadFailed => return Error.ReadFailed,
        };
        errdefer blob.deinit();
        return .{
            .blob = blob,
            .header = try parseHeader(blob.bytes),
        };
    }

    /// 从已有字节构造（借用，不接管所有权；用于测试或上层自行加载）。
    pub fn fromBytes(bytes: []const u8) !XdbReader {
        return .{
            .blob = blob_mod.Blob.borrow(bytes),
            .header = try parseHeader(bytes),
        };
    }

    pub fn deinit(self: *XdbReader) void {
        self.blob.deinit();
    }

    pub fn version(self: XdbReader) u16 {
        return self.header.version;
    }

    pub fn policy(self: XdbReader) IndexPolicy {
        return self.header.policy;
    }

    pub fn ipVersion(self: XdbReader) IpVersion {
        return self.header.ip_version;
    }

    pub fn createTime(self: XdbReader) u32 {
        return self.header.create_time;
    }

    pub fn len(self: XdbReader) usize {
        return self.blob.bytes.len;
    }

    /// 查询原始地域字符串（如 `中国|福建省|福州市|中国电信|CN`）。
    ///
    /// - 未命中：`null`；
    /// - IP 版本不匹配：`null`；
    /// - 文件损坏：`error.CorruptRecord`。
    pub fn lookup(self: *const XdbReader, ip: IpAddr) Error!?[]const u8 {
        const key = self.keyOf(ip) orelse return null;

        const ip_len = self.header.ip_version.ipBytes();
        const rec_len = self.header.ip_version.recordLen();
        const start_index = self.header.start_index;
        const end_index = self.header.end_index;

        var lo_ptr: usize = undefined;
        var hi_ptr: usize = undefined;
        switch (self.header.policy) {
            .vector => {
                const bucket = self.bucketOf(key);
                const off = HEADER_LEN + bucket * VECTOR_ENTRY_LEN;
                const lo = readU32(self.blob.bytes, off) orelse return Error.CorruptRecord;
                const hi = readU32(self.blob.bytes, off + 4) orelse return Error.CorruptRecord;
                if (lo == 0 or hi == 0) return null; // 生成器约定：全 0 = 该桶无数据
                lo_ptr = lo;
                hi_ptr = hi;
            },
            .btree => {
                lo_ptr = start_index;
                hi_ptr = end_index;
            },
        }

        if (lo_ptr < start_index or hi_ptr < lo_ptr or hi_ptr > end_index or
            (lo_ptr - start_index) % rec_len != 0 or (hi_ptr - start_index) % rec_len != 0)
        {
            return Error.BadIndex;
        }

        var lo = (lo_ptr - start_index) / rec_len;
        var hi = (hi_ptr - start_index) / rec_len;

        while (lo <= hi) {
            const mid = lo + (hi - lo) / 2;
            const offset = start_index + mid * rec_len;
            const rec_start = self.readIp(offset) orelse return Error.CorruptRecord;
            const rec_end = self.readIp(offset + ip_len) orelse return Error.CorruptRecord;

            if (key < rec_start) {
                if (mid == 0) break;
                hi = mid - 1;
            } else if (key > rec_end) {
                lo = mid + 1;
            } else {
                const len_off = offset + ip_len * 2;
                const data_len: usize = readU16(self.blob.bytes, len_off) orelse return Error.CorruptRecord;
                const data_ptr: usize = readU32(self.blob.bytes, len_off + 2) orelse return Error.CorruptRecord;
                if (data_len == 0) return null;
                const data_end = data_ptr + data_len;
                if (data_ptr < REGION_START or data_end > self.blob.bytes.len or data_end < data_ptr) {
                    return Error.CorruptRecord;
                }
                const text = self.blob.bytes[data_ptr..data_end];
                if (!std.unicode.utf8ValidateSlice(text)) return Error.CorruptRecord;
                return text;
            }
        }
        return null;
    }

    /// 查询 IPv4（数值）。
    pub fn lookupV4(self: *const XdbReader, value: u32) Error!?[]const u8 {
        return self.lookup(.{ .v4 = value });
    }

    /// 查询 IPv6（数值）。
    pub fn lookupV6(self: *const XdbReader, value: u128) Error!?[]const u8 {
        return self.lookup(.{ .v6 = value });
    }

    fn keyOf(self: XdbReader, ip: IpAddr) ?u128 {
        return switch (self.header.ip_version) {
            .v4 => switch (ip.normalize()) {
                .v4 => |v| v,
                .v6 => null,
            },
            .v6 => switch (ip.normalize()) {
                .v4 => |v| (@as(u128, 0xffff) << 32) | v,
                .v6 => |v| v,
            },
        };
    }

    fn bucketOf(self: XdbReader, key: u128) usize {
        return switch (self.header.ip_version) {
            .v4 => @intCast((key >> 16) & 0xffff),
            .v6 => @intCast((key >> 112) & 0xffff),
        };
    }

    fn readIp(self: XdbReader, offset: usize) ?u128 {
        return switch (self.header.ip_version) {
            .v4 => if (readU32(self.blob.bytes, offset)) |v| v else null,
            .v6 => blk: {
                const end = offset + 16;
                if (end > self.blob.bytes.len or end < offset) break :blk null;
                const array: *const [16]u8 = self.blob.bytes[offset..end][0..16];
                break :blk std.mem.readInt(u128, array, .big);
            },
        };
    }
};

fn readU16(bytes: []const u8, offset: usize) ?u16 {
    const end = offset + 2;
    if (end > bytes.len or end < offset) return null;
    const array: *const [2]u8 = bytes[offset..end][0..2];
    return std.mem.readInt(u16, array, .little);
}

fn readU32(bytes: []const u8, offset: usize) ?u32 {
    const end = offset + 4;
    if (end > bytes.len or end < offset) return null;
    const array: *const [4]u8 = bytes[offset..end][0..4];
    return std.mem.readInt(u32, array, .little);
}

fn parseHeader(data: []const u8) Error!Header {
    if (data.len < REGION_START) return Error.FileTooSmall;
    const version = readU16(data, 0) orelse return Error.FileTooSmall;
    if (version != XDB_VERSION) return Error.UnsupportedVersion;

    const policy_raw = readU16(data, 2) orelse return Error.FileTooSmall;
    const policy: IndexPolicy = switch (policy_raw) {
        POLICY_VECTOR => .vector,
        POLICY_BTREE => .btree,
        else => return Error.UnknownPolicy,
    };

    const create_time = readU32(data, 4) orelse return Error.FileTooSmall;
    const start_index: usize = readU32(data, 8) orelse return Error.FileTooSmall;
    const end_index: usize = readU32(data, 12) orelse return Error.FileTooSmall;

    const ip_version: IpVersion = switch (readU16(data, 16) orelse return Error.FileTooSmall) {
        4 => .v4,
        6 => .v6,
        else => return Error.UnknownIpVersion,
    };

    if ((readU16(data, 18) orelse return Error.FileTooSmall) != PTR_BYTES) {
        return Error.UnsupportedPtrBytes;
    }

    const rec_len = ip_version.recordLen();
    if (start_index < REGION_START or start_index > end_index) return Error.BadIndex;
    if ((end_index - start_index) % rec_len != 0) return Error.BadIndex;
    if (end_index + rec_len > data.len) return Error.BadIndex;

    return .{
        .version = version,
        .policy = policy,
        .create_time = create_time,
        .start_index = start_index,
        .end_index = end_index,
        .ip_version = ip_version,
    };
}

// ---------------------------------------------------------------------------
// 测试用最小 xdb 构造器（与 Rust `Pek.IP::xdb::tests` 相同的布局）
// ---------------------------------------------------------------------------

const testing = std.testing;

fn writeU16(list: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try list.appendSlice(gpa, &buf);
}

fn writeU32(list: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try list.appendSlice(gpa, &buf);
}

pub const TestRecordV4 = struct { start: u32, end: u32, region: []const u8 };
pub const TestRecordV6 = struct { start: u128, end: u128, region: []const u8 };

/// 构造一个最小 xdb v3（IPv4）。
pub fn buildXdbV4(gpa: std.mem.Allocator, records: []const TestRecordV4, policy: u16) ![]u8 {
    var region_data: std.ArrayList(u8) = .empty;
    defer region_data.deinit(gpa);
    var pointers: [32]struct { region: []const u8, ptr: u32 } = undefined;
    var pointer_count: usize = 0;
    var cursor: u32 = @intCast(REGION_START);
    for (records) |rec| {
        var found = false;
        for (pointers[0..pointer_count]) |p| {
            if (std.mem.eql(u8, p.region, rec.region)) {
                found = true;
                break;
            }
        }
        if (!found) {
            pointers[pointer_count] = .{ .region = rec.region, .ptr = cursor };
            pointer_count += 1;
            try region_data.appendSlice(gpa, rec.region);
            cursor += @intCast(rec.region.len);
        }
    }
    const start_index: u32 = @intCast(REGION_START + region_data.items.len);
    const end_index: u32 = start_index + @as(u32, @intCast((records.len - 1) * RECORD_LEN_V4));

    var vector: [VECTOR_LEN]u8 = @splat(0);
    var index: std.ArrayList(u8) = .empty;
    defer index.deinit(gpa);
    for (records) |rec| {
        const ptr: u32 = start_index + @as(u32, @intCast(index.items.len));
        try writeU32(&index, gpa, rec.start);
        try writeU32(&index, gpa, rec.end);
        try writeU16(&index, gpa, @intCast(rec.region.len));
        var region_ptr: u32 = 0;
        for (pointers[0..pointer_count]) |p| {
            if (std.mem.eql(u8, p.region, rec.region)) region_ptr = p.ptr;
        }
        try writeU32(&index, gpa, region_ptr);
        if (policy == POLICY_VECTOR) {
            const bucket: usize = @intCast((rec.start >> 16) & 0xffff);
            const off = bucket * VECTOR_ENTRY_LEN;
            if (std.mem.readInt(u32, vector[off..][0..4], .little) == 0) {
                std.mem.writeInt(u32, vector[off..][0..4], ptr, .little);
            }
            std.mem.writeInt(u32, vector[off + 4 ..][0..4], ptr, .little);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendNTimes(gpa, 0, start_index);
    std.mem.writeInt(u16, out.items[0..2], XDB_VERSION, .little);
    std.mem.writeInt(u16, out.items[2..4], policy, .little);
    std.mem.writeInt(u32, out.items[8..12], start_index, .little);
    std.mem.writeInt(u32, out.items[12..16], end_index, .little);
    std.mem.writeInt(u16, out.items[16..18], 4, .little);
    std.mem.writeInt(u16, out.items[18..20], PTR_BYTES, .little);
    @memcpy(out.items[HEADER_LEN..REGION_START], &vector);
    @memcpy(out.items[REGION_START..start_index], region_data.items);
    try out.appendSlice(gpa, index.items);
    return out.toOwnedSlice(gpa);
}

/// 构造一个最小 xdb v3（IPv6）。
pub fn buildXdbV6(gpa: std.mem.Allocator, records: []const TestRecordV6, policy: u16) ![]u8 {
    var region_data: std.ArrayList(u8) = .empty;
    defer region_data.deinit(gpa);
    var pointers: [32]struct { region: []const u8, ptr: u32 } = undefined;
    var pointer_count: usize = 0;
    var cursor: u32 = @intCast(REGION_START);
    for (records) |rec| {
        var found = false;
        for (pointers[0..pointer_count]) |p| {
            if (std.mem.eql(u8, p.region, rec.region)) {
                found = true;
                break;
            }
        }
        if (!found) {
            pointers[pointer_count] = .{ .region = rec.region, .ptr = cursor };
            pointer_count += 1;
            try region_data.appendSlice(gpa, rec.region);
            cursor += @intCast(rec.region.len);
        }
    }
    const start_index: u32 = @intCast(REGION_START + region_data.items.len);
    const end_index: u32 = start_index + @as(u32, @intCast((records.len - 1) * RECORD_LEN_V6));

    var vector: [VECTOR_LEN]u8 = @splat(0);
    var index: std.ArrayList(u8) = .empty;
    defer index.deinit(gpa);
    for (records) |rec| {
        const ptr: u32 = start_index + @as(u32, @intCast(index.items.len));
        var start_buf: [16]u8 = undefined;
        std.mem.writeInt(u128, &start_buf, rec.start, .big);
        try index.appendSlice(gpa, &start_buf);
        var end_buf: [16]u8 = undefined;
        std.mem.writeInt(u128, &end_buf, rec.end, .big);
        try index.appendSlice(gpa, &end_buf);
        try writeU16(&index, gpa, @intCast(rec.region.len));
        var region_ptr: u32 = 0;
        for (pointers[0..pointer_count]) |p| {
            if (std.mem.eql(u8, p.region, rec.region)) region_ptr = p.ptr;
        }
        try writeU32(&index, gpa, region_ptr);
        if (policy == POLICY_VECTOR) {
            const bucket: usize = @intCast((rec.start >> 112) & 0xffff);
            const off = bucket * VECTOR_ENTRY_LEN;
            if (std.mem.readInt(u32, vector[off..][0..4], .little) == 0) {
                std.mem.writeInt(u32, vector[off..][0..4], ptr, .little);
            }
            std.mem.writeInt(u32, vector[off + 4 ..][0..4], ptr, .little);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendNTimes(gpa, 0, start_index);
    std.mem.writeInt(u16, out.items[0..2], XDB_VERSION, .little);
    std.mem.writeInt(u16, out.items[2..4], policy, .little);
    std.mem.writeInt(u32, out.items[8..12], start_index, .little);
    std.mem.writeInt(u32, out.items[12..16], end_index, .little);
    std.mem.writeInt(u16, out.items[16..18], 6, .little);
    std.mem.writeInt(u16, out.items[18..20], PTR_BYTES, .little);
    @memcpy(out.items[HEADER_LEN..REGION_START], &vector);
    @memcpy(out.items[REGION_START..start_index], region_data.items);
    try out.appendSlice(gpa, index.items);
    return out.toOwnedSlice(gpa);
}

test "IPv4 边界命中（Vector 索引）" {
    const gpa = testing.allocator;
    const records = [_]TestRecordV4{
        .{ .start = 0x0100_0000, .end = 0x0100_00ff, .region = "澳大利亚|昆士兰|0|0|AU" },
        .{ .start = 0x0100_0100, .end = 0x0100_01ff, .region = "中国|福建省|福州市|中国电信|CN" },
        .{ .start = 0x0100_0200, .end = 0x0100_02ff, .region = "美国|德克萨斯州|0|0|US" },
    };
    const data = try buildXdbV4(gpa, &records, POLICY_VECTOR);
    defer gpa.free(data);

    const db = try XdbReader.fromBytes(data);
    try testing.expectEqual(@as(u16, 3), db.version());
    try testing.expectEqual(IndexPolicy.vector, db.policy());
    try testing.expectEqual(IpVersion.v4, db.ipVersion());

    try testing.expectEqualStrings("澳大利亚|昆士兰|0|0|AU", (try db.lookup(try IpAddr.parse("1.0.0.1"))).?);
    try testing.expectEqualStrings("中国|福建省|福州市|中国电信|CN", (try db.lookup(try IpAddr.parse("1.0.1.0"))).?);
    try testing.expectEqualStrings("中国|福建省|福州市|中国电信|CN", (try db.lookup(try IpAddr.parse("1.0.1.255"))).?);
    try testing.expectEqualStrings("美国|德克萨斯州|0|0|US", (try db.lookup(try IpAddr.parse("1.0.2.128"))).?);
    try testing.expect((try db.lookup(try IpAddr.parse("1.0.3.0"))) == null);
    try testing.expect((try db.lookup(try IpAddr.parse("8.8.8.8"))) == null);
}

test "IPv4 BTree 策略" {
    const gpa = testing.allocator;
    const records = [_]TestRecordV4{
        .{ .start = 0x0100_0000, .end = 0x0100_ffff, .region = "A|B|C|D|AA" },
        .{ .start = 0x0200_0000, .end = 0x0200_ffff, .region = "E|F|G|H|BB" },
    };
    const data = try buildXdbV4(gpa, &records, POLICY_BTREE);
    defer gpa.free(data);
    const db = try XdbReader.fromBytes(data);
    try testing.expectEqual(IndexPolicy.btree, db.policy());
    try testing.expectEqualStrings("E|F|G|H|BB", (try db.lookup(try IpAddr.parse("2.0.0.1"))).?);
    try testing.expect((try db.lookup(try IpAddr.parse("3.0.0.1"))) == null);
}

test "IPv6 查询" {
    const gpa = testing.allocator;
    const start: u128 = (try IpAddr.parse("240e:3b7:3273:51d0::")).v6;
    const end: u128 = (try IpAddr.parse("240e:3b7:3273:51ff:ffff:ffff:ffff:ffff")).v6;
    const records = [_]TestRecordV6{
        .{ .start = start, .end = end, .region = "中国|广东省|深圳市|电信|CN" },
    };
    const data = try buildXdbV6(gpa, &records, POLICY_VECTOR);
    defer gpa.free(data);
    const db = try XdbReader.fromBytes(data);
    try testing.expectEqual(IpVersion.v6, db.ipVersion());
    try testing.expectEqualStrings(
        "中国|广东省|深圳市|电信|CN",
        (try db.lookup(try IpAddr.parse("240e:3b7:3273:51d0:cd38:8ae1:e3c0:b708"))).?,
    );
    try testing.expect((try db.lookup(try IpAddr.parse("240e:3b7:3273:5200::"))) == null);
}

test "版本不匹配返回 null" {
    const gpa = testing.allocator;
    const records = [_]TestRecordV4{
        .{ .start = 0x0100_0000, .end = 0x0100_ffff, .region = "A|B|C|D|AA" },
    };
    const data = try buildXdbV4(gpa, &records, POLICY_VECTOR);
    defer gpa.free(data);
    const db = try XdbReader.fromBytes(data);
    try testing.expect((try db.lookup(try IpAddr.parse("2001:db8::1"))) == null);
}

test "拒绝截断或错误版本" {
    const gpa = testing.allocator;
    var tiny: [100]u8 = @splat(0);
    try testing.expectError(Error.FileTooSmall, XdbReader.fromBytes(&tiny));

    const records = [_]TestRecordV4{
        .{ .start = 0x0100_0000, .end = 0x0100_ffff, .region = "A|B|C|D|AA" },
    };
    const data = try buildXdbV4(gpa, &records, POLICY_VECTOR);
    defer gpa.free(data);
    std.mem.writeInt(u16, data[0..2], 2, .little);
    try testing.expectError(Error.UnsupportedVersion, XdbReader.fromBytes(data));
}

test "从真实文件打开（mmap）" {
    // 真实数据可选：没有数据文件时跳过（显式可见，不静默）。
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "G:/Code/Rust/Pek.IP/data/ip2region_v4.xdb";
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
        std.debug.print("[SKIP] 未找到真实 xdb 数据：{s}\n", .{path});
        return;
    };
    file.close(io);

    var db = try XdbReader.open(io, gpa, path);
    defer db.deinit();
    try testing.expectEqual(IpVersion.v4, db.ipVersion());
    const text = (try db.lookup(try IpAddr.parse("114.114.114.114"))).?;
    try testing.expect(text.len > 0);
    std.debug.print("[real xdb] 114.114.114.114 → {s}\n", .{text});
    const qq = (try db.lookup(try IpAddr.parse("223.5.5.5"))).?;
    std.debug.print("[real xdb] 223.5.5.5 → {s}\n", .{qq});
}
