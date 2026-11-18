//! 纯真 QQWry 数据库读取器（C# `DH.NIP` / NewLife.IP 的 `ip.gz` 格式）。
//!
//! ## 文件布局（解压后）
//!
//! ```text
//! [0..4)   索引区起始偏移（通常 8）
//! [4..8)   索引区结束偏移（指向最后一条索引记录首字节）
//! [8..)    索引记录：start_ip u32 小端 + 数据偏移 u24 小端（共 7 字节/条）
//! [..]     数据区：end_ip u32 + 区域串 GBK + 0x00 + 地址串 GBK + 0x00
//! ```
//!
//! 数据串支持两级重定向（首字节标记）：
//! - `0x01`：整个记录指向别处（`value >> 8` 为新偏移）；
//! - `0x02`：只有区域指向别处，地址仍在当前记录后 4 字节处。
//!
//! 本实现与 DH.NIP 语义一致，另外：
//! - 支持 `.gz` 直接加载（`std.compress.flate` 解压，不落临时文件）；
//! - 默认 mmap 只读（非 gz 时），查询零分配；
//! - GBK 串转 UTF-8 写入调用方 scratch，避免每次查询分配。

const std = @import("std");
const blob_mod = @import("blob.zig");
const gbk = @import("gb2312.zig");

/// 打开/解析错误。
pub const Error = error{
    MissingFile,
    EmptyFile,
    ReadFailed,
    /// 文件不是合法的 QQWry 布局
    BadHeader,
    /// 索引/数据区越界或重定向成环
    Corrupt,
    /// gzip 解压失败
    BadGzip,
};

const INDEX_RECORD_LEN: usize = 7;
/// 单条字符串最大字节数（纯真数据里地址串远小于此；防止损坏数据把查询拖死）。
const MAX_STRING_LEN: usize = 512;
/// 重定向最大跟随次数。
const MAX_REDIRECTS: usize = 4;

/// 原始（GBK）记录：切片借用数据库内存。
pub const RawEntry = struct {
    area: []const u8 = "",
    addr: []const u8 = "",
};

/// UTF-8 记录：切片指向调用方 `Scratch`。
pub const Entry = struct {
    area: []const u8 = "",
    addr: []const u8 = "",
};

/// 单线程查询缓冲（每个线程一个，`256` 字节足够放「中国–广东省–深圳市 + 运营商」）。
pub const Scratch = struct {
    buf: [512]u8 = undefined,
};

/// QQWry 读取器（构造后只读，可跨线程共享）。
pub const QqwryReader = struct {
    blob: blob_mod.Blob,
    /// gzip 解压结果（拥有）；非 gz 时为 null。
    decompressed: ?[]u8,
    gpa: ?std.mem.Allocator,
    index_start: u32,
    index_end: u32,
    count: u32,

    /// 打开文件（自动识别 `.gz`）。
    pub fn open(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !QqwryReader {
        var blob = blob_mod.Blob.open(io, gpa, path, .{}) catch |err| switch (err) {
            error.MissingFile => return Error.MissingFile,
            error.EmptyFile => return Error.EmptyFile,
            error.ReadFailed => return Error.ReadFailed,
        };

        if (blob.bytes.len >= 2 and blob.bytes[0] == 0x1f and blob.bytes[1] == 0x8b) {
            const data = decompressGzip(gpa, blob.bytes) catch {
                blob.deinit();
                return Error.BadGzip;
            };
            blob.deinit();
            var reader = try fromBytesOwned(data, gpa);
            reader.decompressed = data;
            return reader;
        }

        var reader = try fromBytes(blob.bytes);
        reader.blob = blob;
        return reader;
    }

    /// 借用已有（已解压）字节。
    pub fn fromBytes(bytes: []const u8) !QqwryReader {
        if (bytes.len < 8) return Error.BadHeader;
        const index_start = readU32(bytes, 0) orelse return Error.BadHeader;
        const index_end = readU32(bytes, 4) orelse return Error.BadHeader;
        if (index_end < index_start) return Error.BadHeader;
        const span = index_end - index_start;
        const count: u32 = @intCast(span / INDEX_RECORD_LEN + 1);
        const index_bytes_end = @as(usize, index_start) + @as(usize, count) * INDEX_RECORD_LEN;
        if (index_bytes_end > bytes.len) return Error.BadHeader;
        return .{
            .blob = blob_mod.Blob.borrow(bytes),
            .decompressed = null,
            .gpa = null,
            .index_start = index_start,
            .index_end = index_end,
            .count = count,
        };
    }

    fn fromBytesOwned(bytes: []u8, gpa: std.mem.Allocator) !QqwryReader {
        var reader = try fromBytes(bytes);
        reader.gpa = gpa;
        return reader;
    }

    pub fn deinit(self: *QqwryReader) void {
        self.blob.deinit();
        if (self.decompressed) |data| {
            if (self.gpa) |gpa| gpa.free(data);
            self.decompressed = null;
        }
    }

    /// 索引记录条数。
    pub fn recordCount(self: QqwryReader) u32 {
        return self.count;
    }

    /// 数据是否来自 gzip。
    pub fn isCompressed(self: QqwryReader) bool {
        return self.decompressed != null;
    }

    /// 查询 IPv4（数值语义与 `IpAddr.v4` 一致：`1.2.3.4 → 0x01020304`）。
    pub fn lookup(self: *const QqwryReader, ip: u32) Error!?RawEntry {
        if (self.count == 0) return null;
        var lo: u32 = 0;
        var hi: u32 = self.count - 1;
        while (lo <= hi) {
            const mid = lo + (hi - lo) / 2;
            const record = try self.readIndex(mid);
            const end_ip = readU32(self.blob.bytes, record.offset) orelse return Error.Corrupt;
            if (ip < record.start) {
                if (mid == 0) break;
                hi = mid - 1;
            } else if (ip > end_ip) {
                lo = mid + 1;
            } else {
                return try self.readAddressInfo(record.offset);
            }
        }
        return null;
    }

    /// 查询并转成 UTF-8（写入 `scratch`）。
    pub fn lookupUtf8(self: *const QqwryReader, scratch: *Scratch, ip: u32) Error!?Entry {
        const raw = (try self.lookup(ip)) orelse return null;
        var used: usize = 0;

        const area_raw = try normalize(raw.area);
        const addr_raw = try normalize(raw.addr);

        const area = decodeInto(area_raw, scratch.buf[used..], &used);
        const addr = decodeInto(addr_raw, scratch.buf[used..], &used);
        return .{ .area = area, .addr = addr };
    }

    const IndexRecord = struct { start: u32, offset: usize };

    fn readIndex(self: *const QqwryReader, index: u32) Error!IndexRecord {
        const p = @as(usize, self.index_start) + @as(usize, index) * INDEX_RECORD_LEN;
        const start = readU32(self.blob.bytes, p) orelse return Error.Corrupt;
        const offset = readU24(self.blob.bytes, p + 4) orelse return Error.Corrupt;
        return .{ .start = start, .offset = offset };
    }

    fn readAddressInfo(self: *const QqwryReader, offset: usize) Error!RawEntry {
        var p: usize = offset + 4;
        var value = readU32(self.blob.bytes, p) orelse return Error.Corrupt;

        if (value & 0xFF == 1) {
            p = value >> 8;
            value = readU32(self.blob.bytes, p) orelse return Error.Corrupt;
        }

        if (value & 0xFF == 2) {
            const area_offset: usize = value >> 8;
            const addr = try self.readAddress(p + 4);
            const area = try self.readString(area_offset);
            return .{ .area = area, .addr = addr };
        }

        var cursor = p;
        const area = try self.readStringAdvance(&cursor);
        const addr = try self.readAddress(cursor);
        return .{ .area = area, .addr = addr };
    }

    fn readAddress(self: *const QqwryReader, start: usize) Error![]const u8 {
        if (start >= self.blob.bytes.len) return Error.Corrupt;
        var p = start;
        // 最后一条记录的空地址段可能正好落在文件末尾：此时只剩 1 个 0x00，
        // 不足 4 字节读不出 u32，但那是合法数据（不是损坏），按普通字符串读即可。
        if (readU32(self.blob.bytes, p)) |value| {
            const tag = value & 0xFF;
            if (tag == 1 or tag == 2) p = value >> 8;
        }
        return self.readString(p);
    }

    fn readString(self: *const QqwryReader, start: usize) Error![]const u8 {
        var cursor = start;
        return self.readStringAdvance(&cursor);
    }

    fn readStringAdvance(self: *const QqwryReader, cursor: *usize) Error![]const u8 {
        const bytes = self.blob.bytes;
        var p = cursor.*;
        var redirects: usize = 0;
        // 允许一次重定向（首字节 1/2），防止损坏数据成环
        while (p + 4 <= bytes.len and redirects < MAX_REDIRECTS) {
            const value = readU32(bytes, p).?;
            const tag = value & 0xFF;
            if (tag != 1 and tag != 2) break;
            p = value >> 8;
            redirects += 1;
        }
        if (p >= bytes.len) return Error.Corrupt;
        var end = p;
        const limit = @min(bytes.len, p + MAX_STRING_LEN);
        while (end < limit and bytes[end] != 0) : (end += 1) {}
        cursor.* = if (end < bytes.len) end + 1 else end;
        return bytes[p..end];
    }
};

/// 去掉纯真数据的占位串。
fn normalize(text: []const u8) Error![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n\x00");
    if (trimmed.len == 0) return "";
    if (std.ascii.eqlIgnoreCase(trimmed, "CZ88.NET")) return "";
    if (std.mem.eql(u8, trimmed, "纯真网络")) return "";
    return trimmed;
}

/// GBK → UTF-8 写入 `out`，返回写入部分；超出缓冲时截断。
fn decodeInto(raw: []const u8, out: []u8, used: *usize) []const u8 {
    const start = used.*;
    var written = start;
    var i: usize = 0;
    while (i < raw.len) {
        if (written >= out.len) break;
        const byte = raw[i];
        if (byte < 0x80) {
            out[written] = byte;
            written += 1;
            i += 1;
            continue;
        }
        if (i + 1 >= raw.len) break;
        const code = (@as(u16, byte) << 8) | raw[i + 1];
        var buf: [3]u8 = undefined;
        if (gbk.decodeInto(code, &buf)) |utf8| {
            if (written + utf8.len > out.len) break;
            @memcpy(out[written..][0..utf8.len], utf8);
            written += utf8.len;
        } else {
            out[written] = '?';
            written += 1;
        }
        i += 2;
    }
    used.* = written;
    return out[start..written];
}

fn readU16(bytes: []const u8, offset: usize) ?u16 {
    const end = offset + 2;
    if (end > bytes.len or end < offset) return null;
    const array: *const [2]u8 = bytes[offset..end][0..2];
    return std.mem.readInt(u16, array, .little);
}

fn readU24(bytes: []const u8, offset: usize) ?usize {
    const end = offset + 3;
    if (end > bytes.len or end < offset) return null;
    const array: *const [3]u8 = bytes[offset..end][0..3];
    return @as(usize, array[0]) | (@as(usize, array[1]) << 8) | (@as(usize, array[2]) << 16);
}

fn readU32(bytes: []const u8, offset: usize) ?u32 {
    const end = offset + 4;
    if (end > bytes.len or end < offset) return null;
    const array: *const [4]u8 = bytes[offset..end][0..4];
    return std.mem.readInt(u32, array, .little);
}

fn decompressGzip(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var input = std.Io.Reader.fixed(raw);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&input, .gzip, &window);
    return decompress.reader.allocRemaining(gpa, .limited(512 * 1024 * 1024));
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "构造最小 QQWry 记录并查询" {
    const gpa = testing.allocator;
    // 布局：[8 字节头][1 条索引(7B)][数据：end_ip + "中国电信" + 0 + "深圳" + 0]
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const index_start: u32 = 8;
    const data_offset: u32 = 15;
    const payload = [_]u8{ 0xB9, 0xFA, 0xB5, 0xE7, 0x00, 0xC9, 0xEE, 0xDB, 0xDA, 0x00 }; // 「国电」+0+「深圳」+0

    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], index_start, .little);
    std.mem.writeInt(u32, header[4..8], index_start, .little); // 单条记录：end = start
    try buf.appendSlice(gpa, &header);

    var index_record: [7]u8 = undefined;
    std.mem.writeInt(u32, index_record[0..4], 0x0100_0000, .little); // 1.0.0.0
    index_record[4] = @intCast(data_offset & 0xff);
    index_record[5] = @intCast((data_offset >> 8) & 0xff);
    index_record[6] = @intCast((data_offset >> 16) & 0xff);
    try buf.appendSlice(gpa, &index_record);

    var end_ip: [4]u8 = undefined;
    std.mem.writeInt(u32, &end_ip, 0x0100_00ff, .little); // 1.0.0.255
    try buf.appendSlice(gpa, &end_ip);
    try buf.appendSlice(gpa, &payload);

    var reader = try QqwryReader.fromBytes(buf.items);
    defer reader.deinit();
    try testing.expectEqual(@as(u32, 1), reader.recordCount());

    const raw = (try reader.lookup(0x0100_0001)).?;
    try testing.expectEqualSlices(u8, &[_]u8{ 0xB9, 0xFA, 0xB5, 0xE7 }, raw.area);

    var scratch: Scratch = .{};
    const entry = (try reader.lookupUtf8(&scratch, 0x0100_0005)).?;
    try testing.expectEqualStrings("国电", entry.area);
    try testing.expectEqualStrings("深圳", entry.addr);

    try testing.expect((try reader.lookup(0x0200_0001)) == null);
}

test "真实 ip.gz（DH.NIP）查询" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "G:/Code/Pek.FrameWork/DH.NIP/ip.gz";
    if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
        file.close(io);
    } else |_| {
        std.debug.print("[SKIP] 未找到真实 QQWry 数据：{s}\n", .{path});
        return;
    }

    var reader = try QqwryReader.open(io, gpa, path);
    defer reader.deinit();
    try testing.expect(reader.isCompressed());

    var scratch: Scratch = .{};
    const cases = [_]struct { ip: u32, label: []const u8 }{
        .{ .ip = 0x72_72_72_72, .label = "114.114.114.114" },
        .{ .ip = 0xDF_05_05_05, .label = "223.5.5.5" },
        .{ .ip = 0x08_08_08_08, .label = "8.8.8.8" },
    };
    for (cases) |case| {
        if (try reader.lookupUtf8(&scratch, case.ip)) |entry| {
            std.debug.print("[qqwry] {s} → {s} {s}\n", .{ case.label, entry.area, entry.addr });
            try testing.expect(entry.area.len > 0 or entry.addr.len > 0);
        } else {
            std.debug.print("[qqwry] {s} → 未命中\n", .{case.label});
        }
    }
}
