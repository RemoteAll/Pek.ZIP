//! MaxMind DB（GeoLite2 / GeoIP2 / DB-IP）读取器 —— 纯 Zig 实现，零分配查询。
//!
//! ## 文件布局
//!
//! ```text
//! [ search tree: node_count × record_size/4 字节 ]
//! [ 16 字节全 0 分隔符 ]
//! [ data section: 各种数据类型（含共享 key 指针） ]
//! [ \xAB\xCD\xEF"MaxMind.com" 标记 + metadata ]
//! ```
//!
//! - 树节点每条记录 `record_size` 位（24 / 28 / 32）：`< node_count` 表示继续走节点，
//!   `== node_count` 表示空占位（未命中），`> node_count` 表示数据指针；
//! - 数据秒针解析：`data_offset = record - node_count - 16`（相对 data section）；
//! - 数据段内的 pointer 类型是**相对 data section 起点**的偏移（1~4 字节四种编码）。
//!
//! 支持的记录：City / Enterprise / Country（国家/省/市/经纬度/时区）、ASN、ISP。
//! 字段切片全部借用 mmap 数据，查询过程**零分配**、无锁、可跨线程共享。

const std = @import("std");
const ip_mod = @import("ip.zig");
const blob_mod = @import("blob.zig");
const country_mod = @import("country.zig");
const IpAddr = ip_mod.IpAddr;

const METADATA_MARKER = "\xab\xcd\xefMaxMind.com";
const DATA_SECTION_SEPARATOR_SIZE: usize = 16;

/// MMDB 数据库类型。
pub const Kind = enum {
    auto,
    city,
    country,
    asn,
    isp,
    enterprise,

    /// 按 `metadata.database_type` 自动识别（与 Rust `Pek.IP::MmdbKind` 同规则）。
    pub fn fromDatabaseType(database_type: []const u8) Kind {
        var upper_buf: [64]u8 = undefined;
        const n = @min(database_type.len, upper_buf.len);
        for (0..n) |i| upper_buf[i] = std.ascii.toUpper(database_type[i]);
        const name = upper_buf[0..n];
        if (std.mem.indexOf(u8, name, "ASN") != null) return .asn;
        if (std.mem.indexOf(u8, name, "ISP") != null) return .isp;
        if (std.mem.indexOf(u8, name, "COUNTRY") != null) return .country;
        if (std.mem.indexOf(u8, name, "ENTERPRISE") != null) return .enterprise;
        return .city;
    }

    /// 是否城市类库（含企业库）。
    pub fn isCityLike(self: Kind) bool {
        return self == .city or self == .enterprise;
    }
};

/// 国外城市/国家记录（借用数据库内存，生命周期同 `MmdbReader`）。
pub const WorldRecord = struct {
    country_code: ?[]const u8 = null,
    country_zh: ?[]const u8 = null,
    country_en: ?[]const u8 = null,
    continent_code: ?[]const u8 = null,
    continent_zh: ?[]const u8 = null,
    province: ?[]const u8 = null,
    city: ?[]const u8 = null,
    district: ?[]const u8 = null,
    latitude: ?f64 = null,
    longitude: ?f64 = null,
    timezone: ?[]const u8 = null,
};

/// ASN / ISP 记录。
pub const AsnRecord = struct {
    asn: ?u32 = null,
    organization: ?[]const u8 = null,
    isp: ?[]const u8 = null,
};

/// 打开/解析错误。
pub const Error = error{
    MissingFile,
    EmptyFile,
    ReadFailed,
    /// 找不到 metadata 标记
    MissingMetadata,
    /// metadata 字段缺失/非法（record_size、ip_version、node_count）
    BadMetadata,
    /// 搜索树越界
    BadTree,
    /// 数据段越界 / 类型不符 / 指针环
    CorruptData,
};

/// MMDB 读取器（构造后只读，可跨线程共享）。
pub const MmdbReader = struct {
    blob: blob_mod.Blob,
    db_kind: Kind,
    database_type: []const u8,
    node_count: usize,
    record_size: usize,
    ip_version: u16,
    build_epoch: u64,
    /// 搜索树字节数（node_count × record_size / 4）。
    search_tree_size: usize,
    /// data section 在文件内的起始偏移（= 树 + 16 字节分隔符）。
    data_start: usize,
    /// data section 结束（metadata 标记起点）。
    data_end: usize,
    /// IPv4 在 IPv6 树中的起点节点（IPv4 库为 0）。
    ipv4_start: usize,

    pub const OpenOptions = struct {
        no_mmap: bool = false,
    };

    /// 打开 MMDB 文件（`kind = .auto` 按 metadata 自动识别）。
    pub fn open(io: std.Io, gpa: std.mem.Allocator, path: []const u8, wanted: Kind) !MmdbReader {
        return openWith(io, gpa, path, wanted, .{});
    }

    pub fn openWith(
        io: std.Io,
        gpa: std.mem.Allocator,
        path: []const u8,
        wanted: Kind,
        options: OpenOptions,
    ) !MmdbReader {
        var blob = blob_mod.Blob.open(io, gpa, path, .{ .no_mmap = options.no_mmap }) catch |err| switch (err) {
            error.MissingFile => return Error.MissingFile,
            error.EmptyFile => return Error.EmptyFile,
            error.ReadFailed => return Error.ReadFailed,
        };
        errdefer blob.deinit();
        return fromBlob(blob, wanted);
    }

    /// 从已有字节构造（借用，不接管所有权）。
    pub fn fromBytes(bytes: []const u8, wanted: Kind) !MmdbReader {
        return fromBlob(blob_mod.Blob.borrow(bytes), wanted);
    }

    fn fromBlob(blob: blob_mod.Blob, wanted: Kind) !MmdbReader {
        const bytes = blob.bytes;

        const marker_start = std.mem.lastIndexOf(u8, bytes, METADATA_MARKER) orelse return Error.MissingMetadata;
        const metadata_offset = marker_start + METADATA_MARKER.len;
        const metadata = Decoder{ .data = bytes[metadata_offset..] };

        const metadata_root: usize = 0;
        const node_count_u64 = (try metadata.getU64Path(metadata_root, &.{"node_count"})) orelse return Error.BadMetadata;
        const record_size_u64 = (try metadata.getU64Path(metadata_root, &.{"record_size"})) orelse return Error.BadMetadata;
        const ip_version_u64 = (try metadata.getU64Path(metadata_root, &.{"ip_version"})) orelse return Error.BadMetadata;
        const build_epoch = (try metadata.getU64Path(metadata_root, &.{"build_epoch"})) orelse 0;
        const database_type = (try metadata.getStringPath(metadata_root, &.{"database_type"})) orelse "";

        if (node_count_u64 == 0) return Error.BadMetadata;
        if (record_size_u64 != 24 and record_size_u64 != 28 and record_size_u64 != 32) return Error.BadMetadata;
        if (ip_version_u64 != 4 and ip_version_u64 != 6) return Error.BadMetadata;

        const node_count: usize = @intCast(node_count_u64);
        const record_size: usize = @intCast(record_size_u64);
        const search_tree_size = std.math.mul(usize, node_count, record_size) catch return Error.BadTree;
        const tree_bytes = search_tree_size / 4;
        const data_start = std.math.add(usize, tree_bytes, DATA_SECTION_SEPARATOR_SIZE) catch return Error.BadTree;
        if (data_start > marker_start) return Error.BadTree;

        var reader = MmdbReader{
            .blob = blob,
            .db_kind = if (wanted == .auto) Kind.fromDatabaseType(database_type) else wanted,
            .database_type = database_type,
            .node_count = node_count,
            .record_size = record_size,
            .ip_version = @intCast(ip_version_u64),
            .build_epoch = build_epoch,
            .search_tree_size = tree_bytes,
            .data_start = data_start,
            .data_end = marker_start,
            .ipv4_start = 0,
        };
        if (reader.ip_version == 6) reader.ipv4_start = reader.findIpv4Start();
        return reader;
    }

    pub fn deinit(self: *MmdbReader) void {
        self.blob.deinit();
    }

    /// 数据库类型（metadata.database_type）。
    pub fn databaseType(self: MmdbReader) []const u8 {
        return self.database_type;
    }

    /// 实际使用的读取类型（`auto` 已解析）。
    pub fn kind(self: MmdbReader) Kind {
        return self.db_kind;
    }

    /// 数据库支持的 IP 版本（4 / 6）。
    pub fn ipVersion(self: MmdbReader) u16 {
        return self.ip_version;
    }

    pub fn nodeCount(self: MmdbReader) usize {
        return self.node_count;
    }

    pub fn buildEpoch(self: MmdbReader) u64 {
        return self.build_epoch;
    }

    /// 是否来自 mmap。
    pub fn isMapped(self: MmdbReader) bool {
        return self.blob.isMapped();
    }

    /// 查询城市/国家记录（仅 City / Country / Enterprise 类库）。
    pub fn lookupWorld(self: *const MmdbReader, ip: IpAddr) Error!?WorldRecord {
        if (!self.db_kind.isCityLike() and self.db_kind != .country) return null;
        const data_offset = (try self.findDataOffset(ip)) orelse return null;
        const dec = self.decoder();

        var rec = WorldRecord{};
        rec.country_code = (try dec.getStringPath(data_offset, &.{ "country", "iso_code" })) orelse
            (try dec.getStringPath(data_offset, &.{ "registered_country", "iso_code" }));
        rec.country_en = try dec.getNamesField(data_offset, &.{"country"}, "en");
        rec.country_zh = try dec.getNamesField(data_offset, &.{"country"}, "zh-CN");
        if (rec.country_zh == null and rec.country_code != null) {
            rec.country_zh = country_mod.nameZh(rec.country_code.?);
        }
        rec.continent_code = try dec.getStringPath(data_offset, &.{ "continent", "code" });
        rec.continent_zh = try dec.getNamesField(data_offset, &.{"continent"}, "zh-CN");
        if (rec.continent_zh == null and rec.continent_code != null) {
            rec.continent_zh = country_mod.continentNameZh(rec.continent_code.?);
        }

        const city_zh = try dec.getNamesField(data_offset, &.{"city"}, "zh-CN");
        const city_en = try dec.getNamesField(data_offset, &.{"city"}, "en");
        rec.city = city_zh orelse city_en;

        const subdivisions = try dec.getPath(data_offset, &.{"subdivisions"});
        if (subdivisions) |sub_offset| {
            const count = try dec.arrayLen(sub_offset);
            if (count > 0) {
                if (try dec.arrayItem(sub_offset, 0)) |item| {
                    rec.province = (try dec.getNamesField(item, &.{}, "zh-CN")) orelse
                        (try dec.getNamesField(item, &.{}, "en"));
                }
                if (count > 1) {
                    if (try dec.arrayItem(sub_offset, count - 1)) |item| {
                        const district = (try dec.getNamesField(item, &.{}, "zh-CN")) orelse
                            (try dec.getNamesField(item, &.{}, "en"));
                        if (district != null and (rec.city == null or !std.mem.eql(u8, district.?, rec.city.?))) {
                            rec.district = district;
                        }
                    }
                }
            }
        }

        rec.latitude = try dec.getF64Path(data_offset, &.{ "location", "latitude" });
        rec.longitude = try dec.getF64Path(data_offset, &.{ "location", "longitude" });
        rec.timezone = try dec.getStringPath(data_offset, &.{ "location", "time_zone" });
        return rec;
    }

    /// 查询 ASN / ISP 记录（仅 Asn / Isp 类库）。
    pub fn lookupAsn(self: *const MmdbReader, ip: IpAddr) Error!?AsnRecord {
        if (self.db_kind != .asn and self.db_kind != .isp) return null;
        const data_offset = (try self.findDataOffset(ip)) orelse return null;
        const dec = self.decoder();

        var rec = AsnRecord{};
        if (try dec.getU64Path(data_offset, &.{"autonomous_system_number"})) |value| {
            rec.asn = @intCast(value);
        }
        const asn_org = try dec.getStringPath(data_offset, &.{"autonomous_system_organization"});
        if (self.db_kind == .isp) {
            rec.isp = try dec.getStringPath(data_offset, &.{"isp"});
            rec.organization = asn_org orelse (try dec.getStringPath(data_offset, &.{"organization"}));
        } else {
            rec.organization = asn_org;
        }
        return rec;
    }

    fn decoder(self: *const MmdbReader) Decoder {
        return .{ .data = self.blob.bytes[self.data_start..self.data_end] };
    }

    /// 树遍历：返回数据段内的偏移（相对 data section）。
    fn findDataOffset(self: *const MmdbReader, ip_in: IpAddr) Error!?usize {
        const ip = ip_in.normalize();
        const result: usize = switch (ip) {
            .v4 => |v| if (self.ip_version == 6)
                try self.traverse(self.ipv4_start, v, 32)
            else
                try self.traverse(0, v, 32),
            .v6 => |v| if (self.ip_version == 4)
                return null
            else
                try self.traverse(0, v, 128),
        };
        if (result <= self.node_count) return null;
        const resolved = result - self.node_count - DATA_SECTION_SEPARATOR_SIZE;
        if (resolved >= self.data_end - self.data_start) return null;
        return resolved;
    }

    fn traverse(self: *const MmdbReader, start_node: usize, key: u128, bits: usize) Error!usize {
        var node = start_node;
        var i: usize = 0;
        while (i < bits) : (i += 1) {
            if (node >= self.node_count) break;
            const bit: usize = @intCast((key >> @intCast(bits - 1 - i)) & 1);
            node = try self.readNode(node, bit);
        }
        return node;
    }

    fn readNode(self: *const MmdbReader, node: usize, index: usize) Error!usize {
        const bytes = self.blob.bytes;
        switch (self.record_size) {
            24 => {
                const offset = node * 6 + index * 2;
                const word = readBeU32(bytes, offset) orelse return Error.BadTree;
                return (word >> @intCast((1 - index) * 8)) & 0x00FF_FFFF;
            },
            28 => {
                const offset = node * 7 + index * 3;
                const word = readBeU32(bytes, offset) orelse return Error.BadTree;
                if (index == 0) {
                    return (word >> 8) | ((word << 20) & 0x0F00_0000);
                }
                return word & 0x0FFF_FFFF;
            },
            32 => {
                const offset = node * 8 + index * 4;
                const word = readBeU32(bytes, offset) orelse return Error.BadTree;
                return word;
            },
            else => return Error.BadMetadata,
        }
    }

    fn findIpv4Start(self: *const MmdbReader) usize {
        var node: usize = 0;
        for (0..96) |_| {
            if (node >= self.node_count) return node;
            node = self.readNode(node, 0) catch return node;
        }
        return node;
    }
};

fn readBeU32(bytes: []const u8, offset: usize) ?u32 {
    const end = offset + 4;
    if (end > bytes.len or end < offset) return null;
    const array: *const [4]u8 = bytes[offset..end][0..4];
    return std.mem.readInt(u32, array, .big);
}

// ---------------------------------------------------------------------------
// MMDB 数据类型解码
// ---------------------------------------------------------------------------

const DataType = enum {
    pointer,
    utf8_string,
    double,
    bytes,
    uint16,
    uint32,
    map,
    int32,
    uint64,
    uint128,
    array,
    cache_container,
    end_marker,
    boolean,
    float,
    unknown,
};

const Entry = struct {
    kind: DataType,
    /// 整数：字节数；字符串/bytes：长度；map：键值对数；array：元素个数；pointer：控制位。
    size: usize,
    /// 负载起始偏移。
    payload: usize,
};

const Decoder = struct {
    /// data section 字节（pointer 的目标偏移相对本切片起点）。
    data: []const u8,

    fn entryAt(self: Decoder, offset: usize) Error!Entry {
        if (offset >= self.data.len) return Error.CorruptData;
        const ctrl = self.data[offset];
        var pos = offset + 1;

        var type_num: u8 = ctrl >> 5;
        if (type_num == 0) {
            if (pos >= self.data.len) return Error.CorruptData;
            type_num = self.data[pos] + 7;
            pos += 1;
        }

        const kind: DataType = switch (type_num) {
            1 => .pointer,
            2 => .utf8_string,
            3 => .double,
            4 => .bytes,
            5 => .uint16,
            6 => .uint32,
            7 => .map,
            8 => .int32,
            9 => .uint64,
            10 => .uint128,
            11 => .array,
            12 => .cache_container,
            13 => .end_marker,
            14 => .boolean,
            15 => .float,
            else => .unknown,
        };

        var size: usize = ctrl & 0x1f;
        switch (size) {
            0...28 => {},
            29 => {
                if (pos >= self.data.len) return Error.CorruptData;
                size = 29 + self.data[pos];
                pos += 1;
            },
            30 => {
                if (pos + 2 > self.data.len) return Error.CorruptData;
                size = 285 + (@as(usize, self.data[pos]) << 8) + self.data[pos + 1];
                pos += 2;
            },
            else => {
                if (pos + 3 > self.data.len) return Error.CorruptData;
                size = 65_821 + (@as(usize, self.data[pos]) << 16) +
                    (@as(usize, self.data[pos + 1]) << 8) + self.data[pos + 2];
                pos += 3;
            },
        }
        return .{ .kind = kind, .size = size, .payload = pos };
    }

    fn pointerTarget(self: Decoder, entry: Entry) Error!usize {
        const pointer_size = ((entry.size >> 3) & 0x3) + 1;
        const high: usize = entry.size & 0x7;
        const end = entry.payload + pointer_size;
        if (end > self.data.len) return Error.CorruptData;
        const bytes = self.data[entry.payload..end];
        const target: usize = switch (pointer_size) {
            1 => (high << 8) | bytes[0],
            2 => ((high << 16) | (@as(usize, bytes[0]) << 8) | bytes[1]) + 2048,
            3 => ((high << 24) | (@as(usize, bytes[0]) << 16) | (@as(usize, bytes[1]) << 8) | bytes[2]) + 526_336,
            else => (@as(usize, bytes[0]) << 24) | (@as(usize, bytes[1]) << 16) |
                (@as(usize, bytes[2]) << 8) | bytes[3],
        };
        if (target >= self.data.len) return Error.CorruptData;
        return target;
    }

    /// 解引用（最多一层，规范不允许指针指向指针）。
    fn resolve(self: Decoder, offset: usize) Error!Entry {
        var entry = try self.entryAt(offset);
        if (entry.kind == .pointer) {
            const target = try self.pointerTarget(entry);
            entry = try self.entryAt(target);
            if (entry.kind == .pointer) return Error.CorruptData;
        }
        return entry;
    }

    fn payloadEnd(self: Decoder, entry: Entry) Error!usize {
        const end = entry.payload + entry.size;
        if (end > self.data.len or end < entry.payload) return Error.CorruptData;
        return end;
    }

    /// 跳过一个值，返回其后的偏移。
    fn skip(self: Decoder, offset: usize) Error!usize {
        return self.skipDepth(offset, 0);
    }

    fn skipDepth(self: Decoder, offset: usize, depth: u8) Error!usize {
        if (depth > 32) return Error.CorruptData;
        const entry = try self.entryAt(offset);
        switch (entry.kind) {
            .pointer => {
                const pointer_size = ((entry.size >> 3) & 0x3) + 1;
                const end = entry.payload + pointer_size;
                if (end > self.data.len) return Error.CorruptData;
                return end;
            },
            .map => {
                var pos = entry.payload;
                var i: usize = 0;
                while (i < entry.size) : (i += 1) {
                    pos = try self.skipDepth(pos, depth + 1);
                    pos = try self.skipDepth(pos, depth + 1);
                }
                return pos;
            },
            .array => {
                var pos = entry.payload;
                var i: usize = 0;
                while (i < entry.size) : (i += 1) {
                    pos = try self.skipDepth(pos, depth + 1);
                }
                return pos;
            },
            else => return self.payloadEnd(entry),
        }
    }

    /// 读字符串（pointer 自动解引用；类型不符返回 null）。
    fn asString(self: Decoder, offset: usize) Error!?[]const u8 {
        const entry = try self.resolve(offset);
        if (entry.kind != .utf8_string and entry.kind != .bytes) return null;
        const end = try self.payloadEnd(entry);
        return self.data[entry.payload..end];
    }

    /// 读无符号整数（uint16/uint32/uint64/uint128；bool 不在此列）。
    fn asU64(self: Decoder, offset: usize) Error!?u64 {
        const entry = try self.resolve(offset);
        return switch (entry.kind) {
            .uint16, .uint32, .uint64 => blk: {
                const end = try self.payloadEnd(entry);
                if (entry.size > 8) return Error.CorruptData;
                var value: u64 = 0;
                for (self.data[entry.payload..end]) |b| value = (value << 8) | b;
                break :blk value;
            },
            .int32 => blk: {
                const end = try self.payloadEnd(entry);
                if (entry.size > 4) return Error.CorruptData;
                var value: u64 = 0;
                for (self.data[entry.payload..end]) |b| value = (value << 8) | b;
                break :blk value;
            },
            else => null,
        };
    }

    /// 读浮点数（double / float）。
    fn asF64(self: Decoder, offset: usize) Error!?f64 {
        const entry = try self.resolve(offset);
        const end = try self.payloadEnd(entry);
        return switch (entry.kind) {
            .double => if (entry.size == 8)
                @as(f64, @bitCast(std.mem.readInt(u64, self.data[entry.payload..end][0..8], .big)))
            else
                null,
            .float => if (entry.size == 4)
                @as(f64, @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, self.data[entry.payload..end][0..4], .big)))))
            else
                null,
            else => null,
        };
    }

    /// map 中按键取值的偏移（值本身可能是 pointer，由调用方 `resolve`）。
    fn mapGet(self: Decoder, map_offset: usize, key: []const u8) Error!?usize {
        const entry = try self.resolve(map_offset);
        if (entry.kind != .map) return null;
        var pos = entry.payload;
        var i: usize = 0;
        while (i < entry.size) : (i += 1) {
            const key_value = (try self.asString(pos)) orelse "";
            const value_offset = try self.skip(pos);
            if (std.mem.eql(u8, key_value, key)) return value_offset;
            pos = try self.skip(value_offset);
        }
        return null;
    }

    fn arrayLen(self: Decoder, array_offset: usize) Error!usize {
        const entry = try self.resolve(array_offset);
        if (entry.kind != .array) return 0;
        return entry.size;
    }

    fn arrayItem(self: Decoder, array_offset: usize, index: usize) Error!?usize {
        const entry = try self.resolve(array_offset);
        if (entry.kind != .array or index >= entry.size) return null;
        var pos = entry.payload;
        var i: usize = 0;
        while (i < index) : (i += 1) pos = try self.skip(pos);
        return pos;
    }

    fn getPath(self: Decoder, start: usize, path: []const []const u8) Error!?usize {
        var current: ?usize = start;
        for (path) |key| {
            const offset = current orelse return null;
            current = try self.mapGet(offset, key);
        }
        return current;
    }

    fn getStringPath(self: Decoder, start: usize, path: []const []const u8) Error!?[]const u8 {
        const offset = (try self.getPath(start, path)) orelse return null;
        return self.asString(offset);
    }

    fn getU64Path(self: Decoder, start: usize, path: []const []const u8) Error!?u64 {
        const offset = (try self.getPath(start, path)) orelse return null;
        return self.asU64(offset);
    }

    fn getF64Path(self: Decoder, start: usize, path: []const []const u8) Error!?f64 {
        const offset = (try self.getPath(start, path)) orelse return null;
        return self.asF64(offset);
    }

    /// `{parent}.names.{lang}`：依次尝试 zh-CN、zh、en。
    fn getNamesField(self: Decoder, start: usize, parent: []const []const u8, lang: []const u8) Error!?[]const u8 {
        const names = (try self.getPath(start, parent)) orelse return null;
        const names_map = (try self.mapGet(names, "names")) orelse return null;
        if (try self.mapGet(names_map, lang)) |value| {
            if (try self.asString(value)) |text| return text;
        }
        if (!std.mem.eql(u8, lang, "zh-CN")) {
            if (try self.mapGet(names_map, "zh")) |value| {
                if (try self.asString(value)) |text| return text;
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "类型识别与真实 DB-IP 国家库" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expectEqual(Kind.city, Kind.fromDatabaseType("GeoLite2-City"));
    try testing.expectEqual(Kind.country, Kind.fromDatabaseType("GeoLite2-Country"));
    try testing.expectEqual(Kind.asn, Kind.fromDatabaseType("GeoLite2-ASN"));
    try testing.expectEqual(Kind.isp, Kind.fromDatabaseType("GeoIP2-ISP"));
    try testing.expectEqual(Kind.enterprise, Kind.fromDatabaseType("GeoIP2-Enterprise"));

    const path = "G:/Code/Rust/Pek.IP/data/dbip-country-lite-2026-10.mmdb";
    if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
        file.close(io);
    } else |_| {
        std.debug.print("[SKIP] 未找到真实 MMDB：{s}\n", .{path});
        return;
    }

    var reader = try MmdbReader.open(io, gpa, path, .auto);
    defer reader.deinit();
    try testing.expect(reader.ipVersion() == 4 or reader.ipVersion() == 6);
    try testing.expect(reader.nodeCount() > 0);
    std.debug.print("[mmdb] type={s} kind={s} ipv={d} nodes={d} mapped={}\n", .{
        reader.databaseType(),
        @tagName(reader.kind()),
        reader.ipVersion(),
        reader.nodeCount(),
        reader.isMapped(),
    });

    const rec = (try reader.lookupWorld(try IpAddr.parse("8.8.8.8"))).?;
    std.debug.print("[mmdb] 8.8.8.8 → {s} / {s}\n", .{
        rec.country_code orelse "-",
        rec.country_zh orelse "-",
    });
    try testing.expectEqualStrings("US", rec.country_code.?);
    try testing.expectEqualStrings("美国", rec.country_zh.?);

    const rec_cn = (try reader.lookupWorld(try IpAddr.parse("114.114.114.114"))).?;
    try testing.expectEqualStrings("CN", rec_cn.country_code.?);
    try testing.expectEqualStrings("中国", rec_cn.country_zh.?);

    try testing.expect((try reader.lookupWorld(try IpAddr.parse("10.0.0.1"))) == null);
}

test "真实 DB-IP ASN 库" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "G:/Code/Rust/Pek.IP/data/dbip-asn-lite-2026-10.mmdb";
    if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
        file.close(io);
    } else |_| {
        std.debug.print("[SKIP] 未找到真实 MMDB：{s}\n", .{path});
        return;
    }

    var reader = try MmdbReader.open(io, gpa, path, .auto);
    defer reader.deinit();
    try testing.expectEqual(Kind.asn, reader.kind());

    const rec = (try reader.lookupAsn(try IpAddr.parse("8.8.8.8"))).?;
    std.debug.print("[mmdb-asn] 8.8.8.8 → AS{d} {s}\n", .{
        rec.asn orelse 0,
        rec.organization orelse "-",
    });
    try testing.expect(rec.asn != null);
    try testing.expect(rec.organization != null);
}

test "坏数据被拒绝" {
    try testing.expectError(Error.MissingMetadata, MmdbReader.fromBytes("not-a-mmdb", .auto));
}
