//! 极简 HTTP 客户端（`std.http.Client` 薄封装）：GET 字节 / POST JSON / GET 到文件。
//!
//! - HTTPS：默认加载**系统根证书**（`Certificate.Bundle.rescan`，Windows 用系统存储）；
//!   配置了 `CaFile` 时额外导入自定义 PEM（内网/自签平台）。
//! - 大小上限由调用方给（组件目录 1 MiB、签名 8 KiB、数据包 512 MiB）。
//! - 失败文案区分**传输层**（连接/超时）与 **HTTP 层**（状态码 + 响应片段）。
//!
//! ## 超时：复用 zzig 的成熟做法（不是自造看门狗）
//!
//! Zig 0.17.1 的 `std.http.Client` **没有生效的超时**：
//! `ConnectTcpOptions.timeout` 只是声明，`connectTcpOptions` 从不读取它（内部
//! `host.connect(io, port, .{ .mode = .stream })` 把超时丢掉）；`Client.zig` 全文仅此一处 timeout，
//! `RequestOptions` 没有；`Io.Operation` 无 `net_connect` 也就用不上 `Io.operateTimeout`。
//!
//! 但 Zig 0.17 提供了**原生并发取消**：`Io.concurrent(io, fn, args)` → `Future`，
//! `Future.cancel(io)` 会请求取消并**等待任务结束**（内部 join，不留悬空）。
//! 同生态 `zzig/src/http/http.zig` 的 `fetchBytesWithTimeout` 就是这么做的（已上线验证），
//! 本文件沿用同一机制，只把「轮询 atomic 标志」换成 `Io.Condition.waitTimeout`（事件驱动，无空转）。
//!
//! 因此这里的语义是：超时 → 取消请求并把线程收回来，**不会泄漏线程**。

const std = @import("std");

pub const Error = error{
    /// 传输层失败（连接/证书/DNS）
    TransportFailed,
    /// 超过总超时（见 `Client.timeout_ms`）
    Timeout,
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

/// 工作线程与等待方共用的同步原语。
/// Zig 0.17 已移除 `std.Thread.Mutex/Condition`，改用 `std.Io` 的实现（支持 `waitTimeout`）。
const Sync = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    done: bool = false,
};

/// 毫秒 → `Io.Timeout`（0 = 不限）。
fn msTimeout(ms: u32) std.Io.Timeout {
    return .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
        .clock = .real,
    } };
}

/// 在工作线程里跑 `worker(ctx)`，最多等 `timeout_ms`。
///
/// 返回 `true` = 超时（已 `Future.cancel` 并等任务结束，`ctx` 可安全回收）；
/// 返回 `false` = 任务已完成（`ctx` 归调用方）。
/// 并发不可用或 `timeout_ms == 0` 时退回同步执行，宁可没超时也不丢功能。
fn runWithTimeout(
    io: std.Io,
    sync: *Sync,
    ctx: *anyopaque,
    comptime worker: fn (*anyopaque) void,
    timeout_ms: u32,
) bool {
    if (timeout_ms == 0) {
        worker(ctx);
        return false;
    }

    var future = io.concurrent(worker, .{ctx}) catch {
        worker(ctx);
        return false;
    };

    const deadline = std.Io.Clock.real.now(io).nanoseconds + @as(i96, timeout_ms) * std.time.ns_per_ms;
    var timed_out = false;

    sync.mutex.lock(io) catch {
        // 被取消（极端情况）：按未超时处理，等它跑完
        _ = future.await(io);
        return false;
    };
    while (!sync.done) {
        const remain = deadline - std.Io.Clock.real.now(io).nanoseconds;
        if (remain <= 0) {
            timed_out = true;
            break;
        }
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromNanoseconds(remain),
            .clock = .real,
        } };
        sync.cond.waitTimeout(io, &sync.mutex, timeout) catch |err| switch (err) {
            error.Timeout => {
                timed_out = true;
                break;
            },
            else => {},
        };
    }
    sync.mutex.unlock(io);

    if (timed_out) {
        // 关键：cancel 会请求取消并等待任务真正结束（内部 join），所以不留悬空引用
        _ = future.cancel(io);
        return true;
    }
    _ = future.await(io);
    return false;
}

/// 单次请求的任务上下文。
///
/// 所有切片都**借用调用方**（url / payload / headers / out_path）：因为
/// `Future.cancel/await` 一定会先把任务收回，函数返回后调用方栈仍然有效。
const Job = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    http: *std.http.Client,
    method: std.http.Method = .GET,
    url: []const u8 = &.{},
    payload: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    out_path: []const u8 = &.{},
    limit: usize = 0,

    sync: Sync = .{},
    status: u16 = 0,
    body: ?[]u8 = null,
    err: ?anyerror = null,

    fn execute(self: *Job) anyerror!void {
        if (self.out_path.len > 0) {
            const file = try std.Io.Dir.cwd().createFile(self.io, self.out_path, .{});
            defer file.close(self.io);
            var buffer: [64 * 1024]u8 = undefined;
            var file_writer = file.writer(self.io, &buffer);
            const result = try self.http.fetch(.{
                .location = .{ .url = self.url },
                .method = self.method,
                .payload = self.payload,
                .extra_headers = self.headers,
                .response_writer = &file_writer.interface,
            });
            try file_writer.interface.flush();
            self.status = @backingInt(result.status);
            return;
        }

        var allocating = try std.Io.Writer.Allocating.initCapacity(self.gpa, @min(self.limit, 64 * 1024));
        errdefer allocating.deinit();
        const result = try self.http.fetch(.{
            .location = .{ .url = self.url },
            .method = self.method,
            .payload = self.payload,
            .extra_headers = self.headers,
            .response_writer = &allocating.writer,
        });
        if (allocating.written().len > self.limit) return error.BodyTooLarge;
        self.status = @backingInt(result.status);
        self.body = try allocating.toOwnedSlice();
    }

    fn workerMain(ctx: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        const outcome = self.execute();
        self.sync.mutex.lock(self.io) catch return;
        if (outcome) |_| {} else |e| self.err = e;
        self.sync.done = true;
        self.sync.cond.signal(self.io);
        self.sync.mutex.unlock(self.io);
    }
};

pub const Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    inner: std.http.Client,
    /// 单次请求**总超时**（毫秒；0 = 不限）。默认 120s——够慢速链下拉完 ~7 MB 数据包。
    timeout_ms: u32 = 120_000,

    /// 创建客户端并加载根证书（`ca_file` 非空时额外导入）。
    pub fn init(io: std.Io, gpa: std.mem.Allocator, ca_file: ?[]const u8) Error!Client {
        var client = Client{
            .io = io,
            .gpa = gpa,
            .inner = .{ .allocator = gpa, .io = io },
        };
        if (@hasDecl(std.http, "disable_tls") and std.http.disable_tls) return client;

        const now = std.Io.Clock.real.now(io);
        client.inner.ca_bundle.rescan(gpa, io, now) catch |err| return switch (err) {
            error.OutOfMemory => Error.OutOfMemory,
            else => Error.CertificateLoadFailed,
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

    fn mapError(err: anyerror) Error {
        return switch (err) {
            error.OutOfMemory => Error.OutOfMemory,
            error.BodyTooLarge => Error.BodyTooLarge,
            else => Error.TransportFailed,
        };
    }

    fn request(
        self: *Client,
        method: std.http.Method,
        url: []const u8,
        headers: []const std.http.Header,
        payload: ?[]const u8,
        limit: usize,
    ) Error!Response {
        var job = Job{
            .io = self.io,
            .gpa = self.gpa,
            .http = &self.inner,
            .method = method,
            .url = url,
            .payload = payload,
            .headers = headers,
            .limit = limit,
        };

        if (runWithTimeout(self.io, &job.sync, @ptrCast(&job), Job.workerMain, self.timeout_ms)) {
            return Error.Timeout;
        }
        if (job.err) |err| return mapError(err);
        const body = job.body orelse self.gpa.alloc(u8, 0) catch return Error.OutOfMemory;
        job.body = null; // 所有权转交调用方
        return .{ .status = job.status, .body = body };
    }

    /// GET 到文件（流式写入，用于数据包；**返回前完成落盘**）。
    pub fn getToFile(self: *Client, url: []const u8, headers: []const std.http.Header, path: []const u8) Error!u16 {
        var job = Job{
            .io = self.io,
            .gpa = self.gpa,
            .http = &self.inner,
            .method = .GET,
            .url = url,
            .headers = headers,
            .out_path = path,
        };

        if (runWithTimeout(self.io, &job.sync, @ptrCast(&job), Job.workerMain, self.timeout_ms)) {
            return Error.Timeout;
        }
        if (job.err) |err| return mapError(err);
        return job.status;
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

test "超时：慢任务被取消并收回，调用方立即返回" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Case = struct {
        sync: Sync = .{},
        io: std.Io,
        delay_ms: u32 = 300,
        finished: bool = false,

        fn worker(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // 模拟阻塞读：这里是一个可取消的睡眠
            std.Io.Timeout.sleep(msTimeout(self.delay_ms), self.io) catch {};
            self.sync.mutex.lock(self.io) catch return;
            self.finished = true;
            self.sync.done = true;
            self.sync.cond.signal(self.io);
            self.sync.mutex.unlock(self.io);
        }
    };

    var case = Case{ .io = io };
    const start = std.Io.Clock.real.now(io).nanoseconds;
    const timed_out = runWithTimeout(io, &case.sync, @ptrCast(&case), Case.worker, 40);
    const elapsed_ms = @divTrunc(std.Io.Clock.real.now(io).nanoseconds - start, std.time.ns_per_ms);

    try std.testing.expect(timed_out);
    try std.testing.expect(elapsed_ms < 250); // 没被 300ms 的任务拖住
}
