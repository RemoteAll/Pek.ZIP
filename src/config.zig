//! `Config/Ip.toml`：平台地址、数据目录、下载开关。
//!
//! 与 Rust `Pek.IP::config` 同口径（默认平台 `https://p.sc8.fun`，只改一行即可换平台）：
//!
//! ```toml
//! # RPanelServer 平台地址（固定，一般不改）
//! StoreUrl = "https://p.sc8.fun"
//! # 平台 Ed25519 公钥；非空 = 强制校验组件目录签名
//! PubKey = ""
//! # 本地数据目录 / 下载缓存 / 客户端状态
//! DataDir = "data"
//! CacheDir = "Data/IpCache"
//! StateDir = "Data/IpClient"
//! # 启动时是否允许自动注册/申请票据（v0.1 未接授权流程，预留）
//! AutoEnroll = true
//! # 是否下载 IPv6 xdb（约 37 MiB）
//! DownloadV6 = false
//! # 平台 https 自定义根证书（PEM，内网/自签平台）
//! # CaFile = "Config/ca.pem"
//! ```
//!
//! 解析器只支持「顶层 `Key = value`」这一子集（与模板一一对应，够用且无依赖）；
//! 相对路径一律按 `base` 解析。

const std = @import("std");

/// 默认 RPanelServer 平台地址（固定；一般无需修改）。
pub const DEFAULT_STORE_URL = "https://p.sc8.fun";

/// 内置配置模板（首次运行自动落盘）。
pub const TEMPLATE =
    \\# Pek.ZIP 配置（首次运行自动生成；只改需要的那几行）
    \\# RPanelServer 平台地址（固定，一般不改）
    \\StoreUrl = "https://p.sc8.fun"
    \\# 平台 Ed25519 公钥（64 位 hex 或 SPKI DER base64）；非空 = 强制校验组件目录签名
    \\PubKey = ""
    \\# 本地数据目录（xdb / mmdb 放这里）
    \\DataDir = "data"
    \\# 下载缓存目录（解压后的版本目录 + 缓存标记）
    \\CacheDir = "Data/IpCache"
    \\# 客户端状态目录（installId / 私钥 / License；授权流程预留）
    \\StateDir = "Data/IpClient"
    \\# 启动时是否自动注册/申请票据
    \\AutoEnroll = true
    \\# 是否下载 IPv6 xdb（约 37 MiB）
    \\DownloadV6 = false
    \\# 平台 https 自定义根证书（PEM 文件；内网/自签平台用）
    \\# CaFile = "Config/ca.pem"
    \\
;

pub const Error = error{
    ConfigDirCreateFailed,
    TemplateWriteFailed,
    ConfigReadFailed,
    ConfigTooLarge,
    ConfigParseFailed,
    OutOfMemory,
};

/// 运行配置。
pub const Config = struct {
    gpa: std.mem.Allocator,
    /// 解析基准目录（相对路径都按它拼）。
    base: []u8,
    store_url: []u8,
    pubkey: []u8,
    data_dir: []u8,
    cache_dir: []u8,
    state_dir: []u8,
    auto_enroll: bool = true,
    download_v6: bool = false,
    ca_file: ?[]u8 = null,

    pub fn deinit(self: *Config) void {
        const gpa = self.gpa;
        gpa.free(self.base);
        gpa.free(self.store_url);
        gpa.free(self.pubkey);
        gpa.free(self.data_dir);
        gpa.free(self.cache_dir);
        gpa.free(self.state_dir);
        if (self.ca_file) |p| gpa.free(p);
        self.* = undefined;
    }

    /// 读取 `{base}/Config/Ip.toml`；不存在时按内置模板生成。
    pub fn load(io: std.Io, gpa: std.mem.Allocator, base: []const u8) Error!Config {
        var cfg = Config{
            .gpa = gpa,
            .base = gpa.dupe(u8, base) catch return Error.OutOfMemory,
            .store_url = gpa.dupe(u8, DEFAULT_STORE_URL) catch return Error.OutOfMemory,
            .pubkey = gpa.dupe(u8, "") catch return Error.OutOfMemory,
            .data_dir = undefined,
            .cache_dir = undefined,
            .state_dir = undefined,
        };
        errdefer cfg.deinit();

        cfg.data_dir = try cfg.resolve("data");
        cfg.cache_dir = try cfg.resolve("Data/IpCache");
        cfg.state_dir = try cfg.resolve("Data/IpClient");

        const rel = std.fs.path.join(gpa, &.{ "Config", "Ip.toml" }) catch return Error.OutOfMemory;
        defer gpa.free(rel);
        const path = std.fs.path.join(gpa, &.{ base, rel }) catch return Error.OutOfMemory;
        defer gpa.free(path);

        std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse "Config") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return Error.ConfigDirCreateFailed,
        };

        const text = readOrCreate(io, gpa, path) catch |err| switch (err) {
            error.FileNotFound => return Error.ConfigReadFailed,
            error.StreamTooLong => return Error.ConfigTooLarge,
            else => return Error.ConfigReadFailed,
        };
        defer gpa.free(text);

        try cfg.applyToml(text);
        return cfg;
    }

    /// 解析 TOML 子集（顶层 `Key = value`）。
    fn applyToml(self: *Config, text: []const u8) Error!void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') continue; // 不支持的 section 直接跳过
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

            if (std.mem.eql(u8, key, "StoreUrl")) {
                const text_value = unquote(value);
                if (text_value.len > 0) try self.setStoreUrl(text_value);
            } else if (std.mem.eql(u8, key, "PubKey")) {
                try self.setPubKey(unquote(value));
            } else if (std.mem.eql(u8, key, "DataDir")) {
                const path = unquote(value);
                if (path.len > 0) try self.setPath(&self.data_dir, path);
            } else if (std.mem.eql(u8, key, "CacheDir")) {
                const path = unquote(value);
                if (path.len > 0) try self.setPath(&self.cache_dir, path);
            } else if (std.mem.eql(u8, key, "StateDir")) {
                const path = unquote(value);
                if (path.len > 0) try self.setPath(&self.state_dir, path);
            } else if (std.mem.eql(u8, key, "AutoEnroll")) {
                self.auto_enroll = parseBool(value) orelse self.auto_enroll;
            } else if (std.mem.eql(u8, key, "DownloadV6")) {
                self.download_v6 = parseBool(value) orelse self.download_v6;
            } else if (std.mem.eql(u8, key, "CaFile")) {
                const path = unquote(value);
                if (path.len > 0) {
                    const resolved = try self.resolve(path);
                    if (self.ca_file) |old| self.gpa.free(old);
                    self.ca_file = resolved;
                }
            }
        }
    }

    /// 相对路径按 base 解析为绝对/带前缀路径（新分配，替换目标字段）。
    fn setPath(self: *Config, field: *[]u8, value: []const u8) Error!void {
        const resolved = try self.resolve(value);
        self.gpa.free(field.*);
        field.* = resolved;
    }

    fn setStoreUrl(self: *Config, value: []const u8) Error!void {
        var trimmed = value;
        while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
        const dup = self.gpa.dupe(u8, trimmed) catch return Error.OutOfMemory;
        self.gpa.free(self.store_url);
        self.store_url = dup;
    }

    fn setPubKey(self: *Config, value: []const u8) Error!void {
        const dup = self.gpa.dupe(u8, value) catch return Error.OutOfMemory;
        self.gpa.free(self.pubkey);
        self.pubkey = dup;
    }

    fn resolve(self: *Config, value: []const u8) Error![]u8 {
        if (std.fs.path.isAbsolute(value)) {
            return self.gpa.dupe(u8, value) catch return Error.OutOfMemory;
        }
        return std.fs.path.join(self.gpa, &.{ self.base, value }) catch return Error.OutOfMemory;
    }
};

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn parseBool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) return false;
    return null;
}

/// 读配置文件；不存在时写模板再读。
fn readOrCreate(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.Io.Dir.cwd();
    if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.size > 1024 * 1024) return error.StreamTooLong;
        var buffer: [16 * 1024]u8 = undefined;
        var reader = file.reader(io, &buffer);
        return reader.interface.allocRemaining(gpa, .limited(1024 * 1024));
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try dir.writeFile(io, .{ .sub_path = path, .data = TEMPLATE });
    return gpa.dupe(u8, TEMPLATE);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "首次运行生成模板并解析默认值" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = "G:/Code/Zig/Pek.ZIP/.zig-cache/cfgtest";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};

    var cfg = try Config.load(io, gpa, base);
    defer cfg.deinit();
    try testing.expectEqualStrings(DEFAULT_STORE_URL, cfg.store_url);
    try testing.expectEqualStrings("", cfg.pubkey);
    try testing.expect(cfg.auto_enroll);
    try testing.expect(!cfg.download_v6);
    try testing.expect(std.mem.endsWith(u8, cfg.data_dir, "data"));
    try testing.expect(std.mem.endsWith(u8, cfg.cache_dir, "IpCache"));

    // 二次加载（已存在）必须幂等
    var cfg2 = try Config.load(io, gpa, base);
    defer cfg2.deinit();
    try testing.expectEqualStrings(cfg.store_url, cfg2.store_url);

    std.Io.Dir.cwd().deleteTree(io, base) catch {};
}

test "TOML 覆盖与路径解析" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = "G:/Code/Zig/Pek.ZIP/.zig-cache/cfgtest2";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    const path = base ++ "/Config/Ip.toml";
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/Config");
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data =
        \\StoreUrl = "http://127.0.0.1:5502/"
        \\PubKey = "abc"
        \\DataDir = "mydata"
        \\DownloadV6 = true
        \\AutoEnroll = false
        \\
        ,
    });

    var cfg = try Config.load(io, gpa, base);
    defer cfg.deinit();
    try testing.expectEqualStrings("http://127.0.0.1:5502", cfg.store_url);
    try testing.expectEqualStrings("abc", cfg.pubkey);
    try testing.expect(cfg.download_v6);
    try testing.expect(!cfg.auto_enroll);
    try testing.expect(std.mem.endsWith(u8, cfg.data_dir, "mydata"));

    std.Io.Dir.cwd().deleteTree(io, base) catch {};
}
