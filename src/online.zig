//! 在线 IP 归属地查询（对标 C# `DH.NIP::OnlineIp`）。
//!
//! 离线库没有记录时的兜底：调用第三方在线 API，并按常见四种响应格式自动识别：
//!
//! | 服务 | 关键字段 | 备注 |
//! |------|----------|------|
//! | 腾讯位置服务 | `result.ad_info.{nation,province,city,district}` + `result.isp` | 需 Key（`{1}` 占位符） |
//! | 百度地图 | `content.address_detail.{province,city,district}` + 顶层 `address` | 需 Key |
//! | 高德 | `status=1` + 顶层 `province/city/district` | 需 Key |
//! | ip-api.com | `status=success` + `country/regionName/city` + `isp` | 免费无 Key（默认） |
//!
//! 与 C# 版一致：网络失败/限流/解析失败一律返回 `null`（不抛异常影响业务）；
//! 区域拼接用 `–`（en dash，U+2013），空字段跳过。
//!
//! 默认不缓存：Pek.ZIP 的主路径是离线库，在线查询只作兜底；需要缓存时由调用方按 IP 自行缓存。

const std = @import("std");
const ip_mod = @import("ip.zig");
const http_mod = @import("http.zig");

/// 默认在线 API（ip-api.com，免费、无需 Key）。
pub const DEFAULT_SERVER = "http://ip-api.com/json/{0}";
/// 响应体积上限（防止异常响应吃内存）。
const MAX_RESPONSE_BYTES: usize = 256 * 1024;
/// 区域分隔符（与 C# `Join("–")` 一致）。
const SEPARATOR = "\u{2013}";

/// 解析结果（`gpa` 分配，调用方释放）。
pub const Record = struct {
    area: []u8,
    addr: []u8,

    pub fn deinit(self: Record, gpa: std.mem.Allocator) void {
        gpa.free(self.area);
        gpa.free(self.addr);
    }

    /// 合并展示（`area addr`，与 C# `GetAddress` 返回口味一致）。
    pub fn display(self: Record, buf: []u8) []const u8 {
        if (self.addr.len == 0) return self.area;
        return std.fmt.bufPrint(buf, "{s} {s}", .{ self.area, self.addr }) catch self.area;
    }
};

/// 解析在线 API 响应（四种格式自动识别）；无法识别或失败返回 `null`。
pub fn parse(gpa: std.mem.Allocator, json: []const u8) !?Record {
    if (json.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };

    // 1) 腾讯位置服务：result.ad_info + result.isp
    if (root.get("result")) |result| {
        if (result == .object) {
            const result_obj = result.object;
            const ad = if (result_obj.get("ad_info")) |v| (if (v == .object) v.object else null) else null;
            if (ad) |ad_obj| {
                const area = try joinParts(gpa, SEPARATOR, &.{
                    jsonString(ad_obj, "nation"),
                    jsonString(ad_obj, "province"),
                    jsonString(ad_obj, "city"),
                    jsonString(ad_obj, "district"),
                });
                const addr = try gpa.dupe(u8, jsonString(result_obj, "isp") orelse "");
                return .{ .area = area, .addr = addr };
            }
        }
    }

    // 2) 百度地图：content.address_detail + 顶层 address
    if (root.get("content")) |content| {
        if (content == .object) {
            const content_obj = content.object;
            const detail = if (content_obj.get("address_detail")) |v| (if (v == .object) v.object else null) else null;
            if (detail) |detail_obj| {
                const area = try joinParts(gpa, SEPARATOR, &.{
                    jsonString(detail_obj, "province"),
                    jsonString(detail_obj, "city"),
                    jsonString(detail_obj, "district"),
                });
                const addr = try gpa.dupe(u8, jsonString(root, "address") orelse "");
                return .{ .area = area, .addr = addr };
            }
        }
    }

    // 3) 高德：status = 1 + 顶层 province/city/district
    if (jsonStringInt(root, "status")) |status| {
        if (status == 1) {
            const area = try joinParts(gpa, SEPARATOR, &.{
                jsonString(root, "province"),
                jsonString(root, "city"),
                jsonString(root, "district"),
            });
            return .{ .area = area, .addr = try gpa.dupe(u8, "") };
        }
    }

    // 4) ip-api.com：status = success + country/regionName/city + isp
    if (jsonString(root, "status")) |status| {
        if (!std.mem.eql(u8, status, "success")) return null;
        const area = try joinParts(gpa, SEPARATOR, &.{
            jsonString(root, "country"),
            jsonString(root, "regionName"),
            jsonString(root, "city"),
        });
        return .{ .area = area, .addr = try gpa.dupe(u8, jsonString(root, "isp") orelse "") };
    }
    return null;
}

/// 在线查询客户端。
pub const Resolver = struct {
    gpa: std.mem.Allocator,
    /// 服务地址模板：`{0}` = IP，`{1}` = Key。
    server: []const u8 = DEFAULT_SERVER,
    /// API Key（为空则不携带）。
    key: []const u8 = "",

    /// 查询并解析；任何失败返回 `null`（与 C# 版一致，不影响业务）。
    pub fn lookup(self: Resolver, client: *http_mod.Client, ip_text: []const u8) ?Record {
        var ip_buf: [46]u8 = undefined;
        const normalized = normalizeIp(ip_text, &ip_buf) orelse return null;

        var url_buf: [1024]u8 = undefined;
        const url = buildUrl(&url_buf, self.server, normalized, self.key) orelse return null;

        var response = client.getBytes(url, &.{}, MAX_RESPONSE_BYTES) catch return null;
        defer response.deinit(self.gpa);
        if (!response.isSuccess()) return null;
        return parse(self.gpa, response.body) catch null;
    }
};

fn normalizeIp(text: []const u8, buf: []u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const parsed = ip_mod.IpAddr.parse(trimmed) catch return null;
    return parsed.toString(buf);
}

/// 替换 `{0}` / `{1}` 占位符。
fn buildUrl(buf: []u8, server: []const u8, ip_text: []const u8, key: []const u8) ?[]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    const w = &writer;
    var i: usize = 0;
    while (i < server.len) {
        if (i + 2 < server.len and server[i] == '{' and server[i + 2] == '}') {
            switch (server[i + 1]) {
                '0' => w.writeAll(ip_text) catch return null,
                '1' => w.writeAll(key) catch return null,
                else => w.writeAll(server[i .. i + 3]) catch return null,
            }
            i += 3;
            continue;
        }
        w.writeByte(server[i]) catch return null;
        i += 1;
    }
    return w.buffered();
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonStringInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |v| v,
        // 高德把 status 序列化成数字或字符串两种情况都见过
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn joinParts(gpa: std.mem.Allocator, separator: []const u8, parts: []const ?[]const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var first = true;
    for (parts) |part| {
        const text = part orelse continue;
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) continue;
        if (!first) try list.appendSlice(gpa, separator);
        try list.appendSlice(gpa, trimmed);
        first = false;
    }
    return list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "解析 ip-api.com" {
    const gpa = testing.allocator;
    const json =
        \\{"status":"success","country":"United States","regionName":"Virginia","city":"Ashburn","isp":"Google LLC","query":"8.8.8.8"}
    ;
    const rec = (try parse(gpa, json)).?;
    defer rec.deinit(gpa);
    try testing.expectEqualStrings("United States\u{2013}Virginia\u{2013}Ashburn", rec.area);
    try testing.expectEqualStrings("Google LLC", rec.addr);

    // 失败态
    try testing.expect((try parse(gpa, "{\"status\":\"fail\",\"message\":\"reserved range\"}")) == null);
}

test "解析腾讯位置服务" {
    const gpa = testing.allocator;
    const json =
        \\{"status":0,"message":"query ok","result":{"ip":"119.29.29.29","ad_info":{"nation":"中国","province":"广东省","city":"深圳市","district":"南山区"},"isp":"腾讯"}}
    ;
    const rec = (try parse(gpa, json)).?;
    defer rec.deinit(gpa);
    try testing.expectEqualStrings("中国\u{2013}广东省\u{2013}深圳市\u{2013}南山区", rec.area);
    try testing.expectEqualStrings("腾讯", rec.addr);
}

test "解析百度地图" {
    const gpa = testing.allocator;
    const json =
        \\{"address":"北京市海淀区","content":{"address_detail":{"province":"北京市","city":"北京市","district":"海淀区"}}}
    ;
    const rec = (try parse(gpa, json)).?;
    defer rec.deinit(gpa);
    try testing.expectEqualStrings("北京市\u{2013}北京市\u{2013}海淀区", rec.area);
    try testing.expectEqualStrings("北京市海淀区", rec.addr);
}

test "解析高德（status=1，字符串/数字都认）" {
    const gpa = testing.allocator;
    const rec = (try parse(gpa,
        \\{"status":"1","province":"浙江省","city":"杭州市","district":"西湖区"}
    )).?;
    defer rec.deinit(gpa);
    try testing.expectEqualStrings("浙江省\u{2013}杭州市\u{2013}西湖区", rec.area);
    try testing.expectEqualStrings("", rec.addr);
}

test "URL 占位符替换" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "http://ip-api.com/json/8.8.8.8",
        buildUrl(&buf, DEFAULT_SERVER, "8.8.8.8", "").?,
    );
    try testing.expectEqualStrings(
        "https://apis.map.qq.com/ws/location/v1/ip?ip=1.2.3.4&key=abc",
        buildUrl(&buf, "https://apis.map.qq.com/ws/location/v1/ip?ip={0}&key={1}", "1.2.3.4", "abc").?,
    );
}
