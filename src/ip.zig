//! IP 地址模型：解析、格式化、IPv4-mapped 归一、特殊用途地址分类。
//!
//! 与 Rust `Pek.IP` 的 `reserved.rs` / `types.rs` 逐字节对齐：
//! 内网/回环/链路本地/组播/文档/基准/保留/NAT64/ORCHID 一律在查库前短路，
//! 避免把 `10.0.0.1` 误判成某个公网位置。
//!
//! 全部为**零分配**实现：解析结果、标签都以值或静态切片返回。

const std = @import("std");

/// IP 地址（IPv4 存 32 位大端语义数值，IPv6 存 128 位大端语义数值）。
pub const IpAddr = union(enum) {
    v4: u32,
    v6: u128,

    pub const ParseError = error{InvalidIp};

    /// 解析 IP 文本（IPv4 / IPv6；容忍首尾空白；IPv6 支持 `::` 压缩、
    /// 末尾点分四段（`::ffff:1.2.3.4`）、`%zone` 后缀按忽略处理）。
    pub fn parse(text_in: []const u8) ParseError!IpAddr {
        const text = std.mem.trim(u8, text_in, " \t\r\n");
        if (text.len == 0) return error.InvalidIp;
        if (std.mem.indexOfScalar(u8, text, ':') != null) {
            return .{ .v6 = try parseV6(text) };
        }
        return .{ .v4 = try parseV4(text) };
    }

    /// 是否为 IPv4-mapped IPv6（`::ffff:a.b.c.d`）。
    pub fn isV4Mapped(self: IpAddr) bool {
        return switch (self) {
            .v4 => false,
            .v6 => |v| (v >> 32) == 0xffff,
        };
    }

    /// IPv4-mapped IPv6 归一为 IPv4（其余原样返回）。
    pub fn normalize(self: IpAddr) IpAddr {
        return switch (self) {
            .v4 => self,
            .v6 => |v| if ((v >> 32) == 0xffff) .{ .v4 = @truncate(v) } else self,
        };
    }

    /// 数值键（v4 用低 32 位；v6 用 128 位；跨族比较由调用方决定）。
    pub fn toU128(self: IpAddr) u128 {
        return switch (self) {
            .v4 => |v| v,
            .v6 => |v| v,
        };
    }

    /// 由 IPv4 数值构造。
    pub fn fromU32(value: u32) IpAddr {
        return .{ .v4 = value };
    }

    /// 由 IPv6 数值构造。
    pub fn fromU128(value: u128) IpAddr {
        return .{ .v6 = value };
    }

    /// 格式化为文本，写入 `buf`，返回实际切片（buf 至少 46 字节）。
    pub fn toString(self: IpAddr, buf: []u8) []const u8 {
        switch (self) {
            .v4 => |v| return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
                (v >> 24) & 0xff,
                (v >> 16) & 0xff,
                (v >> 8) & 0xff,
                v & 0xff,
            }) catch buf[0..0],
            .v6 => |v| return formatV6(v, buf),
        }
    }
};

/// 特殊地址分类（与 `Pek.IP::IpClass` 一一对应）。
pub const IpClass = enum {
    unspecified,
    loopback,
    private,
    cgnat,
    link_local,
    multicast,
    documentation,
    benchmark,
    shared,
    reserved,
    nat64,
    orchid,

    /// 中文标签（可直接作为“国家/地区”展示）。
    pub fn label(self: IpClass) []const u8 {
        return switch (self) {
            .unspecified => "未指定地址",
            .loopback => "回环地址",
            .private => "局域网",
            .cgnat => "运营商级 NAT",
            .link_local => "链路本地",
            .multicast => "组播地址",
            .documentation => "文档示例地址",
            .benchmark => "基准测试地址",
            .shared => "共享地址",
            .reserved => "保留地址",
            .nat64 => "NAT64 地址",
            .orchid => "ORCHID 地址",
        };
    }
};

/// 判断特殊用途网段；公网地址返回 `null`。
pub fn classify(ip_in: IpAddr) ?IpClass {
    return switch (ip_in.normalize()) {
        .v4 => |v| classifyV4(v),
        .v6 => |v| classifyV6(v),
    };
}

/// IPv4 特殊网段分类。
pub fn classifyV4(v: u32) ?IpClass {
    if (v == 0) return .unspecified;
    if (v & 0xff00_0000 == 0x7f00_0000) return .loopback; // 127.0.0.0/8
    if (v & 0xff00_0000 == 0x0a00_0000) return .private; // 10.0.0.0/8
    if (v & 0xfff0_0000 == 0xac10_0000) return .private; // 172.16.0.0/12
    if (v & 0xffff_0000 == 0xc0a8_0000) return .private; // 192.168.0.0/16
    if (v & 0xffc0_0000 == 0x6440_0000) return .cgnat; // 100.64.0.0/10
    if (v & 0xffff_0000 == 0xa9fe_0000) return .link_local; // 169.254.0.0/16
    if (v & 0xffff_ff00 == 0xc000_0000) return .reserved; // 192.0.0.0/24
    if (v & 0xffff_ff00 == 0xc000_0200) return .documentation; // 192.0.2.0/24
    if (v & 0xffff_ff00 == 0xc058_6300) return .reserved; // 192.88.99.0/24
    if (v & 0xfffe_0000 == 0xc612_0000) return .benchmark; // 198.18.0.0/15
    if (v & 0xffff_ff00 == 0xc633_6400) return .documentation; // 198.51.100.0/24
    if (v & 0xffff_ff00 == 0xcb00_7100) return .documentation; // 203.0.113.0/24
    if (v & 0xf000_0000 == 0xe000_0000) return .multicast; // 224.0.0.0/4
    if (v & 0xf000_0000 == 0xf000_0000) return .reserved; // 240.0.0.0/4
    if (v & 0xff00_0000 == 0x0000_0000) return .reserved; // 0.0.0.0/8
    return null;
}

/// IPv6 特殊网段分类。
pub fn classifyV6(v: u128) ?IpClass {
    const b = bytesBE(v);
    if (v == 0) return .unspecified;
    if (v == 1) return .loopback;
    if (std.mem.eql(u8, b[0..12], &[_]u8{ 0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0 })) return .nat64; // 64:ff9b::/96
    if (std.mem.eql(u8, b[0..8], &[_]u8{ 0x01, 0x00, 0, 0, 0, 0, 0, 0 })) return .shared; // 100::/64
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x0d and b[3] == 0xb8) return .documentation; // 2001:db8::/32
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x00 and (b[3] & 0xf0) == 0x10) return .orchid; // 2001:10::/28
    if (b[0] & 0xfe == 0xfc) return .private; // fc00::/7
    if (b[0] == 0xfe and b[1] & 0xc0 == 0x80) return .link_local; // fe80::/10
    if (b[0] == 0xff) return .multicast; // ff00::/8
    return null;
}

/// 大端字节序列（与 Rust `Ipv6Addr::octets()` 逐字节一致）。
fn bytesBE(v: u128) [16]u8 {
    return @bitCast(std.mem.nativeToBig(u128, v));
}

fn parseV4(text: []const u8) IpAddr.ParseError!u32 {
    var value: u32 = 0;
    var parts: usize = 0;
    var i: usize = 0;
    while (true) {
        const start = i;
        var part: u32 = 0;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
            part = part * 10 + (text[i] - '0');
            if (part > 255 or i - start >= 3) return error.InvalidIp;
        }
        if (i == start) return error.InvalidIp;
        value = (value << 8) | part;
        parts += 1;
        if (i == text.len) break;
        if (text[i] != '.' or parts == 4) return error.InvalidIp;
        i += 1;
    }
    if (parts != 4) return error.InvalidIp;
    return value;
}

fn parseV6(text_in: []const u8) IpAddr.ParseError!u128 {
    // 丢弃 %zone
    const zone = std.mem.indexOfScalar(u8, text_in, '%');
    const text = if (zone) |z| text_in[0..z] else text_in;
    if (text.len < 2) return error.InvalidIp;

    var groups: [8]u16 = @splat(0);
    var count: usize = 0;
    var gap: ?usize = null;
    var i: usize = 0;

    if (text[0] == ':') {
        if (text[1] != ':') return error.InvalidIp;
        gap = 0;
        i = 2;
        if (i == text.len) return 0;
    }

    while (i < text.len) {
        // 点分四段尾巴（只在最后一组允许；点必须出现在下一个冒号之前）
        const rest = text[i..];
        const dot = std.mem.indexOfScalar(u8, rest, '.');
        const colon = std.mem.indexOfScalar(u8, rest, ':');
        if (dot != null and (colon == null or dot.? < colon.?)) {
            const v4 = try parseV4(rest);
            if (count + 2 > 8) return error.InvalidIp;
            groups[count] = @truncate(v4 >> 16);
            groups[count + 1] = @truncate(v4 & 0xffff);
            count += 2;
            i = text.len;
            break;
        }

        var value: u32 = 0;
        var digits: usize = 0;
        while (i < text.len) : (i += 1) {
            const nibble: u32 = switch (text[i]) {
                '0'...'9' => text[i] - '0',
                'a'...'f' => text[i] - 'a' + 10,
                'A'...'F' => text[i] - 'A' + 10,
                else => break,
            };
            value = value * 16 + nibble;
            digits += 1;
            if (digits > 4) return error.InvalidIp;
        }
        if (digits == 0) return error.InvalidIp;
        if (count == 8) return error.InvalidIp;
        groups[count] = @intCast(value);
        count += 1;

        if (i == text.len) break;
        if (text[i] != ':') return error.InvalidIp;
        i += 1;
        if (i == text.len) return error.InvalidIp; // 单个结尾冒号非法
        if (text[i] == ':') {
            if (gap != null) return error.InvalidIp;
            gap = count;
            i += 1;
            if (i == text.len) break;
        }
    }

    if (gap) |g| {
        const tail = count - g;
        if (count >= 8) return error.InvalidIp;
        var k: usize = count;
        while (k > g) : (k -= 1) {
            groups[7 - (count - k)] = groups[k - 1];
        }
        var z = g;
        while (z < 8 - tail) : (z += 1) groups[z] = 0;
        count = 8;
    }
    if (count != 8) return error.InvalidIp;

    var out: u128 = 0;
    for (groups) |g| out = (out << 16) | g;
    return out;
}

fn hasColonAfter(text: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return false;
    return std.mem.indexOfScalar(u8, text[dot..], ':') != null;
}

fn formatV6(v: u128, buf: []u8) []const u8 {
    const b = bytesBE(v);
    var groups: [8]u16 = undefined;
    for (0..8) |idx| {
        groups[idx] = (@as(u16, b[idx * 2]) << 8) | b[idx * 2 + 1];
    }

    // 找最长连续 0 段（至少 2 段才压缩）
    var best_start: usize = 8;
    var best_len: usize = 0;
    var idx: usize = 0;
    while (idx < 8) {
        if (groups[idx] != 0) {
            idx += 1;
            continue;
        }
        const start = idx;
        while (idx < 8 and groups[idx] == 0) idx += 1;
        const len = idx - start;
        if (len > best_len and len >= 2) {
            best_len = len;
            best_start = start;
        }
    }

    var writer = std.Io.Writer.fixed(buf);
    const w = &writer;
    idx = 0;
    while (idx < 8) {
        if (idx == best_start) {
            w.writeAll("::") catch return buf[0..0];
            idx += best_len;
            if (idx == 8) return w.buffered();
            continue;
        }
        if (idx != 0 and idx != best_start + best_len) {
            w.writeByte(':') catch return buf[0..0];
        }
        w.print("{x}", .{groups[idx]}) catch return buf[0..0];
        idx += 1;
    }
    return w.buffered();
}

test "IPv4 解析与边界" {
    try std.testing.expectEqual(@as(u32, 0x7f00_0001), (try IpAddr.parse("127.0.0.1")).v4);
    try std.testing.expectEqual(@as(u32, 0), (try IpAddr.parse(" 0.0.0.0 ")).v4);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), (try IpAddr.parse("255.255.255.255")).v4);
    try std.testing.expectError(error.InvalidIp, IpAddr.parse("1.2.3"));
    try std.testing.expectError(error.InvalidIp, IpAddr.parse("1.2.3.256"));
    try std.testing.expectError(error.InvalidIp, IpAddr.parse("1.2.3.4.5"));
    try std.testing.expectError(error.InvalidIp, IpAddr.parse(""));
}

test "IPv6 解析" {
    try std.testing.expectEqual(@as(u128, 1), (try IpAddr.parse("::1")).v6);
    try std.testing.expectEqual(@as(u128, 0), (try IpAddr.parse("::")).v6);
    const full = try IpAddr.parse("2001:0db8:0000:0000:0000:ff00:0042:8329");
    const compact = try IpAddr.parse("2001:db8::ff00:42:8329");
    try std.testing.expectEqual(full.v6, compact.v6);
    const mapped = try IpAddr.parse("::ffff:192.168.1.10");
    try std.testing.expect(mapped.isV4Mapped());
    try std.testing.expectEqual(@as(u32, 0xc0a8_010a), mapped.normalize().v4);
    try std.testing.expectError(error.InvalidIp, IpAddr.parse("2001:db8:::1"));
    try std.testing.expectError(error.InvalidIp, IpAddr.parse("12345::1"));
}

test "IPv6 格式化与压缩规则" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("::1", (IpAddr{ .v6 = 1 }).toString(&buf));
    try std.testing.expectEqualStrings("::", (IpAddr{ .v6 = 0 }).toString(&buf));
    const v: u128 = (@as(u128, 0x2001) << 112) | (@as(u128, 0xdb8) << 96) | 1;
    try std.testing.expectEqualStrings("2001:db8::1", (IpAddr{ .v6 = v }).toString(&buf));
    try std.testing.expectEqualStrings("1.2.3.4", (IpAddr{ .v4 = 0x0102_0304 }).toString(&buf));
}

test "特殊地址分类与 Pek.IP 对齐" {
    const cases = [_]struct { text: []const u8, want: ?IpClass }{
        .{ .text = "8.8.8.8", .want = null },
        .{ .text = "1.1.1.1", .want = null },
        .{ .text = "0.0.0.0", .want = .unspecified },
        .{ .text = "127.0.0.2", .want = .loopback },
        .{ .text = "10.255.255.255", .want = .private },
        .{ .text = "172.15.255.255", .want = null },
        .{ .text = "172.16.0.0", .want = .private },
        .{ .text = "192.168.1.1", .want = .private },
        .{ .text = "100.64.0.1", .want = .cgnat },
        .{ .text = "169.254.10.10", .want = .link_local },
        .{ .text = "192.0.2.1", .want = .documentation },
        .{ .text = "198.18.0.1", .want = .benchmark },
        .{ .text = "198.51.100.1", .want = .documentation },
        .{ .text = "203.0.113.1", .want = .documentation },
        .{ .text = "224.0.0.1", .want = .multicast },
        .{ .text = "240.0.0.1", .want = .reserved },
        .{ .text = "255.255.255.255", .want = .reserved },
        .{ .text = "::", .want = .unspecified },
        .{ .text = "::1", .want = .loopback },
        .{ .text = "fc00::1", .want = .private },
        .{ .text = "fd12:3456::1", .want = .private },
        .{ .text = "fe80::1", .want = .link_local },
        .{ .text = "2001:db8::1", .want = .documentation },
        .{ .text = "ff02::1", .want = .multicast },
        .{ .text = "64:ff9b::1.2.3.4", .want = .nat64 },
        .{ .text = "100::1", .want = .shared },
        .{ .text = "::ffff:192.168.1.10", .want = .private },
        .{ .text = "::ffff:8.8.8.8", .want = null },
        .{ .text = "2001:4860:4860::8888", .want = null },
        .{ .text = "2400:3200::1", .want = null },
    };
    for (cases) |case| {
        const ip = try IpAddr.parse(case.text);
        try std.testing.expectEqual(case.want, classify(ip));
    }
}
