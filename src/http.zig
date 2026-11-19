//! 极简 HTTP 客户端（`std.http.Client` 薄封装）：GET 字节 / POST JSON / GET 到文件。
//!
//! - HTTPS：默认加载**系统根证书**（`Certificate.Bundle.rescan`，Windows 用系统存储）；
//!   配置了 `CaFile` 时额外导入自定义 PEM（内网/自签平台）。
//! - 大小上限由调用方给（组件目录 1 MiB、签名 8 KiB、数据包 512 MiB）。
//! - 失败文案区分**传输层**（连接/超时）与 **HTTP 层**（状态码 + 响应片段），
//!   便于一眼判断该查网络还是查平台。
//!
//! ## 为什么自己实现总超时（Zig 0.17.1 源码依据）
//!
//! 逐行核对 `lib/std` 后确认：**底层有超时能力，但 `std.http.Client` 没有接上**。
//!
//! - `Io.net.ConnectOptions.timeout` 是**真生效**的（`io.vtable.netConnectIp(io, addr, options)`，
//!   错误集含 `Io.Timeout.Error`）；`Socket.sendTimeout / receiveTimeout` 同理，走 `Io.operateTimeout`。
//! - 但 `std.http.Client.ConnectTcpOptions.timeout` 只是**声明了没用**：`connectTcpOptions`
//!   的函数体从头到尾没读过该字段，内部调 `host.connect(io, port, .{ .mode = .stream })` 把超时丢掉；
//!   而整个 `Client.zig` 里 `timeout` 仅此一处，`RequestOptions` 里没有。
//! - `Io.Operation` 只有 file_read/write、device_io_control、net_receive/send/read/write，
//!   **没有 net_connect**，所以 `Io.operateTimeout` 也补不了连接阶段；
//!   `Future.await/cancel` 也没有 timeout 参数（且文档标注 "Not threadsafe"）。
//!
//! 结论：要让"连上了但不回数据"这类挂死有界，只能自己做看门狗——请求跑在独立线程，
//! 主线程等 `timeout_ms` 后直接返回 `Error.Timeout`。代价：真卡死时那个线程会被 detach，
//! 结束后自行释放（不 join、不阻塞调用方），因此 `timeout_ms` 不宜设得过短。

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

/// 以毫秒构造 `Io.Timeout`（0 = 不限）。
fn msTimeout(ms: u32) std.Io.Timeout {
    return .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
        .clock = .real,
    } };
}

/// 工作线程与等待方共用的同步原语。
/// Zig 0.17 已移除 `std.Thread.Mutex/Condition`，改用 `std.Io` 的实现（支持 `waitTimeout`）。
const Sync = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    done: bool = false,
    /// 等待方已放弃：worker 结束时自行释放资源。
    abandoned: bool = false,
};

/// 通用看门狗：`worker(ctx)` 在独立线程里跑，主线程最多等 `timeout_ms`。
///
/// 返回 `true` = 超时（`ctx` 所有权转给 worker，由它结束时自行释放）；
/// 返回 `false` = worker 已结束（`ctx` 仍归调用方）。
/// `timeout_ms == 0` 或线程起不来时同步执行并返回 `false`（宁可没超时，也不能丢功能）。
fn supervise(io: std.Io, sync: *Sync, ctx: *anyopaque, comptime worker: fn (*anyopaque) void, timeout_ms: u32) bool {
    if (timeout_ms == 0) {
        worker(ctx);
        return false;
    }

    const thread = std.Thread.spawn(.{}, worker, .{ctx}) catch {
        worker(ctx);
        return false;
    };

    const timeout = msTimeout(timeout_ms);

    sync.mutex.lock(io) catch {
        // 被取消（极端情况）：不给超时语义，直接等它跑完
        thread.join();
        return false;
    };
    var timed_out = false;
    while (!sync.done) {
        sync.cond.waitTimeout(io, &sync.mutex, timeout) catch |err| switch (err) {
            error.Timeout => {
                timed_out = true;
                break;
            },
            // 被取消：按未超时处理，让下面 join 等它
            else => break,
        };
    }
    if (timed_out) sync.abandoned = true;
    sync.mutex.unlock(io);

    if (timed_out) {
        thread.detach();
        return true;
    }
    thread.join();
    return false;
}

/// 单次请求的任务槽（**堆分配**）：worker 只碰这个槽，绝不引用调用方栈。
const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    ca_file: ?[]u8 = null,
    method: std.http.Method = .GET,
    url: []u8 = &.{},
    payload: []u8 = &.{},
    out_path: []u8 = &.{},
    limit: usize = 0,
    header_names: [8][64]u8 = undefined,
    header_values: [8][256]u8 = undefined,
    header_count: usize = 0,

    sync: Sync = .{},
    status: u16 = 0,
    body: ?[]u8 = null,
    err: ?anyerror = null,

    fn headerSlices(self: *Job) [8]std.http.Header {
        var slices: [8]std.http.Header = undefined;
        for (0..self.header_count) |i| {
            slices[i] = .{
                .name = std.mem.sliceTo(&self.header_names[i], 0),
                .value = std.mem.sliceTo(&self.header_values[i], 0),
            };
        }
        return slices;
    }

    /// 真正干活：**自建** `std.http.Client`（超时后调用方可能已 deinit 自己的 client）。
    fn execute(self: *Job) anyerror!void {
        var client = std.http.Client{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();

        if (!(@hasDecl(std.http, "disable_tls") and std.http.disable_tls)) {
            const now = std.Io.Clock.real.now(self.io);
            try client.ca_bundle.rescan(self.gpa, self.io, now);
            if (self.ca_file) |path| {
                try client.ca_bundle.addCertsFromFilePath(self.gpa, self.io, now, std.Io.Dir.cwd(), path);
            }
        }

        var slices = self.headerSlices();
        const extra = slices[0..self.header_count];
        const payload: ?[]const u8 = if (self.payload.len > 0) self.payload else null;

        if (self.out_path.len > 0) {
            const file = try std.Io.Dir.cwd().createFile(self.io, self.out_path, .{});
            defer file.close(self.io);
            var buffer: [64 * 1024]u8 = undefined;
            var file_writer = file.writer(self.io, &buffer);
            const result = try client.fetch(.{
                .location = .{ .url = self.url },
                .method = self.method,
                .payload = payload,
                .extra_headers = extra,
                .response_writer = &file_writer.interface,
            });
            try file_writer.interface.flush();
            self.status = @backingInt(result.status);
            return;
        }

        var allocating = try std.Io.Writer.Allocating.initCapacity(self.gpa, @min(self.limit, 64 * 1024));
        errdefer allocating.deinit();
        const result = try client.fetch(.{
            .location = .{ .url = self.url },
            .method = self.method,
            .payload = payload,
            .extra_headers = extra,
            .response_writer = &allocating.writer,
        });
        if (allocating.written().len > self.limit) return error.BodyTooLarge;
        self.status = @backingInt(result.status);
        self.body = try allocating.toOwnedSlice();
    }

    fn workerMain(self: *Job) void {
        const outcome = self.execute();

        self.sync.mutex.lock(self.io) catch return;
        if (self.sync.abandoned) {
            // 调用方已放弃：连槽一起由工作线程回收
            self.sync.mutex.unlock(self.io);
            self.destroy();
            return;
        }
        if (outcome) |_| {} else |e| self.err = e;
        self.sync.done = true;
        self.sync.cond.signal(self.io);
        self.sync.mutex.unlock(self.io);
    }

    fn destroy(self: *Job) void {
        const gpa = self.gpa;
        gpa.free(self.url);
        if (self.payload.len > 0) gpa.free(self.payload);
        if (self.out_path.len > 0) gpa.free(self.out_path);
        if (self.ca_file) |text| gpa.free(text);
        if (self.body) |bytes| gpa.free(bytes);
        gpa.destroy(self);
    }

    fn workerOf(ctx: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        self.workerMain();
    }
};

pub const Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    inner: std.http.Client,
    /// 自定义根证书 PEM 路径（自己持有一份，超时线程要用）。
    ca_file: ?[]u8 = null,
    /// 单次请求**总超时**（毫秒；0 = 不限）。默认 120s——够慢速链下拉完 ~7 MB 数据包。
    timeout_ms: u32 = 120_000,

    /// 创建客户端并加载根证书（`ca_file` 非空时额外导入）。
    pub fn init(io: std.Io, gpa: std.mem.Allocator, ca_file: ?[]const u8) Error!Client {
        var client = Client{
            .io = io,
            .gpa = gpa,
            .inner = .{ .allocator = gpa, .io = io },
        };
        if (ca_file) |path| {
            client.ca_file = gpa.dupe(u8, path) catch return Error.OutOfMemory;
        }
        if (@hasDecl(std.http, "disable_tls") and std.http.disable_tls) return client;

        const now = std.Io.Clock.real.now(io);
        client.inner.ca_bundle.rescan(gpa, io, now) catch |err| {
            if (client.ca_file) |text| gpa.free(text);
            client.ca_file = null;
            return switch (err) {
                error.OutOfMemory => Error.OutOfMemory,
                else => Error.CertificateLoadFailed,
            };
        };
        if (client.ca_file) |path| {
            client.inner.ca_bundle.addCertsFromFilePath(gpa, io, now, std.Io.Dir.cwd(), path) catch {
                gpa.free(path);
                client.ca_file = null;
                return Error.CertificateLoadFailed;
            };
        }
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.inner.deinit();
        if (self.ca_file) |text| {
            self.gpa.free(text);
            self.ca_file = null;
        }
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

    fn newJob(
        self: *Client,
        method: std.http.Method,
        url: []const u8,
        headers: []const std.http.Header,
        payload: ?[]const u8,
        limit: usize,
        out_path: []const u8,
    ) Error!*Job {
        const gpa = self.gpa;
        const job = gpa.create(Job) catch return Error.OutOfMemory;
        job.* = .{ .gpa = gpa, .io = self.io, .method = method, .limit = limit };

        job.url = gpa.dupe(u8, url) catch {
            gpa.destroy(job);
            return Error.OutOfMemory;
        };
        if (payload) |bytes| {
            if (bytes.len > 0) {
                job.payload = gpa.dupe(u8, bytes) catch {
                    job.destroy();
                    return Error.OutOfMemory;
                };
            }
        }
        if (out_path.len > 0) {
            job.out_path = gpa.dupe(u8, out_path) catch {
                job.destroy();
                return Error.OutOfMemory;
            };
        }
        if (self.ca_file) |text| {
            job.ca_file = gpa.dupe(u8, text) catch {
                job.destroy();
                return Error.OutOfMemory;
            };
        }
        job.header_count = @min(headers.len, job.header_names.len);
        for (headers[0..job.header_count], 0..) |header, i| {
            const name = header.name[0..@min(header.name.len, job.header_names[i].len - 1)];
            const value = header.value[0..@min(header.value.len, job.header_values[i].len - 1)];
            @memcpy(job.header_names[i][0..name.len], name);
            job.header_names[i][name.len] = 0;
            @memcpy(job.header_values[i][0..value.len], value);
            job.header_values[i][value.len] = 0;
        }
        return job;
    }

    fn request(
        self: *Client,
        method: std.http.Method,
        url: []const u8,
        headers: []const std.http.Header,
        payload: ?[]const u8,
        limit: usize,
    ) Error!Response {
        // 不设超时：走原路径，省一次线程与客户端创建
        if (self.timeout_ms == 0) {
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
            }) catch |err| return mapError(err);

            if (allocating.written().len > limit) return Error.BodyTooLarge;
            const body = allocating.toOwnedSlice() catch return Error.OutOfMemory;
            owned = true;
            return .{ .status = @backingInt(result.status), .body = body };
        }

        const job = try self.newJob(method, url, headers, payload, limit, &.{});
        if (supervise(self.io, &job.sync, @ptrCast(job), Job.workerOf, self.timeout_ms)) {
            return Error.Timeout; // job 已转交工作线程
        }
        defer job.destroy();
        if (job.err) |err| return mapError(err);
        const body = job.body orelse try self.gpa.alloc(u8, 0);
        job.body = null; // 所有权转交调用方
        return .{ .status = job.status, .body = body };
    }

    /// GET 到文件（流式写入，用于数据包；**返回前完成落盘**）。
    pub fn getToFile(self: *Client, url: []const u8, headers: []const std.http.Header, path: []const u8) Error!u16 {
        if (self.timeout_ms == 0) {
            const file = std.Io.Dir.cwd().createFile(self.io, path, .{}) catch return Error.TransportFailed;
            defer file.close(self.io);

            var buffer: [64 * 1024]u8 = undefined;
            var file_writer = file.writer(self.io, &buffer);
            const result = self.inner.fetch(.{
                .location = .{ .url = url },
                .method = .GET,
                .extra_headers = headers,
                .response_writer = &file_writer.interface,
            }) catch |err| return mapError(err);
            file_writer.interface.flush() catch return Error.TransportFailed;
            return @backingInt(result.status);
        }

        const job = try self.newJob(.GET, url, headers, null, 0, path);
        if (supervise(self.io, &job.sync, @ptrCast(job), Job.workerOf, self.timeout_ms)) {
            return Error.Timeout;
        }
        defer job.destroy();
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

test "看门狗：超时立即返回且不阻塞，worker 自行收尾" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Case = struct {
        sync: Sync = .{},
        gpa: std.mem.Allocator,
        io: std.Io,
        delay_ms: u32 = 150,

        fn worker(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.Io.Timeout.sleep(msTimeout(self.delay_ms), self.io) catch {};
            self.sync.mutex.lock(self.io) catch return;
            if (self.sync.abandoned) {
                self.sync.mutex.unlock(self.io);
                self.gpa.destroy(self);
                return;
            }
            self.sync.done = true;
            self.sync.cond.signal(self.io);
            self.sync.mutex.unlock(self.io);
        }
    };

    // 1) 超时：30ms << worker 的 150ms，调用方必须马上返回
    const slow = try gpa.create(Case);
    slow.* = .{ .gpa = gpa, .io = io };
    const start = std.Io.Clock.real.now(io).nanoseconds;
    const timed_out = supervise(io, &slow.sync, @ptrCast(slow), Case.worker, 30);
    const elapsed_ms = @divTrunc(std.Io.Clock.real.now(io).nanoseconds - start, std.time.ns_per_ms);
    try std.testing.expect(timed_out);
    try std.testing.expect(elapsed_ms < 150);
    // slow 已交给 worker；这里只等它跑完（若重复释放，testing.allocator 会报错）
    std.Io.Timeout.sleep(msTimeout(250), io) catch {};

    // 2) 不超时：worker 先完成，槽仍归调用方
    const fast = try gpa.create(Case);
    fast.* = .{ .gpa = gpa, .io = io };
    try std.testing.expect(!supervise(io, &fast.sync, @ptrCast(fast), Case.worker, 5000));
    try std.testing.expect(fast.sync.done);
    gpa.destroy(fast);
}
