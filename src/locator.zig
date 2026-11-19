//! 统一 IP 定位器：国内 ip2region（xdb）+ 国外 MMDB + 纯真 QQWry 兼容，合并成统一结果。
//!
//! 合并策略（与 Rust `Pek.IP::locator::merge_records` 一致）：
//!
//! 1. 内网/回环/保留地址直接返回，不查库；
//! 2. 国内 IP（ip2region 判定为中国）：国家/省/市/运营商以 ip2region 为准，
//!    经纬度/时区/区县由 MMDB 补齐；
//! 3. 国外 IP：以 MMDB 为主，ip2region 只补缺失字段（未使用则不标记 merged）；
//! 4. ASN/ISP 最后合并，`isp` 缺失时回退 ASN 组织名；
//! 5. 没有 xdb 时用纯真 QQWry（`ip.gz`）作为国内数据源。
//!
//! **零分配**：所有字符串要么借用数据库内存（mmap），要么写在调用方的
//! [`Scratch`] 里（仅 QQWry 的 GBK→UTF-8 转码需要缓冲）。

const std = @import("std");
const ip_mod = @import("ip.zig");
const region_mod = @import("region.zig");
const country_mod = @import("country.zig");
const xdb_mod = @import("xdb.zig");
const mmdb_mod = @import("mmdb.zig");
const qqwry_mod = @import("qqwry.zig");
const blob_mod = @import("blob.zig");

const IpAddr = ip_mod.IpAddr;
const IpClass = ip_mod.IpClass;
const CnRegion = region_mod.CnRegion;

/// 数据来源。
pub const DataSource = enum {
    /// 内网/保留/组播等特殊地址，未查询数据库。
    reserved,
    /// 仅命中 ip2region（国内数据）。
    ip2region,
    /// 仅命中纯真 QQWry（DH.NIP 历史数据）。
    qqwry,
    /// 仅命中 MMDB（国外数据）。
    mmdb,
    /// 多源合并（国内城市用 xdb，经纬度/时区等用 MMDB）。
    merged,
    /// 数据库中没有该地址的记录。
    unknown,

    /// 中文标签。
    pub fn label(self: DataSource) []const u8 {
        return switch (self) {
            .reserved => "保留地址",
            .ip2region => "ip2region",
            .qqwry => "纯真",
            .mmdb => "MMDB",
            .merged => "多源合并",
            .unknown => "未知",
        };
    }
};

/// 单线程查询缓冲（每个线程一份，避免分配与跨线程共享）。
pub const Scratch = struct {
    buf: [512]u8 = undefined,
    qqwry: qqwry_mod.Scratch = .{},
};

/// 统一 IP 定位结果。
///
/// 字符串切片的生命周期：借用 `Locator` 内的数据（mmap 常驻），或指向调用方
/// `Scratch`；**不要**在 locator 释放/scratch 复用后继续持有。
pub const Location = struct {
    ip: IpAddr,
    country: ?[]const u8 = null,
    country_code: ?[]const u8 = null,
    country_en: ?[]const u8 = null,
    continent: ?[]const u8 = null,
    continent_code: ?[]const u8 = null,
    province: ?[]const u8 = null,
    city: ?[]const u8 = null,
    district: ?[]const u8 = null,
    isp: ?[]const u8 = null,
    asn: ?u32 = null,
    as_org: ?[]const u8 = null,
    latitude: ?f64 = null,
    longitude: ?f64 = null,
    timezone: ?[]const u8 = null,
    is_china: bool = false,
    is_private: bool = false,
    ip_class: ?IpClass = null,
    source: DataSource = .unknown,

    /// 特殊地址结果。
    pub fn reserved(ip: IpAddr, class: IpClass) Location {
        return .{
            .ip = ip,
            .country = class.label(),
            .is_private = true,
            .ip_class = class,
            .source = .reserved,
        };
    }

    /// 是否命中任意数据源（含特殊地址分类）。
    pub fn isKnown(self: Location) bool {
        return self.source != .unknown;
    }

    /// 是否公网地址。
    pub fn isPublic(self: Location) bool {
        return !self.is_private;
    }

    /// 是否大中华区（`CN`/`HK`/`MO`/`TW`，或名称以“中国”开头）。
    pub fn isChinaRegion(self: Location) bool {
        if (self.is_china) return true;
        if (self.country_code) |code| {
            if (std.ascii.eqlIgnoreCase(code, "HK") or
                std.ascii.eqlIgnoreCase(code, "MO") or
                std.ascii.eqlIgnoreCase(code, "TW")) return true;
        }
        if (self.country) |c| return std.mem.startsWith(u8, c, "中国");
        return false;
    }

    /// 展示用单行文本（如 `中国 广东省 深圳市 中国电信`），写入 `buf`。
    pub fn displayShort(self: Location, buf: []u8) []const u8 {
        var writer = std.Io.Writer.fixed(buf);
        const w = &writer;
        var wrote = false;
        if (self.country) |country| {
            if (country.len > 0) {
                w.writeAll(country) catch return "未知";
                wrote = true;
            }
        }
        const fields = [4]?[]const u8{ self.province, self.city, self.district, self.isp };
        for (fields) |field| {
            const text = field orelse continue;
            if (text.len == 0) continue;
            if (self.country) |country| {
                if (std.mem.eql(u8, text, country)) continue;
            }
            if (wrote) w.writeByte(' ') catch break;
            w.writeAll(text) catch break;
            wrote = true;
        }
        if (!wrote) return "未知";
        return w.buffered();
    }
};

/// 是否包含任意数据源。
pub const Locator = struct {
    xdb_v4: ?xdb_mod.XdbReader = null,
    xdb_v6: ?xdb_mod.XdbReader = null,
    world: ?mmdb_mod.MmdbReader = null,
    world_asn: ?mmdb_mod.MmdbReader = null,
    qqwry: ?qqwry_mod.QqwryReader = null,

    pub fn deinit(self: *Locator) void {
        if (self.xdb_v4) |*reader| reader.deinit();
        if (self.xdb_v6) |*reader| reader.deinit();
        if (self.world) |*reader| reader.deinit();
        if (self.world_asn) |*reader| reader.deinit();
        if (self.qqwry) |*reader| reader.deinit();
        self.* = .{};
    }

    /// 是否有国内 ip2region 数据。
    pub fn hasChinaDb(self: Locator) bool {
        return self.xdb_v4 != null or self.xdb_v6 != null or self.qqwry != null;
    }

    /// 是否有国外 MMDB 数据。
    pub fn hasWorldDb(self: Locator) bool {
        return self.world != null or self.world_asn != null;
    }

    /// 查询 IP（零分配；结果切片借用 locator 或 `scratch`）。
    pub fn lookup(self: *const Locator, scratch: *Scratch, ip_in: IpAddr) !Location {
        return self.lookupOptions(scratch, ip_in, .{});
    }

    /// 查询选项。
    pub const Options = struct {
        /// 命中 ip2region 国内记录时**跳过 MMDB**。
        ///
        /// 实测（ReleaseFast，真实数据）：国内 IP 的 MMDB 查询占整体耗时的 ~95%
        /// （xdb 66 ns/op vs 合并 1930 ns/op）。日志分析 / 地区统计这类只要
        /// 国家-省-市-ISP 的场景开它会快一个数量级；代价是拿不到
        /// 经纬度 / 时区 / 区县 / ASN（国外 IP 仍照常走 MMDB，不受影响）。
        skip_world_for_china: bool = false,
    };

    /// 带选项的查询。
    pub fn lookupOptions(
        self: *const Locator,
        scratch: *Scratch,
        ip_in: IpAddr,
        options: Options,
    ) !Location {
        const ip = ip_in.normalize();
        if (ip_mod.classify(ip)) |class| return Location.reserved(ip, class);

        var cn: ?CnRegion = null;
        if (try self.lookupXdb(ip)) |text| {
            const parsed = CnRegion.parse(text);
            if (!parsed.reserved and !parsed.isEmpty()) cn = parsed;
        }
        if (cn == null) {
            if (try self.lookupQqwry(scratch, ip)) |parsed| cn = parsed;
        }

        // 国内快速路径：省市/ISP 已由 ip2region 给出，再查 MMDB 只为补
        // 经纬度/时区/区县/ASN，不必要时省掉（这是国内流量的主要开销）
        const skip_world = options.skip_world_for_china and (cn != null and cn.?.isChinaRegion());

        var world: ?mmdb_mod.WorldRecord = null;
        if (!skip_world) {
            if (self.world) |*reader| {
                world = try reader.lookupWorld(ip);
            }
        }
        var asn: ?mmdb_mod.AsnRecord = null;
        if (!skip_world) {
            if (self.world_asn) |*reader| {
                asn = try reader.lookupAsn(ip);
            }
        }

        return merge(ip, cn, world, asn, self.qqwry != null and self.xdb_v4 == null and self.xdb_v6 == null);
    }

    /// 查询 IP 文本。
    pub fn lookupStr(self: *const Locator, scratch: *Scratch, text: []const u8) !Location {
        return self.lookup(scratch, try IpAddr.parse(text));
    }

    /// 查询 IPv4（数值语义与 Rust `IpLocator::lookup_ipv4` 一致：`1.2.3.4 → 0x01020304`）。
    pub fn lookupIpv4(self: *const Locator, scratch: *Scratch, ip: u32) !Location {
        return self.lookup(scratch, .{ .v4 = ip });
    }

    /// 查询 IPv6（大端 u128，与 `Ipv6Addr::octets()` 逐字节一致）。
    pub fn lookupIpv6(self: *const Locator, scratch: *Scratch, ip: u128) !Location {
        return self.lookup(scratch, .{ .v6 = ip });
    }

    fn lookupXdb(self: *const Locator, ip: IpAddr) !?[]const u8 {
        const readers: [2]*const ?xdb_mod.XdbReader = switch (ip) {
            .v4 => .{ &self.xdb_v4, &self.xdb_v6 },
            .v6 => .{ &self.xdb_v6, &self.xdb_v4 },
        };
        for (readers) |slot| {
            if (slot.*) |*reader| {
                const text = (try reader.lookup(ip)) orelse continue;
                return text;
            }
        }
        return null;
    }

    fn lookupQqwry(self: *const Locator, scratch: *Scratch, ip: IpAddr) !?CnRegion {
        const reader = if (self.qqwry) |*value| value else return null;
        const numeric = switch (ip) {
            .v4 => |v| v,
            // 纯真库只有 IPv4：非 v4-mapped 的 IPv6 不查
            .v6 => return null,
        };
        const entry = (try reader.lookupUtf8(&scratch.qqwry, numeric)) orelse return null;
        return qqwryToRegion(entry);
    }
};

/// 把纯真 `area`（`中国–江苏–南京`）+ `addr`（运营商/描述）转成地域记录。
fn qqwryToRegion(entry: qqwry_mod.Entry) CnRegion {
    var region = CnRegion{};
    var parts: [4][]const u8 = undefined;
    const count = splitArea(entry.area, &parts);

    if (count > 0) region.country = parts[0];
    if (count > 1) region.province = parts[1];
    if (count > 2) region.city = parts[2];
    if (count > 3) region.district = parts[3];
    const addr = std.mem.trim(u8, entry.addr, " \t");
    if (addr.len > 0) region.isp = addr;

    if (region.country) |name| {
        if (std.mem.startsWith(u8, name, "中国")) region.is_china = true;
    }
    if (region.is_china) {
        region.country = "中国";
        region.country_code = "CN";
    } else if (region.country) |name| {
        region.country_code = country_mod.codeFromNameZh(name);
    }
    return region;
}

/// 按 en dash（U+2013）/ 半角 `-` 拆分纯真的区域串。
fn splitArea(area: []const u8, parts: *[4][]const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < area.len) {
        var sep_len: usize = 0;
        if (area[i] == '-') {
            sep_len = 1;
        } else if (i + 3 <= area.len and std.mem.eql(u8, area[i..][0..3], "\u{2013}")) {
            sep_len = 3;
        }
        if (sep_len == 0) {
            i += 1;
            continue;
        }
        const piece = std.mem.trim(u8, area[start..i], " \t");
        if (piece.len > 0 and count < parts.len) {
            parts[count] = piece;
            count += 1;
        }
        i += sep_len;
        start = i;
    }
    const piece = std.mem.trim(u8, area[start..], " \t");
    if (piece.len > 0 and count < parts.len) {
        parts[count] = piece;
        count += 1;
    }
    return count;
}

/// 合并国内/国外/ASN 记录（公开给同模块测试）。
pub fn merge(
    ip: IpAddr,
    cn_input: ?CnRegion,
    world_input: ?mmdb_mod.WorldRecord,
    asn: ?mmdb_mod.AsnRecord,
    cn_from_qqwry: bool,
) Location {
    var out = Location{ .ip = ip };

    if (world_input) |w| {
        out.country_code = w.country_code;
        out.country = w.country_zh orelse blk: {
            const code = out.country_code orelse break :blk null;
            break :blk country_mod.nameZh(code);
        };
        out.country_en = w.country_en;
        out.continent_code = w.continent_code;
        out.continent = w.continent_zh orelse blk: {
            const code = out.continent_code orelse break :blk null;
            break :blk country_mod.continentNameZh(code);
        };
        out.province = w.province;
        out.city = w.city;
        out.district = w.district;
        out.latitude = w.latitude;
        out.longitude = w.longitude;
        out.timezone = w.timezone;
        out.source = .mmdb;
    }

    if (cn_input) |cn| {
        const had_world = out.source == .mmdb;
        if (cn.is_china) {
            out.is_china = true;
            out.country = cn.displayZh() orelse "中国";
            out.country_code = cn.country_code orelse "CN";
            out.country_en = "China";
            out.continent = "亚洲";
            out.continent_code = "AS";

            if (cn.province) |province| {
                if (out.province == null or !std.mem.eql(u8, out.province.?, province)) {
                    out.district = null;
                }
                out.province = province;
            }
            if (cn.city) |city| {
                if (out.city == null or !std.mem.eql(u8, out.city.?, city)) {
                    out.district = null;
                }
                out.city = city;
            }
            if (cn.isp) |isp| out.isp = isp;
            if (out.district == null) out.district = cn.district;

            out.source = if (had_world)
                .merged
            else if (cn_from_qqwry) .qqwry else .ip2region;
        } else if (out.country == null and !cn.isEmpty()) {
            out.country = cn.displayZh();
            out.country_code = cn.country_code;
            out.province = cn.province;
            out.city = cn.city;
            out.isp = cn.isp;
            out.source = if (had_world)
                .merged
            else if (cn_from_qqwry) .qqwry else .ip2region;
        } else if (had_world) {
            // 国外：MMDB 为主；ip2region 只补缺失字段，未使用则不标记 merged
            var used_cn = false;
            if (out.province == null) {
                if (cn.province) |value| {
                    out.province = value;
                    used_cn = true;
                }
            }
            if (out.city == null) {
                if (cn.city) |value| {
                    out.city = value;
                    used_cn = true;
                }
            }
            if (out.isp == null) {
                if (cn.isp) |value| {
                    out.isp = value;
                    used_cn = true;
                }
            }
            if (used_cn) out.source = .merged;
        }
    }

    if (asn) |a| {
        if (out.asn == null) out.asn = a.asn;
        if (out.isp == null) out.isp = a.isp orelse a.organization;
        if (out.as_org == null) out.as_org = a.organization;
    }

    if (out.country == null) {
        if (out.country_code) |code| out.country = country_mod.nameZh(code);
    }
    if (out.country_code) |code| {
        if (std.ascii.eqlIgnoreCase(code, "CN")) {
            out.is_china = true;
            if (out.country == null) out.country = "中国";
        }
    } else if (out.country) |name| {
        if (std.mem.eql(u8, name, "中国")) out.is_china = true;
    }
    return out;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn worldUs() mmdb_mod.WorldRecord {
    return .{
        .country_code = "US",
        .country_zh = "美国",
        .country_en = "United States",
        .continent_code = "NA",
        .continent_zh = "北美洲",
        .province = "California",
        .city = "Los Angeles",
        .latitude = 34.05,
        .longitude = -118.24,
        .timezone = "America/Los_Angeles",
    };
}

test "国内记录压过 MMDB 城市但保留坐标" {
    const cn = CnRegion.parse("中国|广东省|深圳市|中国电信|CN");
    const loc = merge(try IpAddr.parse("1.2.3.4"), cn, worldUs(), null, false);
    try testing.expect(loc.is_china);
    try testing.expectEqualStrings("中国", loc.country.?);
    try testing.expectEqualStrings("CN", loc.country_code.?);
    try testing.expectEqualStrings("广东省", loc.province.?);
    try testing.expectEqualStrings("深圳市", loc.city.?);
    try testing.expectEqualStrings("中国电信", loc.isp.?);
    try testing.expectEqual(@as(f64, 34.05), loc.latitude.?);
    try testing.expectEqualStrings("America/Los_Angeles", loc.timezone.?);
    try testing.expectEqual(DataSource.merged, loc.source);
}

test "仅 MMDB 记录" {
    const asn = mmdb_mod.AsnRecord{ .asn = 15169, .organization = "Google LLC" };
    const loc = merge(try IpAddr.parse("8.8.8.8"), null, worldUs(), asn, false);
    try testing.expectEqualStrings("美国", loc.country.?);
    try testing.expectEqualStrings("US", loc.country_code.?);
    try testing.expectEqualStrings("California", loc.province.?);
    try testing.expectEqualStrings("Los Angeles", loc.city.?);
    try testing.expectEqual(@as(u32, 15169), loc.asn.?);
    try testing.expectEqualStrings("Google LLC", loc.isp.?);
    try testing.expectEqual(DataSource.mmdb, loc.source);
}

test "仅国内记录" {
    const cn = CnRegion.parse("中国|福建省|福州市|中国电信|CN");
    const loc = merge(try IpAddr.parse("1.2.3.4"), cn, null, null, false);
    try testing.expect(loc.is_china);
    try testing.expectEqualStrings("中国", loc.country.?);
    try testing.expectEqualStrings("福建省", loc.province.?);
    try testing.expectEqualStrings("福州市", loc.city.?);
    try testing.expectEqual(DataSource.ip2region, loc.source);
    try testing.expect(loc.latitude == null);
}

test "纯真数据源标记" {
    const cn = CnRegion.parse("澳大利亚|Queensland|Brisbane|0|AU");
    const loc = merge(try IpAddr.parse("1.0.0.1"), cn, null, null, true);
    try testing.expect(!loc.is_china);
    try testing.expectEqualStrings("澳大利亚", loc.country.?);
    try testing.expectEqualStrings("AU", loc.country_code.?);
    try testing.expectEqual(DataSource.qqwry, loc.source);
}

test "MMDB 有数据时国内未补任何字段则不标记 merged" {
    const cn = CnRegion.parse("Sweden|0|0|0|SE");
    const loc = merge(try IpAddr.parse("89.160.20.128"), cn, worldUs(), null, false);
    try testing.expectEqualStrings("US", loc.country_code.?);
    try testing.expectEqual(DataSource.mmdb, loc.source);
}

test "国内 ISP 补齐 MMDB 记录标记 merged" {
    const cn = CnRegion.parse("United States|Texas|0|Some ISP|US");
    const loc = merge(try IpAddr.parse("8.8.8.8"), cn, worldUs(), null, false);
    try testing.expectEqualStrings("Some ISP", loc.isp.?);
    try testing.expectEqual(DataSource.merged, loc.source);
}

test "ISP 回退 ASN 组织名" {
    const asn = mmdb_mod.AsnRecord{ .asn = 15169, .organization = "Google LLC" };
    const loc = merge(try IpAddr.parse("8.8.8.8"), null, null, asn, false);
    try testing.expectEqualStrings("Google LLC", loc.isp.?);
    try testing.expectEqualStrings("Google LLC", loc.as_org.?);
}

test "保留地址短路" {
    var scratch: Scratch = .{};
    const locator = Locator{};
    const loc = try locator.lookup(&scratch, try IpAddr.parse("10.1.2.3"));
    try testing.expect(loc.is_private);
    try testing.expect(!loc.isPublic());
    try testing.expectEqualStrings("局域网", loc.country.?);
    try testing.expectEqual(IpClass.private, loc.ip_class.?);
    try testing.expectEqual(DataSource.reserved, loc.source);
}

test "展示文本" {
    var buf: [128]u8 = undefined;
    const loc = merge(try IpAddr.parse("1.2.3.4"), CnRegion.parse("中国|广东省|深圳市|中国电信|CN"), null, null, false);
    try testing.expectEqualStrings("中国 广东省 深圳市 中国电信", loc.displayShort(&buf));

    var empty_buf: [32]u8 = undefined;
    const unknown = Location{ .ip = try IpAddr.parse("1.1.1.1") };
    try testing.expectEqualStrings("未知", unknown.displayShort(&empty_buf));
}

test "lookupIpv4 / lookupIpv6 数值入口与文本入口结果一致" {
    var scratch: Scratch = .{};
    const locator = Locator{};

    const by_number = try locator.lookupIpv4(&scratch, 0x0A00_0001); // 10.0.0.1
    const by_text = try locator.lookupStr(&scratch, "10.0.0.1");
    try testing.expect(by_number.is_private);
    try testing.expectEqual(by_text.ip_class.?, by_number.ip_class.?);
    try testing.expectEqual(by_text.source, by_number.source);

    const loop6 = try locator.lookupIpv6(&scratch, 1); // ::1
    try testing.expectEqual(IpClass.loopback, loop6.ip_class.?);
}

test "真实数据端到端（xdb + MMDB）" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const v4_path = "G:/Code/Rust/Pek.IP/data/ip2region_v4.xdb";
    const world_path = "G:/Code/Rust/Pek.IP/data/dbip-country-lite-2026-10.mmdb";
    const asn_path = "G:/Code/Rust/Pek.IP/data/dbip-asn-lite-2026-10.mmdb";

    var locator = Locator{};
    defer locator.deinit();

    if (std.Io.Dir.cwd().openFile(io, v4_path, .{})) |f| {
        f.close(io);
        locator.xdb_v4 = try xdb_mod.XdbReader.open(io, gpa, v4_path);
    } else |_| {
        std.debug.print("[SKIP] 无真实 xdb：{s}\n", .{v4_path});
        return;
    }
    if (std.Io.Dir.cwd().openFile(io, world_path, .{})) |f| {
        f.close(io);
        locator.world = try mmdb_mod.MmdbReader.open(io, gpa, world_path, .auto);
    } else |_| {}
    if (std.Io.Dir.cwd().openFile(io, asn_path, .{})) |f| {
        f.close(io);
        locator.world_asn = try mmdb_mod.MmdbReader.open(io, gpa, asn_path, .auto);
    } else |_| {}

    var scratch: Scratch = .{};
    var buf: [128]u8 = undefined;

    const cn = try locator.lookupStr(&scratch, "114.114.114.114");
    std.debug.print("[locator] 114.114.114.114 → {s}（{s}）\n", .{ cn.displayShort(&buf), cn.source.label() });
    try testing.expect(cn.is_china);
    try testing.expectEqualStrings("CN", cn.country_code.?);

    // 国内快路径：命中 ip2region 后不再查 MMDB（省 ~1.5 µs/次）
    if (locator.world != null) {
        var fast_scratch: Scratch = .{};
        const fast = try locator.lookupOptions(&fast_scratch, try IpAddr.parse("114.114.114.114"), .{
            .skip_world_for_china = true,
        });
        try testing.expectEqual(DataSource.ip2region, fast.source);
        try testing.expect(fast.latitude == null);
        try testing.expect(fast.timezone == null);
        // 省市仍然来自 ip2region，不能因为跳过 MMDB 就丢
        try testing.expectEqualStrings(cn.province.?, fast.province.?);
        try testing.expectEqualStrings(cn.city.?, fast.city.?);

        // 国外 IP 不受该开关影响：与不开开关的结果完全一致
        var slow_scratch: Scratch = .{};
        var fast_scratch2: Scratch = .{};
        const us_slow = try locator.lookupOptions(&slow_scratch, try IpAddr.parse("89.160.20.128"), .{});
        const us_fast = try locator.lookupOptions(&fast_scratch2, try IpAddr.parse("89.160.20.128"), .{
            .skip_world_for_china = true,
        });
        try testing.expectEqual(us_slow.source, us_fast.source);
        try testing.expectEqualStrings(us_slow.country_code.?, us_fast.country_code.?);
    }

    const us = try locator.lookupStr(&scratch, "8.8.8.8");
    std.debug.print("[locator] 8.8.8.8 → {s}（{s}）\n", .{ us.displayShort(&buf), us.source.label() });
    try testing.expectEqualStrings("US", us.country_code.?);
    if (locator.world_asn != null) try testing.expectEqual(@as(u32, 15169), us.asn.?);

    const local = try locator.lookupStr(&scratch, "192.168.1.1");
    try testing.expect(local.is_private);
}
