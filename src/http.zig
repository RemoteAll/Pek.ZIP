//! 极简 HTTP 客户端（`std.http.Client` 薄封装）：GET 字节 / POST JSON / GET 到文件。
//!
//! - HTTPS：默认加载**系统根证书**（`Certificate.Bundle.rescan`，Windows 用系统存储）；
//!   配置了 `CaFile` 时额外导入自定义 PEM（内网/自签平台）。
//! - 大小上限由调用方给（组件目录 1 MiB、签名 8 KiB、数据包 512 MiB）。
//! - 失败文案区分**传输层**（连接/超时）与 **HTTP 层**（状态码 + 响应片段），
//!   便于一眼判断该查网络还是查平台。
//!
//! 注意：v0.1 未设置单请求超时（std 0.17 的 `Client` 未暴露 per-request 超时；
//! 下载在后台线程执行，卡住不影响业务查询）。收紧时在 `fetch` 外挂 `Io.Timeout`。

const std = @import("std");

pub const Error = error{
    /// 传输层失败（连接/证书/DNS）
    TransportFailed,
    /// HTTP 状态非 2xx
    HttpStatus,
    /// 响应体超过上限
    BodyTooLarge,
    /// 证书加载失败
    CertificateLoadFailed,
    OutOfMemory,
};

/// 一次响应（body 由调用方释放）。
pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
        self.body = &.{};
    }

    pub fn isSuccess(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }

    /// 响应体前缀（日志用，避免整段倾倒）。
    pub fn snippet(self: Response, max: usize) []const u8 {
        return self.body[0..@min(self.body.len, max)];
    }
};

pub const Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    inner: std.http.Client,

    /// 创建客户端并加载根证书（`ca_file` 非空时额外导入）。
    pub fn init(io: std.Io, gpa: std.mem.Allocator, ca_file: ?[]const u8) Error!Client {
        var client = Client{
            .io = io,
            .gpa = gpa,
            .inner = .{ .allocator = gpa, .io = io },
        };
        if (@hasDecl(std.http, "disable_tls") and std.http.disable_tls) return client;

        const now = std.Io.Clock.real.now(io);
        client.inner.ca_bundle.rescan(gpa, io, now) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.CertificateLoadFailed,
        };
        if (ca_file) |path| {
            client.inner.ca_bundle.addCertsFromFilePath(gpa, io, now, std.Io.Dir.cwd(), path) catch {
                return Error.CertificateLoadFailed;
            };
        }
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.inner.deinit();
    }

    /// GET（上限 `limit` 字节）。
    pub fn getBytes(self: *Client, url: []const u8, headers: []const std.http.Header, limit: usize) Error!Response {
        return self.request(.GET, url, headers, null, limit);
    }

    /// POST JSON。
    pub fn postJson(self: *Client, url: []const u8, json_body: []const u8, limit: usize) Error!Response {
        var content_type = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
        return self.request(.POST, url, &content_type, json_body, limit);
    }

    fn request(
        self: *Client,
        method: std.http.Method,
        url: []const u8,
        headers: []const std.http.Header,
        payload: ?[]const u8,
        limit: usize,
    ) Error!Response {
        var allocating = std.Io.Writer.Allocating.initCapacity(self.gpa, @min(limit, 64 * 1024)) catch
            return Error.OutOfMemory;
        var owned = false;
        defer if (!owned) allocating.deinit();

        const result = self.inner.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .extra_headers = headers,
            .response_writer = &allocating.writer,
        }) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.TransportFailed,
        };

        if (allocating.written().len > limit) return Error.BodyTooLarge;
        const body = allocating.toOwnedSlice() catch return Error.OutOfMemory;
        owned = true;
        return .{ .status = @backingInt(result.status), .body = body };
    }

    /// GET 到文件（流式写入，用于数据包；**返回前完成落盘**）。
    pub fn getToFile(self: *Client, url: []const u8, headers: []const std.http.Header, path: []const u8) Error!u16 {
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{}) catch return Error.TransportFailed;
        defer file.close(self.io);

        var buffer: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(self.io, &buffer);
        const result = self.inner.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = headers,
            .response_writer = &file_writer.interface,
        }) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.TransportFailed,
        };
        file_writer.interface.flush() catch return Error.TransportFailed;
        return @backingInt(result.status);
    }
};

test "非法 URL 返回传输层失败" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = Client.init(io, gpa, null) catch |err| switch (err) {
        // CI/受限环境没有根证书也算正常：只验证不 panic
        error.CertificateLoadFailed => return,
        else => return err,
    };
    defer client.deinit();

    const result = client.getBytes("http://127.0.0.1:1/not-there", &.{}, 1024);
    try std.testing.expectError(Error.TransportFailed, result);
}
