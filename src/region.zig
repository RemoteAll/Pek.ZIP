//! ip2region 地域字符串解析（零拷贝，字段切片直接指向 xdb 数据段）。
//!
//! xdb v3 标准格式：`国家|省份|城市|ISP|ISO-3166-1-alpha2`
//! （`中国|福建省|福州市|中国电信|CN`、`Australia|Queensland|0|0|AU`）。
//! 同时兼容旧版 v2：`国家|区域|省份|城市|ISP`（`中国|0|广东省|深圳市|电信`）。

const std = @import("std");
const country = @import("country.zig");

/// 解析后的地域记录（字段借用输入文本，不做任何分配）。
pub const CnRegion = struct {
    country: ?[]const u8 = null,
    /// ISO alpha-2（来自数据，或按中文名反查）。
    country_code: ?[]const u8 = null,
    province: ?[]const u8 = null,
    city: ?[]const u8 = null,
    /// 区县（纯真数据的第 4 段；xdb 不提供时为空）。
    district: ?[]const u8 = null,
    isp: ?[]const u8 = null,
    /// 是否中国（“中国”开头 / `CN`）。
    is_china: bool = false,
    /// 数据明确标记为保留/内网（`Reserved` / `内网IP` / `局域网` / `保留地址`）。
    reserved: bool = false,

    /// 解析地域字符串（v3，兼容 v2）。
    pub fn parse(text_in: []const u8) CnRegion {
        var fields_buf: [8][]const u8 = undefined;
        const fields = splitFields(text_in, &fields_buf);

        for (fields) |f| {
            if (isReservedMarker(f)) return .{ .reserved = true };
        }

        var country_text: ?[]const u8 = null;
        var province_text: ?[]const u8 = null;
        var city_text: ?[]const u8 = null;
        var isp_text: ?[]const u8 = null;
        var iso_text: ?[]const u8 = null;

        switch (fields.len) {
            0 => {},
            1 => country_text = fields[0],
            2 => {
                country_text = fields[0];
                province_text = fields[1];
            },
            3 => {
                country_text = fields[0];
                province_text = fields[1];
                city_text = fields[2];
            },
            4 => {
                // v2：country|region|province|city
                country_text = fields[0];
                province_text = fields[2];
                city_text = fields[3];
            },
            else => {
                const f0 = fields[0];
                const f1 = fields[1];
                const f2 = fields[2];
                const f3 = fields[3];
                const f4 = fields[4];
                if (isIsoLike(f4)) {
                    // v3：country|province|city|isp|iso
                    country_text = f0;
                    province_text = f1;
                    city_text = f2;
                    isp_text = f3;
                    iso_text = f4;
                } else if (std.mem.eql(u8, f1, "0") and !std.mem.eql(u8, f2, "0")) {
                    // v2：country|region|province|city|isp
                    country_text = f0;
                    province_text = f2;
                    city_text = f3;
                    isp_text = f4;
                } else {
                    // v3（ISO 缺失）
                    country_text = f0;
                    province_text = f1;
                    city_text = f2;
                    isp_text = f3;
                }
            },
        }

        var out = CnRegion{
            .country = clean(country_text),
            .province = clean(province_text),
            .city = clean(city_text),
            .isp = clean(isp_text),
        };

        const iso = clean(iso_text);
        if (iso != null and isIsoLike(iso.?)) {
            out.country_code = iso;
        } else if (out.country) |c| {
            out.country_code = country.codeFromNameZh(c);
        }

        const looks_china = (out.country != null and std.mem.startsWith(u8, out.country.?, "中国")) or
            (out.country_code != null and std.ascii.eqlIgnoreCase(out.country_code.?, "CN")) or
            (out.country == null and out.province != null and isChineseProvince(out.province.?));

        if (out.country_code == null and looks_china) out.country_code = "CN";
        if (looks_china) {
            if (out.country == null) {
                out.country = "中国";
            } else if (std.mem.eql(u8, out.country.?, "China")) {
                out.country = "中国";
            }
        }
        out.is_china = looks_china;
        return out;
    }

    /// 是否没有任何有效字段。
    pub fn isEmpty(self: CnRegion) bool {
        return self.country == null and self.province == null and
            self.city == null and self.isp == null;
    }

    /// 展示用国家名：优先按 ISO 查中文名，否则用数据原文。
    pub fn displayZh(self: CnRegion) ?[]const u8 {
        if (self.country_code) |code| {
            if (country.nameZh(code)) |name| return name;
        }
        return self.country;
    }

    /// 是否大中华区（`CN`/`HK`/`MO`/`TW`，或名称以“中国”开头）。
    pub fn isChinaRegion(self: CnRegion) bool {
        if (self.is_china) return true;
        if (self.country_code) |code| {
            if (std.ascii.eqlIgnoreCase(code, "HK") or
                std.ascii.eqlIgnoreCase(code, "MO") or
                std.ascii.eqlIgnoreCase(code, "TW")) return true;
        }
        if (self.country) |c| return std.mem.startsWith(u8, c, "中国");
        return false;
    }
};

fn splitFields(text: []const u8, out: *[8][]const u8) [][]const u8 {
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '|') {
            if (count < out.len) {
                out[count] = std.mem.trim(u8, text[start..i], " \t\r\n\u{3000}");
                count += 1;
            }
            start = i + 1;
        }
    }
    return out[0..count];
}

fn isReservedMarker(field: []const u8) bool {
    return std.ascii.eqlIgnoreCase(field, "reserved") or
        std.mem.eql(u8, field, "内网IP") or
        std.mem.eql(u8, field, "局域网") or
        std.mem.eql(u8, field, "保留地址");
}

fn clean(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    const trimmed = std.mem.trim(u8, text, " \t\r\n\u{3000}");
    if (trimmed.len == 0) return null;
    if (std.mem.eql(u8, trimmed, "0")) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "reserved")) return null;
    if (std.mem.eql(u8, trimmed, "内网IP") or
        std.mem.eql(u8, trimmed, "局域网") or
        std.mem.eql(u8, trimmed, "未知")) return null;
    return trimmed;
}

fn isIsoLike(value: []const u8) bool {
    const text = std.mem.trim(u8, value, " \t");
    if (text.len != 2) return false;
    if (!std.ascii.isAlphabetic(text[0]) or !std.ascii.isAlphabetic(text[1])) return false;
    return !std.mem.eql(u8, text, "00");
}

fn isChineseProvince(value: []const u8) bool {
    return std.mem.endsWith(u8, value, "省") or
        std.mem.endsWith(u8, value, "市") or
        std.mem.endsWith(u8, value, "自治区") or
        std.mem.endsWith(u8, value, "特别行政区") or
        std.mem.eql(u8, value, "台湾");
}

test "解析 v3 国内记录" {
    const r = CnRegion.parse("中国|福建省|福州市|中国电信|CN");
    try std.testing.expectEqualStrings("中国", r.country.?);
    try std.testing.expectEqualStrings("CN", r.country_code.?);
    try std.testing.expectEqualStrings("福建省", r.province.?);
    try std.testing.expectEqualStrings("福州市", r.city.?);
    try std.testing.expectEqualStrings("中国电信", r.isp.?);
    try std.testing.expect(r.is_china);
    try std.testing.expect(!r.reserved);
    try std.testing.expectEqualStrings("中国", r.displayZh().?);
}

test "解析 v3 国外记录" {
    const r = CnRegion.parse("Australia|Queensland|0|0|AU");
    try std.testing.expectEqualStrings("Australia", r.country.?);
    try std.testing.expectEqualStrings("AU", r.country_code.?);
    try std.testing.expectEqualStrings("Queensland", r.province.?);
    try std.testing.expect(r.city == null);
    try std.testing.expect(r.isp == null);
    try std.testing.expect(!r.is_china);
    try std.testing.expectEqualStrings("澳大利亚", r.displayZh().?);
}

test "解析 v2 国内记录" {
    const r = CnRegion.parse("中国|0|广东省|深圳市|电信");
    try std.testing.expectEqualStrings("中国", r.country.?);
    try std.testing.expectEqualStrings("CN", r.country_code.?);
    try std.testing.expectEqualStrings("广东省", r.province.?);
    try std.testing.expectEqualStrings("深圳市", r.city.?);
    try std.testing.expectEqualStrings("电信", r.isp.?);
    try std.testing.expect(r.is_china);
}

test "解析 v2 无国家记录" {
    const r = CnRegion.parse("0|0|浙江省|杭州市|0");
    try std.testing.expectEqualStrings("中国", r.country.?);
    try std.testing.expectEqualStrings("CN", r.country_code.?);
    try std.testing.expectEqualStrings("浙江省", r.province.?);
    try std.testing.expectEqualStrings("杭州市", r.city.?);
    try std.testing.expect(r.is_china);
}

test "Reserved 标记" {
    const texts = [_][]const u8{
        "0|0|Reserved|Reserved|Reserved",
        "0|0|内网IP|内网IP",
        "Reserved|0|0|0|0",
    };
    for (texts) |text| {
        const r = CnRegion.parse(text);
        try std.testing.expect(r.reserved);
        try std.testing.expect(r.isEmpty());
    }
}

test "大中华区判定" {
    try std.testing.expect(CnRegion.parse("中国|广东省|深圳市|电信|CN").isChinaRegion());
    try std.testing.expect(CnRegion.parse("中国香港|0|香港|HKBN|HK").isChinaRegion());
    try std.testing.expect(!CnRegion.parse("United States|Texas|0|0|US").isChinaRegion());
}
