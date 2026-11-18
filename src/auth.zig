//! 下载授权：零身份自动注册（installId + Ed25519）+ License 验签 + 一次性下载票据。
//!
//! 与 Rust `Pek.IP::auth` 和平台端 `Pek.RPanlServer::ipdb` **同一契约**（已按平台源码核对）：
//!
//! | 步骤 | 请求 | 关键字段 |
//! |------|------|----------|
//! | 注册 | `POST {origin}/api/ipdb/enroll` | `installId` / `clientPubKey` / `hostname` / `appName` / `machineId` / `clientVersion` |
//! | 票据 | `POST {origin}/api/ipdb/ticket` | `installId` / `dataset` / `version` / `nonce` / `ts` / `signature` |
//! | 下载 | `GET {票据 url}` | 平台校验票据签名、来源 IP、配额后才放行 |
//!
//! 待签名字节（与平台逐字节一致）：
//!
//! ```text
//! License: "pek-ip-license-v1\n{licenseId}\n{installId}\n{clientPubKey}\n{datasets,以逗号连接}\n{authMode}\n{issuedAt}\n{notAfter}\n{dailyQuota}"
//! 票据:    "pek-ip-ticket-v1\n{installId}\n{dataset}\n{version}\n{nonce}\n{ts}"
//! ```
//!
//! 身份持久化（`StateDir`）：`install.id`（32 位 hex）、`client.key`（**32 字节 seed 的 hex**，
//! 与 dhrust 的私钥文件格式一致）、`pubkey.txt`（平台公钥 TOFU）。签名用**标准 base64（带填充）**。
//!
//! 降级策略（与 Pek.IP 一致）：平台没有 `/api/ipdb/*`（HTTP 404/405）→ 返回 `error.Unsupported`，
//! 调用方回退公开下载；平台明确拒绝（401/403/业务 code != 0）→ 直接失败，**不回退**。

const std = @import("std");
const http_mod = @import("http.zig");

const Ed25519 = std.crypto.sign.Ed25519;

/// 授权流程错误。
pub const Error = error{
    /// 平台未启用授权接口（404/405）→ 可回退公开下载
    Unsupported,
    /// 已注册但等待管理员批准
    Pending,
    /// 客户端被吊销
    Revoked,
    /// 平台拒绝（401/403 / 业务错误码）
    Denied,
    /// 响应结构不符合契约
    BadResponse,
    /// 签名校验失败
    BadSignature,
    /// 本地身份文件损坏
    InvalidIdentity,
    /// 网络/读写失败
    IoFailed,
    OutOfMemory,
};

/// 平台侧客户端状态。
pub const Status = enum { pending, approved, revoked };

const MAX_INSTALL_ID = 64;
const MAX_URL = 2048;

/// 客户端身份与授权运行时。
pub const AuthClient = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    state_dir: []const u8,
    /// installId（8~64 位 [A-Za-z0-9._-]）。
    install_id_buf: [MAX_INSTALL_ID]u8 = @splat(0),
    install_id_len: usize = 0,
    /// 32 字节私钥 seed。
    seed: [32]u8 = @splat(0),
    key_pair: Ed25519.KeyPair,
    /// 客户端公钥 hex（64 字符）。
    pubkey_hex: [64]u8 = @splat(0),
    /// 平台公钥 hex（配置或 TOFU 落盘）。
    platform_pubkey_hex: [64]u8 = @splat(0),
    have_platform_pubkey: bool = false,
    /// 本进程内是否已拿到有效 License。
    licensed: bool = false,
    /// 平台不支持授权接口（本进程内缓存）。
    unsupported: bool = false,
    /// 客户端版本（审计用）。
    client_version: []const u8 = "zpk/0.1.0",

    pub fn installId(self: *const AuthClient) []const u8 {
        return self.install_id_buf[0..self.install_id_len];
    }

    pub fn pubKeyHex(self: *const AuthClient) []const u8 {
        return &self.pubkey_hex;
    }

    pub fn platformPubKeyHex(self: *const AuthClient) ?[]const u8 {
        return if (self.have_platform_pubkey) &self.platform_pubkey_hex else null;
    }

    /// 加载或创建身份（`state_dir` 下 install.id / client.key / pubkey.txt）。
    pub fn loadOrCreate(
        io: std.Io,
        gpa: std.mem.Allocator,
        state_dir: []const u8,
        platform_pubkey: ?[]const u8,
    ) Error!AuthClient {
        std.Io.Dir.cwd().createDirPath(io, state_dir) catch return Error.IoFailed;

        var self = AuthClient{
            .io = io,
            .gpa = gpa,
            .state_dir = state_dir,
            .key_pair = undefined,
        };

        // 1) installId
        const install_path = std.fs.path.join(gpa, &.{ state_dir, "install.id" }) catch return Error.OutOfMemory;
        defer gpa.free(install_path);
        if (readText(io, gpa, install_path, 128)) |text| {
            defer gpa.free(text);
            self.setInstallId(std.mem.trim(u8, text, " \t\r\n")) catch return Error.InvalidIdentity;
        } else |_| {
            var raw: [16]u8 = undefined;
            std.Io.random(io, &raw);
            var hex_buf: [32]u8 = undefined;
            _ = hexEncode(&raw, &hex_buf);
            writeFile(io, install_path, &hex_buf) catch return Error.IoFailed;
            self.setInstallId(&hex_buf) catch return Error.InvalidIdentity;
        }

        // 2) 私钥 seed（hex）
        const key_path = std.fs.path.join(gpa, &.{ state_dir, "client.key" }) catch return Error.OutOfMemory;
        defer gpa.free(key_path);
        if (readText(io, gpa, key_path, 256)) |text| {
            defer gpa.free(text);
            self.setSeed(std.mem.trim(u8, text, " \t\r\n")) catch return Error.InvalidIdentity;
        } else |_| {
            var seed: [32]u8 = undefined;
            std.Io.random(io, &seed);
            var hex_buf: [64]u8 = undefined;
            _ = hexEncode(&seed, &hex_buf);
            writeFile(io, key_path, &hex_buf) catch return Error.IoFailed;
            self.setSeed(&hex_buf) catch return Error.InvalidIdentity;
        }

        // 3) 平台公钥：配置优先，其次 TOFU 落盘，留空等待首次注册时学习
        if (platform_pubkey) |text| {
            if (text.len > 0) {
                if (parsePubkeyHex(text)) |key| {
                    self.setPlatformPubkey(&key);
                } else |_| return Error.InvalidIdentity;
            }
        } else {
            const pub_path = std.fs.path.join(gpa, &.{ state_dir, "pubkey.txt" }) catch return Error.OutOfMemory;
            defer gpa.free(pub_path);
            if (readText(io, gpa, pub_path, 128)) |text| {
                defer gpa.free(text);
                if (parsePubkeyHex(std.mem.trim(u8, text, " \t\r\n"))) |key| {
                    self.setPlatformPubkey(&key);
                } else |_| {}
            } else |_| {}
        }
        return self;
    }

    fn setInstallId(self: *AuthClient, text: []const u8) !void {
        if (text.len < 8 or text.len > MAX_INSTALL_ID) return error.Invalid;
        for (text) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return error.Invalid;
        }
        @memcpy(self.install_id_buf[0..text.len], text);
        self.install_id_len = text.len;
    }

    fn setSeed(self: *AuthClient, hex_text: []const u8) !void {
        var seed: [32]u8 = undefined;
        if (!hexDecode(hex_text, &seed)) return error.Invalid;
        self.seed = seed;
        self.key_pair = Ed25519.KeyPair.generateDeterministic(seed) catch return error.Invalid;
        const pk = self.key_pair.public_key.toBytes();
        _ = hexEncode(&pk, &self.pubkey_hex);
    }

    fn setPlatformPubkey(self: *AuthClient, key: *const [32]u8) void {
        _ = hexEncode(key, &self.platform_pubkey_hex);
        self.have_platform_pubkey = true;
    }

    /// 注册（幂等）并拿到 License；已批准则返回 `Ok`。
    pub fn ensureLicense(self: *AuthClient, origin: []const u8, client: *http_mod.Client) Error!void {
        if (self.licensed) return;
        if (self.unsupported) return Error.Unsupported;

        var body_buf: [512]u8 = undefined;
        const install = self.installId();
        const pubkey = self.pubKeyHex();
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"installId\":\"{s}\",\"clientPubKey\":\"{s}\",\"hostname\":\"\",\"appName\":\"Pek.ZIP\",\"machineId\":\"\",\"clientVersion\":\"{s}\"}}",
            .{ install, pubkey, self.client_version },
        ) catch return Error.OutOfMemory;

        const url = std.fmt.allocPrint(self.gpa, "{s}/api/ipdb/enroll", .{origin}) catch return Error.OutOfMemory;
        defer self.gpa.free(url);

        var response = client.postJson(url, body, 256 * 1024) catch |err| switch (err) {
            error.HttpStatus => return Error.Denied,
            else => return Error.IoFailed,
        };
        defer response.deinit(self.gpa);

        if (response.status == 404 or response.status == 405) {
            self.unsupported = true;
            return Error.Unsupported;
        }
        if (response.status == 401 or response.status == 403) return Error.Denied;

        const data = parseEnvelope(self.gpa, response.body) catch |err| return err;
        defer data.deinit();

        const object = switch (data.value) {
            .object => |obj| obj,
            else => return Error.BadResponse,
        };

        const status_text = jsonString(object, "status") orelse return Error.BadResponse;
        if (std.mem.eql(u8, status_text, "revoked")) return Error.Revoked;
        if (!std.mem.eql(u8, status_text, "approved")) return Error.Pending;

        // 平台公钥：配置/TOFU 已有则必须一致（防中间人替换），否则学习并落盘
        const platform_key_text = jsonString(object, "pubkey") orelse return Error.BadResponse;
        const platform_key = parsePubkeyHex(platform_key_text) catch return Error.BadResponse;
        if (self.have_platform_pubkey) {
            // 公钥固定：配置/TOFU 已有则必须一致（防中间人替换）
            var expected: [32]u8 = undefined;
            if (!hexDecode(&self.platform_pubkey_hex, &expected)) return Error.InvalidIdentity;
            if (!std.mem.eql(u8, &expected, &platform_key)) return Error.BadSignature;
        } else {
            self.setPlatformPubkey(&platform_key);
            const path = std.fs.path.join(self.gpa, &.{ self.state_dir, "pubkey.txt" }) catch return Error.OutOfMemory;
            defer self.gpa.free(path);
            writeFile(self.io, path, &self.platform_pubkey_hex) catch {};
        }

        // License + 签名校验
        const license_value = object.get("license") orelse return Error.BadResponse;
        switch (license_value) {
            .object => {},
            else => return Error.BadResponse,
        }
        const signature_text = jsonString(object, "signature") orelse return Error.BadResponse;

        const canonical = licenseCanonical(self.gpa, license_value.object) catch return Error.BadResponse;
        defer self.gpa.free(canonical);

        var sig_bytes: [64]u8 = undefined;
        if (!base64Decode64(signature_text, &sig_bytes)) return Error.BadSignature;
        const signature = Ed25519.Signature.fromBytes(sig_bytes);
        const verifying_key = Ed25519.PublicKey.fromBytes(platform_key) catch return Error.BadSignature;
        signature.verify(canonical, verifying_key) catch return Error.BadSignature;

        self.licensed = true;
    }

    /// 申请一次性下载票据，返回带票据的 URL（写入 `out`）。
    pub fn ticket(
        self: *AuthClient,
        origin: []const u8,
        client: *http_mod.Client,
        dataset: []const u8,
        version: []const u8,
        out: []u8,
    ) Error![]const u8 {
        try self.ensureLicense(origin, client);

        var nonce_raw: [16]u8 = undefined;
        std.Io.random(self.io, &nonce_raw);
        var nonce_buf: [32]u8 = undefined;
        _ = hexEncode(&nonce_raw, &nonce_buf);

        const now = std.Io.Clock.real.now(self.io);
        const ts: i64 = if (now.nanoseconds > 0) @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_s)) else 0;

        const canonical = std.fmt.allocPrint(self.gpa, "pek-ip-ticket-v1\n{s}\n{s}\n{s}\n{s}\n{d}", .{
            self.installId(), dataset, version, &nonce_buf, ts,
        }) catch return Error.OutOfMemory;
        defer self.gpa.free(canonical);

        const signature = self.key_pair.sign(canonical, null) catch return Error.BadSignature;
        var sig_text_buf: [128]u8 = undefined;
        const sig_text = base64Encode(&signature.toBytes(), &sig_text_buf);

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"installId\":\"{s}\",\"dataset\":\"{s}\",\"version\":\"{s}\",\"nonce\":\"{s}\",\"ts\":{d},\"signature\":\"{s}\"}}",
            .{ self.installId(), dataset, version, &nonce_buf, ts, sig_text },
        ) catch return Error.OutOfMemory;

        const url = std.fmt.allocPrint(self.gpa, "{s}/api/ipdb/ticket", .{origin}) catch return Error.OutOfMemory;
        defer self.gpa.free(url);

        var response = client.postJson(url, body, 256 * 1024) catch |err| switch (err) {
            error.HttpStatus => return Error.Denied,
            else => return Error.IoFailed,
        };
        defer response.deinit(self.gpa);

        if (response.status == 404 or response.status == 405) {
            self.unsupported = true;
            return Error.Unsupported;
        }
        if (response.status == 401 or response.status == 403) return Error.Denied;

        const data = parseEnvelope(self.gpa, response.body) catch |err| return err;
        defer data.deinit();
        const object = switch (data.value) {
            .object => |obj| obj,
            else => return Error.BadResponse,
        };
        const ticket_url = jsonString(object, "url") orelse return Error.BadResponse;

        // 只接受 https，或回环 http；且必须落在组件源下（防被引导到第三方）
        const ok_scheme = std.mem.startsWith(u8, ticket_url, "https://") or
            (std.mem.startsWith(u8, ticket_url, "http://") and
                (std.mem.startsWith(u8, origin, "http://127.0.0.1") or
                    std.mem.startsWith(u8, origin, "http://localhost") or
                    std.mem.startsWith(u8, origin, "http://[::1]")));
        if (!ok_scheme) return Error.Denied;
        if (!std.mem.startsWith(u8, ticket_url, origin)) return Error.Denied;
        if (ticket_url.len > out.len) return Error.OutOfMemory;
        @memcpy(out[0..ticket_url.len], ticket_url);
        return out[0..ticket_url.len];
    }
};

/// 解析十六进制公钥（32 字节裸公钥，或 44 字节 Ed25519 SPKI DER），返回 32 字节。
pub fn parsePubkeyHex(text_in: []const u8) ![32]u8 {
    var text = std.mem.trim(u8, text_in, " \t\r\n");
    if (std.mem.startsWith(u8, text, "0x")) text = text[2..];
    if (text.len == 64) {
        var out: [32]u8 = undefined;
        if (!hexDecode(text, &out)) return error.Invalid;
        return out;
    }
    if (text.len == 88) {
        var der: [44]u8 = undefined;
        if (!hexDecode(text, &der)) return error.Invalid;
        const spki = [_]u8{ 0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00 };
        if (!std.mem.eql(u8, der[0..12], &spki)) return error.Invalid;
        return der[12..44].*;
    }
    return error.Invalid;
}

/// 校验 base64 签名（公钥接受 hex 裸公钥或 SPKI DER）。
pub fn verifyBase64(pubkey_hex: []const u8, data: []const u8, sig_base64: []const u8) !void {
    const key_bytes = try parsePubkeyHex(pubkey_hex);
    var sig_bytes: [64]u8 = undefined;
    if (!base64Decode64(sig_base64, &sig_bytes)) return error.BadSignature;
    const signature = Ed25519.Signature.fromBytes(sig_bytes);
    const public_key = Ed25519.PublicKey.fromBytes(key_bytes) catch return error.BadSignature;
    signature.verify(data, public_key) catch return error.BadSignature;
}

const ParsedJson = struct {
    parsed: std.json.Parsed(std.json.Value),
    value: std.json.Value,

    fn deinit(self: ParsedJson) void {
        self.parsed.deinit();
    }
};

/// 解平台统一信封 `{code, message, data}`；code != 0 一律失败（不回退）。
fn parseEnvelope(gpa: std.mem.Allocator, body: []const u8) Error!ParsedJson {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return Error.BadResponse;
    var result = ParsedJson{ .parsed = parsed, .value = .null };
    errdefer result.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return Error.BadResponse,
    };
    const code: i64 = switch (root.get("code") orelse .null) {
        .integer => |v| v,
        else => -1,
    };
    if (code != 0) {
        const message = jsonString(root, "message") orelse "";
        std.debug.print("[pek-zip] 平台返回错误：code={d} message={s}\n", .{ code, message });
        return Error.Denied;
    }
    result.value = root.get("data") orelse .null;
    switch (result.value) {
        .object, .null => {},
        else => {},
    }
    return result;
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |v| v,
        .float => |v| @intFromFloat(v),
        else => null,
    };
}

/// License 待签名字节（字段顺序必须与平台一致）。
fn licenseCanonical(gpa: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    const license_id = jsonString(object, "licenseId") orelse return error.Invalid;
    const install_id = jsonString(object, "installId") orelse return error.Invalid;
    const client_pub_key = jsonString(object, "clientPubKey") orelse return error.Invalid;
    const auth_mode = jsonString(object, "authMode") orelse return error.Invalid;
    const issued_at = jsonInt(object, "issuedAt") orelse return error.Invalid;
    const not_after = jsonInt(object, "notAfter") orelse return error.Invalid;
    const daily_quota = jsonInt(object, "dailyQuota") orelse return error.Invalid;

    var datasets: std.ArrayList(u8) = .empty;
    defer datasets.deinit(gpa);
    if (object.get("datasets")) |value| {
        switch (value) {
            .array => |arr| {
                for (arr.items, 0..) |item, index| {
                    if (index > 0) try datasets.append(gpa, ',');
                    switch (item) {
                        .string => |s| try datasets.appendSlice(gpa, s),
                        else => return error.Invalid,
                    }
                }
            },
            else => return error.Invalid,
        }
    }

    return std.fmt.allocPrint(
        gpa,
        "pek-ip-license-v1\n{s}\n{s}\n{s}\n{s}\n{s}\n{d}\n{d}\n{d}",
        .{ license_id, install_id, client_pub_key, datasets.items, auth_mode, issued_at, not_after, daily_quota },
    );
}

fn readText(io: std.Io, gpa: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(gpa, .limited(limit));
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn hexEncode(bytes: []const u8, out: []u8) []const u8 {
    if (out.len < bytes.len * 2) return out[0..0];
    const chars = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = chars[byte >> 4];
        out[i * 2 + 1] = chars[byte & 0x0f];
    }
    return out[0 .. bytes.len * 2];
}

fn hexDecode(text: []const u8, out: []u8) bool {
    if (text.len != out.len * 2) return false;
    for (out, 0..) |*byte, i| {
        const hi = hexVal(text[i * 2]) orelse return false;
        const lo = hexVal(text[i * 2 + 1]) orelse return false;
        byte.* = (hi << 4) | lo;
    }
    return true;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// 标准 base64（带填充）编码。
fn base64Encode(data: []const u8, out: []u8) []const u8 {
    const encoder = std.base64.standard.Encoder;
    const size = encoder.calcSize(data.len);
    if (size > out.len) return out[0..0];
    return encoder.encode(out[0..size], data);
}

/// 标准 base64 解码到固定 64 字节（容忍 URL 安全字符与缺省填充）。
fn base64Decode64(text_in: []const u8, out: *[64]u8) bool {
    var normalized_buf: [128]u8 = undefined;
    var len: usize = 0;
    for (text_in) |c| {
        const ch: u8 = switch (c) {
            '-' => '+',
            '_' => '/',
            ' ', '\t', '\r', '\n' => continue,
            else => c,
        };
        if (len >= normalized_buf.len) return false;
        normalized_buf[len] = ch;
        len += 1;
    }
    // 补 padding 到 4 的倍数
    while (len % 4 != 0) {
        if (len >= normalized_buf.len) return false;
        normalized_buf[len] = '=';
        len += 1;
    }
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(normalized_buf[0..len]) catch return false;
    if (size != 64) return false;
    decoder.decode(out, normalized_buf[0..len]) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "hex / base64 / 公钥解析" {
    var digits: [8]u8 = undefined;
    try testing.expectEqualStrings("000102ff", hexEncode(&[_]u8{ 0, 1, 2, 255 }, &digits));

    var back: [4]u8 = undefined;
    try testing.expect(hexDecode("000102FF", &back));
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 255 }, &back);
    try testing.expect(!hexDecode("zz", &back));

    // 32 字节裸公钥（hex）
    var raw: [32]u8 = undefined;
    for (&raw, 0..) |*b, i| b.* = @intCast(i);
    var hex_text: [64]u8 = undefined;
    _ = hexEncode(&raw, &hex_text);
    const parsed = try parsePubkeyHex(&hex_text);
    try testing.expectEqualSlices(u8, &raw, &parsed);

    // SPKI DER（44 字节）也应接受
    const spki = [_]u8{ 0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00 } ++ raw;
    var der_hex: [88]u8 = undefined;
    _ = hexEncode(&spki, &der_hex);
    const parsed_der = try parsePubkeyHex(&der_hex);
    try testing.expectEqualSlices(u8, &raw, &parsed_der);

    try testing.expectError(error.Invalid, parsePubkeyHex("1234"));
}

test "Ed25519 签名往返（标准 base64 带填充）" {
    const seed: [32]u8 = @splat(7);
    const key_pair = try Ed25519.KeyPair.generateDeterministic(seed);
    const pk = key_pair.public_key.toBytes();
    var pk_hex: [64]u8 = undefined;
    _ = hexEncode(&pk, &pk_hex);

    const message = "pek-ip-ticket-v1\nabc\ndataset\n2026.10\nnonce\n123";
    const sig = try key_pair.sign(message, null);
    var sig_text_buf: [128]u8 = undefined;
    const sig_text = base64Encode(&sig.toBytes(), &sig_text_buf);
    try testing.expect(std.mem.endsWith(u8, sig_text, "="));

    try verifyBase64(&pk_hex, message, sig_text);
    try testing.expectError(error.BadSignature, verifyBase64(&pk_hex, "tampered", sig_text));

    // 容忍缺省填充
    const trimmed = std.mem.trimEnd(u8, sig_text, "=");
    try verifyBase64(&pk_hex, message, trimmed);
}

test "身份持久化与二次加载" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "G:/Code/Zig/Pek.ZIP/.zig-cache/authtest";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const first = try AuthClient.loadOrCreate(io, gpa, dir, null);
    const first_id = try gpa.dupe(u8, first.installId());
    defer gpa.free(first_id);
    const first_pub = try gpa.dupe(u8, first.pubKeyHex());
    defer gpa.free(first_pub);
    try testing.expectEqual(@as(usize, 32), first_id.len);
    try testing.expectEqual(@as(usize, 64), first_pub.len);

    const second = try AuthClient.loadOrCreate(io, gpa, dir, null);
    try testing.expectEqualStrings(first_id, second.installId());
    try testing.expectEqualStrings(first_pub, second.pubKeyHex());

    // 配置公钥后应被采纳
    const seeded: [32]u8 = @splat(9);
    const kp = try Ed25519.KeyPair.generateDeterministic(seeded);
    var pk_hex: [64]u8 = undefined;
    _ = hexEncode(&kp.public_key.toBytes(), &pk_hex);
    const third = try AuthClient.loadOrCreate(io, gpa, dir, &pk_hex);
    try testing.expectEqualStrings(&pk_hex, third.platformPubKeyHex().?);

    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}
