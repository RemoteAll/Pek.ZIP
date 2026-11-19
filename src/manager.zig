//! 启动时异步数据管理：本地有就立即用，缺了就在**后台线程**从 RPanelServer 拉取并热替换。
//!
//! ## 启动顺序（`Manager.start`）
//!
//! 1. 读 `Config/Ip.toml`（不存在按模板生成）；
//! 2. **同步**加载本地数据（`data/` 优先 → 下载缓存次之），mmap 打开，毫秒级；
//!    —— 到这一步查询已可用（哪怕一个库都没有：内网/保留地址照常识别）；
//! 3. `background = true` 时**立刻返回**，后台线程去补缺失数据集：
//!    `catalog.json`（+ Ed25519 签名校验，如配了 PubKey）→ 选包 → 下载 zip →
//!    SHA-256 校验 → 解压安装 → 重建定位器 → **原子替换**（读方无锁）。
//!
//! ## 并发模型（为什么是"后台线程 + 原子指针"，而不是 await）
//!
//! - 查询热路径**不取锁**：`acquire` 只做一次原子加 + 指针复核，`release` 原子减；
//!   老定位器在引用归零后才销毁（引用计数 + 退休标记，销毁路径加锁，热路径不加锁）。
//! - 下载是阻塞 IO（std 0.17 在 Windows 上 socket 读仍是同步 `deviceIoControl`，
//!   真异步需要自建 AFD/IOCP），放独立线程是当前平台**唯一**能"启动不等网络"的做法；
//!   POSIX 上可换 `Io.concurrent`，接口不变。
//! - 后台线程全程只读配置 + 自己的 arena，不碰业务状态；失败只记 `last_error` 并保留旧定位器。

const std = @import("std");
const ip_mod = @import("ip.zig");
const config_mod = @import("config.zig");
const catalog_mod = @import("catalog.zig");
const store_mod = @import("store.zig");
const http_mod = @import("http.zig");
const auth_mod = @import("auth.zig");
const xdb_mod = @import("xdb.zig");
const mmdb_mod = @import("mmdb.zig");
const qqwry_mod = @import("qqwry.zig");
const locator_mod = @import("locator.zig");
const fsutil = @import("fsutil.zig");

const IpAddr = ip_mod.IpAddr;
const Locator = locator_mod.Locator;
const Scratch = locator_mod.Scratch;
const Location = locator_mod.Location;

/// 组件分类（上传到 Pek.RPanlServer 时填写）。
pub const IP_DATABASE_CATEGORY = "ip-database";
/// ip2region IPv4。
pub const DATASET_IP2REGION_V4 = "ip2region-v4";
/// ip2region IPv6。
pub const DATASET_IP2REGION_V6 = "ip2region-v6";
/// GeoLite2/DB-IP 城市库。
pub const DATASET_GEOLITE2_CITY = "geolite2-city";
/// GeoLite2 ASN 库。
pub const DATASET_GEOLITE2_ASN = "geolite2-asn";

const CATALOG_PATH = "/components/catalog.json";
/// 自动探测本机镜像的超时（毫秒）：探不到就当没有，不能拖慢启动/同步。
const MIRROR_PROBE_TIMEOUT_MS: u32 = 800;

/// 取 URL 的文件名（去掉目录、查询串与片段）。
pub fn componentFileName(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.indexOfAny(u8, rest, "?#")) |i| rest = rest[0..i];
    const slash = std.mem.lastIndexOfScalar(u8, rest, '/');
    return if (slash) |i| rest[i + 1 ..] else rest;
}

/// 镜像模式下的包地址：`{mirror}/components/{文件名}`。
///
/// 目录里的 `url` 是平台绝对地址（`https://p.sc8.fun/components/x.zip`），
/// 如果原样使用就会绕过镜像直连平台——所以镜像模式必须按文件名重拼。
pub fn mirrorComponentUrl(arena: std.mem.Allocator, mirror: []const u8, entry_url: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/components/{s}", .{ mirror, componentFileName(entry_url) });
}
const MAX_CATALOG_BYTES: usize = 1024 * 1024;
/// 本地目录缓存：与 `CatalogMaxAge` 配合，避免每次启动/每次 sync 都联网拉目录。
/// `.catalog.meta` 只有一行 unix 秒（抓取时间）。
const CATALOG_CACHE_JSON = ".catalog.json";
const CATALOG_CACHE_SIG = ".catalog.sig";
const CATALOG_CACHE_META = ".catalog.meta";

/// 读一个小文本文件（超限或不存在返回 null）。
fn readSmallFile(io: std.Io, arena: std.mem.Allocator, path: []const u8, limit: usize) ?[]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return reader.interface.allocRemaining(arena, .limited(limit)) catch null;
}

/// 本地目录缓存是否仍在新鲜期内。
/// `max_age_s == 0` 表示「每次都拉」；缓存缺失/损坏/时钟回拨一律视为不新鲜。
fn catalogCacheFresh(io: std.Io, arena: std.mem.Allocator, cache_dir: []const u8, max_age_s: u32) bool {
    if (max_age_s == 0) return false;

    const json_path = std.fs.path.join(arena, &.{ cache_dir, CATALOG_CACHE_JSON }) catch return false;
    const json_file = std.Io.Dir.cwd().openFile(io, json_path, .{}) catch return false;
    json_file.close(io);

    const meta_path = std.fs.path.join(arena, &.{ cache_dir, CATALOG_CACHE_META }) catch return false;
    const meta_file = std.Io.Dir.cwd().openFile(io, meta_path, .{}) catch return false;
    defer meta_file.close(io);
    var buf: [64]u8 = undefined;
    var reader = meta_file.reader(io, &buf);
    const line_opt = reader.interface.takeDelimiter('\n') catch null;
    const line = line_opt orelse return false;
    const fetched_at = std.fmt.parseInt(u64, std.mem.trim(u8, line, " \t\r"), 10) catch return false;

    const now_ns = std.Io.Clock.real.now(io).nanoseconds;
    const now_s: u64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s));
    if (now_s < fetched_at) return false; // 时钟回拨：当作不新鲜，重拉一次
    return now_s - fetched_at <= max_age_s;
}

/// 写本地目录缓存。缓存是「省带宽」的优化，失败只告警不影响正确性。
fn writeCatalogCache(io: std.Io, arena: std.mem.Allocator, cache_dir: []const u8, body: []const u8, sig: ?[]const u8) void {
    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch |err| {
        std.debug.print("[pek-zip] 组件目录缓存目录创建失败：{s}（{s}）\n", .{ cache_dir, @errorName(err) });
        return;
    };

    const json_path = std.fs.path.join(arena, &.{ cache_dir, CATALOG_CACHE_JSON }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = json_path, .data = body }) catch |err| {
        std.debug.print("[pek-zip] 组件目录缓存写入失败：{s}（{s}）；本次仍用内存中的目录\n", .{ json_path, @errorName(err) });
        return;
    };

    if (sig) |text| {
        const sig_path = std.fs.path.join(arena, &.{ cache_dir, CATALOG_CACHE_SIG }) catch return;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sig_path, .data = text }) catch |err| {
            std.debug.print("[pek-zip] 组件目录签名缓存写入失败：{s}（{s}）\n", .{ sig_path, @errorName(err) });
        };
    }

    var stamp_buf: [32]u8 = undefined;
    const now_s: u64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    const stamp = std.fmt.bufPrint(&stamp_buf, "{d}\n", .{now_s}) catch return;
    const meta_path = std.fs.path.join(arena, &.{ cache_dir, CATALOG_CACHE_META }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = meta_path, .data = stamp }) catch |err| {
        std.debug.print("[pek-zip] 组件目录时间戳写入失败：{s}（{s}）\n", .{ meta_path, @errorName(err) });
    };
}
const MAX_SIGNATURE_BYTES: usize = 8 * 1024;
const DEFAULT_PACKAGE_LIMIT: usize = 512 * 1024 * 1024;

/// 数据集（固定 4 个，顺序即加载顺序）。
pub const Dataset = enum(usize) {
    ip2region_v4 = 0,
    ip2region_v6 = 1,
    world = 2,
    asn = 3,

    pub fn id(self: Dataset) []const u8 {
        return switch (self) {
            .ip2region_v4 => DATASET_IP2REGION_V4,
            .ip2region_v6 => DATASET_IP2REGION_V6,
            .world => DATASET_GEOLITE2_CITY,
            .asn => DATASET_GEOLITE2_ASN,
        };
    }

    pub fn label(self: Dataset) []const u8 {
        return switch (self) {
            .ip2region_v4 => "ip2region IPv4",
            .ip2region_v6 => "ip2region IPv6",
            .world => "国外城市库",
            .asn => "ASN/ISP 库",
        };
    }
};

/// 单个数据集的加载状态（用于 `status` 输出）。
pub const DatasetState = struct {
    /// 已加载的数据文件路径（空 = 未加载）。
    path: []const u8 = "",
    /// 打开失败原因（空 = 正常）。
    error_text: []const u8 = "",
};

/// 引用计数包装：定位器只在最后一个读方释放后销毁。
pub const Shared = struct {
    locator: Locator,
    refs: std.atomic.Value(u32) = .init(1),
};

/// 启动选项。
pub const StartOptions = struct {
    /// 是否用后台线程补数据（`false` = 只加载本地，适合 CLI/测试）。
    background: bool = true,
    /// 本地缺失时是否允许下载。
    download_missing: bool = true,
    /// 允许部分数据缺失（启动时尽力而为）。
    allow_partial: bool = true,
    /// 是否下载 IPv6 xdb（覆盖配置项，用于测试）。
    download_v6: ?bool = null,
    /// 即使本地数据齐全也比对组件目录版本，有新版本才下载（`zpk sync` 用）。
    check_updates: bool = false,
    /// 忽略 `CatalogMaxAge` 缓存新鲜期，强制联网拉目录（`zpk sync --force`）。
    force_refresh: bool = false,
    /// 国内命中 ip2region 时跳过 MMDB（省 ~95% 查询耗时；代价：无经纬度/时区/区县/ASN）。
    skip_world_for_china: bool = false,
    /// 后台定时检查更新的间隔（分钟；`null` = 用配置项，`0` = 关闭）。
    /// 每轮只多一次目录 GET（受 `CatalogMaxAge` 约束），**只有发现新版本才下包**。
    auto_update_minutes: ?u32 = null,
};

/// 极短临界区自旋锁（只保护「退休/销毁」路径，查询热路径不进锁）。
const SpinLock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinLock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.inner.unlock();
    }
};

/// 机器级同步锁：同机多应用同时启动时只让一个进程去下载/解压，其余直接复用共享缓存。
///
/// 用「独占创建锁文件」而不是 advisory lock —— 后者在 Windows 上即便
/// `lock_nonblocking` 也可能阻塞（实测直接把测试挂住），前者永不阻塞。
/// 崩溃残留由 mtime 兜底：超过 10 分钟视为陈旧，删掉重取一次。
const SyncLock = struct {
    path: [512]u8 = @splat(0),
    path_len: usize = 0,
    io: std.Io,
    held: bool = false,

    const stale_ns: i96 = 10 * 60 * std.time.ns_per_s;

    fn acquire(io: std.Io, cache_dir: []const u8) ?SyncLock {
        std.Io.Dir.cwd().createDirPath(io, cache_dir) catch return null;
        var self = SyncLock{ .io = io };
        const path = std.fmt.bufPrint(&self.path, "{s}/.sync.lock", .{cache_dir}) catch return null;
        self.path_len = path.len;

        if (tryCreate(io, path)) {
            self.held = true;
            return self;
        }

        // 已存在：判断是否陈旧（上一个进程崩溃留下的）
        if (isStale(io, path)) {
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
            if (tryCreate(io, path)) {
                self.held = true;
                return self;
            }
        }
        return null;
    }

    fn tryCreate(io: std.Io, path: []const u8) bool {
        const file = std.Io.Dir.cwd().createFile(io, path, .{
            .read = false,
            .truncate = false,
            .exclusive = true,
        }) catch return false;
        file.close(io);
        return true;
    }

    fn isStale(io: std.Io, path: []const u8) bool {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
        const now = std.Io.Clock.real.now(io).nanoseconds;
        return now - stat.mtime.nanoseconds > stale_ns;
    }

    fn release(self: *SyncLock) void {
        if (!self.held) return;
        self.held = false;
        std.Io.Dir.cwd().deleteFile(self.io, self.path[0..self.path_len]) catch {};
    }
};

pub const Manager = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: config_mod.Config,
    store: store_mod.Store,
    shared: std.atomic.Value(?*Shared),
    swap_lock: SpinLock = .{},
    worker: ?std.Thread = null,
    opts: StartOptions,
    /// 后台任务是否已跑完（含失败）。
    finished: std.atomic.Value(bool) = .init(false),
    /// 后台任务期间的告警/失败摘要（启动时留空）。
    last_error: [768]u8 = @splat(0),
    last_error_len: usize = 0,
    /// 各数据集状态（由后台线程在发布前填好，读方只读）。
    states: [4]DatasetState = @splat(DatasetState{}),
    state_text: [4][512]u8 = @splat(@as([512]u8, @splat(0))),
    /// 已完成的查询次数（诊断用）。
    lookups: std.atomic.Value(u64) = .init(0),
    /// 下载授权客户端（懒加载；零身份自动注册，首次下载时创建）。
    auth: ?auth_mod.AuthClient = null,
    /// 自动探测到的本机镜像根（`null` = 尚未探测；空串不可能，没探到就一直是 null）。
    mirror_detected: ?[]u8 = null,
    /// 是否已尝试过探测（探测只做一次，无论成败）。
    mirror_probed: bool = false,
    /// 被替换下来的旧定位器：**只延后释放**（廉价 hazard pointer 替代），
    /// 运行期不销毁，避免「读方刚拿到指针就被销毁」的竞态；替换次数很少（启动一次 + 手动 sync）。
    retired: std.ArrayList(*Shared) = .empty,
    /// 后台定时检查更新的停止信号（`destroy` 时置位并唤醒等待方）。
    stop: std.atomic.Value(bool) = .init(false),
    stop_mutex: std.Io.Mutex = .init,
    stop_cond: std.Io.Condition = .init,
    /// 「首轮同步完成」通知（开启定时更新后线程会长期存活，不能靠 join 判就绪）。
    ready_mutex: std.Io.Mutex = .init,
    ready_cond: std.Io.Condition = .init,

    /// 创建并加载：本地数据立即可用，后台补缺（`background`）。
    pub fn start(io: std.Io, gpa: std.mem.Allocator, base: []const u8, opts: StartOptions) !*Manager {
        const self = try gpa.create(Manager);
        errdefer gpa.destroy(self);

        const cfg = try config_mod.Config.load(io, gpa, base);

        self.* = .{
            .io = io,
            .gpa = gpa,
            .cfg = cfg,
            .store = store_mod.Store.init(io, gpa, cfg.cache_dir),
            .shared = .init(null),
            .opts = opts,
        };
        errdefer self.cfg.deinit();
        self.store.package_limit = DEFAULT_PACKAGE_LIMIT;

        // 第 1 步：本地数据（同步、毫秒级）
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        self.captureStates(arena) catch {};
        const locator = try self.buildLocator(arena, false);
        self.publish(locator);

        // 第 2 步：后台补缺
        if (opts.background) {
            self.worker = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
                self.setError("启动后台数据线程失败：{s}（本地数据已加载，可继续离线使用）", .{@errorName(err)});
                self.finished.store(true, .release);
                return self;
            };
        } else {
            self.finished.store(true, .release);
        }
        return self;
    }

    /// 等首轮同步完成（CLI / 测试 / 优雅退出前调用）。
    ///
    /// 注意语义：开启 `auto_update_minutes` 后后台线程会长期存活，
    /// 所以这里等的是「`finished` 置位」而不是 join；真正回收线程在 `destroy` 里。
    pub fn waitIdle(self: *Manager) void {
        self.ready_mutex.lock(self.io) catch return;
        defer self.ready_mutex.unlock(self.io);
        while (!self.finished.load(.acquire)) {
            // 1s 超时只是兼底（防丢唤醒），正常会被 signal 立即唤醒
            self.ready_cond.waitTimeout(self.io, &self.ready_mutex, .{ .duration = .{
                .raw = std.Io.Duration.fromNanoseconds(std.time.ns_per_s),
                .clock = .real,
            } }) catch |err| switch (err) {
                error.Timeout => {},
                else => return,
            };
        }
    }

    /// 真正回收后台线程（仅 `destroy` 用）。
    fn joinWorker(self: *Manager) void {
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
    }

    /// 销毁（会先叫停后台定时任务，再等线程结束、释放定位器）。
    pub fn destroy(self: *Manager) void {
        self.stop.store(true, .release);
        self.stop_mutex.lock(self.io) catch {};
        self.stop_cond.signal(self.io);
        self.stop_mutex.unlock(self.io);
        self.joinWorker();
        self.swap_lock.lock();
        if (self.shared.swap(null, .acq_rel)) |shared| {
            self.retired.append(self.gpa, shared) catch {
                // 极端情况下（OOM）宁可泄漏也不破坏运行中的指针
            };
        }
        // 依次回收：等引用归零（此时后台线程已停、业务应已停止查询），再释放
        for (self.retired.items) |shared| {
            while (shared.refs.load(.acquire) > 1) std.atomic.spinLoopHint();
            self.retired_destroy(shared);
        }
        self.retired.deinit(self.gpa);
        self.swap_lock.unlock();

        const gpa = self.gpa;
        if (self.mirror_detected) |m| gpa.free(m);
        self.cfg.deinit();
        gpa.destroy(self);
    }

    fn retired_destroy(self: *Manager, shared: *Shared) void {
        destroyShared(self.gpa, shared);
    }

    /// 取一个可用定位器（读方必须配对 `release`）。
    pub fn acquire(self: *Manager) ?*Shared {
        while (true) {
            const current = self.shared.load(.acquire) orelse return null;
            _ = current.refs.fetchAdd(1, .monotonic);
            // 复核：期间若已被替换，撤销本次引用重来
            if (self.shared.load(.monotonic) == current) return current;
            _ = current.refs.fetchSub(1, .acq_rel);
        }
    }

    /// 释放定位器引用（只递减；真正销毁在 `destroy`）。
    pub fn release(self: *Manager, shared: *Shared) void {
        _ = self;
        _ = shared.refs.fetchSub(1, .acq_rel);
    }

    /// 查询（内部 acquire/release，最省事但略贵；高频场景请自行 acquire 复用）。
    pub fn lookup(self: *Manager, scratch: *Scratch, ip: IpAddr) !Location {
        const shared = self.acquire() orelse {
            if (ip_mod.classify(ip.normalize())) |class| return Location.reserved(ip.normalize(), class);
            return Location{ .ip = ip };
        };
        defer self.release(shared);
        _ = self.lookups.fetchAdd(1, .monotonic);
        return shared.locator.lookupOptions(scratch, ip, .{
            .skip_world_for_china = self.opts.skip_world_for_china,
        });
    }

    /// 查询 IP 文本。
    pub fn lookupStr(self: *Manager, scratch: *Scratch, text: []const u8) !Location {
        return self.lookup(scratch, try IpAddr.parse(text));
    }

    /// 后台任务是否结束（`true` 时数据已是最新或已放弃）。
    pub fn isReady(self: *Manager) bool {
        return self.finished.load(.acquire);
    }

    /// 最近一次失败/告警（空串 = 无）。
    pub fn lastError(self: *Manager) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    /// 各数据集状态。
    pub fn datasetState(self: *Manager, dataset: Dataset) DatasetState {
        return self.states[@backingInt(dataset)];
    }

    /// 同步补齐（CLI `sync` 用；会阻塞到下载完成）。
    pub fn ensureNow(self: *Manager) !void {
        _ = try self.ensureAll(self.opts.check_updates);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // 先记录状态（用固定缓冲，避免结果指向临时 arena）
        self.captureStates(arena) catch {};
        const locator = try self.buildLocator(arena, true);
        self.publish(locator);
        self.finished.store(true, .release);
    }

    // -----------------------------------------------------------------------
    // 内部实现
    // -----------------------------------------------------------------------

    fn workerMain(self: *Manager) void {
        // 首轮：补缺 + 重建 + 发布（原行为）
        self.syncPass(false);
        self.finished.store(true, .release);
        self.ready_mutex.lock(self.io) catch {};
        self.ready_cond.signal(self.io);
        self.ready_mutex.unlock(self.io);

        // 之后（可选）：定时检查更新。默认 0 = 关闭——周期任务要先算账，
        // 开启后每轮只多一次目录 GET（且受 CatalogMaxAge 约束），有新版本才下包。
        const minutes = self.opts.auto_update_minutes orelse self.cfg.auto_update_minutes;
        if (minutes == 0) return;
        while (self.waitForNextCheck(minutes)) {
            self.syncPass(true);
        }
    }

    /// 一次「拉取 → 重建 → 发布」。`force_check` 时即使本地齐全也比对版本；
    /// 无新版本则不重建（省一次全量打开）。
    fn syncPass(self: *Manager, force_check: bool) void {
        const downloaded = self.ensureAll(force_check) catch |err| {
            self.setError("后台补数据失败：{s}（保留当前本地数据继续服务；检查 StoreUrl/网络后重启或执行 sync）", .{@errorName(err)});
            return;
        };
        if (force_check and !downloaded) return;

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        self.captureStates(arena) catch {};

        // 只有当这次确实加载到比现在更多的数据时才替换（避免无谓替换）
        const locator = self.buildLocator(arena, true) catch |err| {
            self.setError("后台重建定位器失败：{s}（保留旧数据；已下载文件仍在缓存目录，可直接复用）", .{@errorName(err)});
            return;
        };
        self.publish(locator);
    }

    /// 等下一次检查（可被 `destroy` 唤醒）。返回 false = 要求停止。
    fn waitForNextCheck(self: *Manager, minutes: u32) bool {
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromSeconds(@as(i64, minutes) * 60),
            .clock = .real,
        } };
        self.stop_mutex.lock(self.io) catch return false;
        defer self.stop_mutex.unlock(self.io);
        if (self.stop.load(.acquire)) return false;
        self.stop_cond.waitTimeout(self.io, &self.stop_mutex, timeout) catch |err| switch (err) {
            error.Timeout => return !self.stop.load(.acquire), // 时间到：去检查
            else => return false,
        };
        return !self.stop.load(.acquire); // 被 signal 唤醒（destroy）
    }

    fn publish(self: *Manager, locator: Locator) void {
        const shared = self.gpa.create(Shared) catch {
            var owned = locator;
            owned.deinit();
            self.setError("发布定位器失败：内存不足（保留旧数据）", .{});
            return;
        };
        shared.* = .{ .locator = locator };

        const previous = self.shared.swap(shared, .acq_rel);
        if (previous) |old| {
            // 丢 Manager 自己的那份引用，并把老对象挂到退休列表（不在运行期销毁）
            self.release(old);
            self.swap_lock.lock();
            self.retired.append(self.gpa, old) catch {};
            self.swap_lock.unlock();
        }
    }

    fn setError(self: *Manager, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.last_error, fmt, args) catch blk: {
            break :blk self.last_error[0..@min(self.last_error.len, 200)];
        };
        self.last_error_len = text.len;
        std.debug.print("[pek-zip] {s}\n", .{text});
    }

    /// 记录各数据集状态（路径/错误写进固定缓冲，`DatasetState` 指向缓冲）。
    fn captureStates(self: *Manager, arena: std.mem.Allocator) !void {
        const base = self.cfg.data_dir;
        const plan = [_]struct { dataset: Dataset, kind: Kind }{
            .{ .dataset = .ip2region_v4, .kind = .xdb_v4 },
            .{ .dataset = .ip2region_v6, .kind = .xdb_v6 },
            .{ .dataset = .world, .kind = .world },
            .{ .dataset = .asn, .kind = .asn },
        };
        for (plan) |item| {
            const index = @backingInt(item.dataset);
            const path = self.resolvePath(arena, item.dataset, item.kind, base) catch "";
            const buffer = &self.state_text[index];
            if (path.len > 0) {
                const n = @min(path.len, buffer.len);
                @memcpy(buffer[0..n], path[0..n]);
                self.states[index] = .{ .path = buffer[0..n], .error_text = "" };
            } else {
                self.states[index] = .{ .path = "", .error_text = "本地缺失（等待下载）" };
            }
        }
    }

    const Kind = enum { xdb_v4, xdb_v6, world, asn, qqwry };

    /// 解析某数据集应该用的文件路径：本地 `data/` 优先，其次下载缓存，再次（可选）下载。
    fn resolvePath(self: *Manager, arena: std.mem.Allocator, dataset: Dataset, kind: Kind, data_dir: []const u8) ![]const u8 {
        if (try localPath(self.io, arena, kind, data_dir)) |path| return path;

        if (try self.store.findLocalLatest(arena, dataset.id())) |installed| {
            if (installed.primaryFile()) |file| return file;
        }

        if (!self.opts.download_missing) return "";
        // 下载由 ensureAll 统一做；这里只再查一次缓存
        if (try self.store.findLocalLatest(arena, dataset.id())) |installed| {
            if (installed.primaryFile()) |file| return file;
        }
        return "";
    }

    /// 该数据集是否已有本地可用数据（缓存安装目录 或 用户数据目录）。
    fn hasLocal(self: *Manager, arena: std.mem.Allocator, dataset: Dataset) !bool {
        if (try self.store.findLocalLatest(arena, dataset.id()) != null) return true;
        const kind: Kind = switch (dataset) {
            .ip2region_v4 => .xdb_v4,
            .ip2region_v6 => .xdb_v6,
            .world => .world,
            .asn => .asn,
        };
        return (try localPath(self.io, arena, kind, self.cfg.data_dir)) != null;
    }

    /// 读本地组件目录缓存（新鲜期内 + 签名复校）。
    /// 返回 `null` = 需要联网刷新（缓存缺失/过期/签名不可信）。
    fn loadCachedCatalog(self: *Manager, arena: std.mem.Allocator) !?[]const u8 {
        if (self.opts.force_refresh) return null;
        if (!catalogCacheFresh(self.io, arena, self.cfg.cache_dir, self.cfg.catalog_max_age)) return null;

        const json_path = try std.fs.path.join(arena, &.{ self.cfg.cache_dir, CATALOG_CACHE_JSON });
        const body = readSmallFile(self.io, arena, json_path, MAX_CATALOG_BYTES) orelse return null;

        // 有可信公钥（配置的 PubKey 或注册时 TOFU 学到的平台公钥）就必须连缓存一起验签：
        // 否则改缓存文件即可绕过验签
        if (self.catalogVerifyKey()) |verify_key| {
            const sig_path = try std.fs.path.join(arena, &.{ self.cfg.cache_dir, CATALOG_CACHE_SIG });
            const sig_text = readSmallFile(self.io, arena, sig_path, MAX_SIGNATURE_BYTES) orelse {
                std.debug.print("[pek-zip] 本地目录缓存缺签名（{s}），改走联网刷新\n", .{sig_path});
                return null;
            };
            auth_mod.verifyBase64(verify_key, body, std.mem.trim(u8, sig_text, " \t\r\n")) catch |err| {
                std.debug.print("[pek-zip] 本地目录缓存签名校验失败：{s}，改走联网刷新\n", .{@errorName(err)});
                return null;
            };
        }

        std.debug.print("[pek-zip] 复用本地组件目录缓存（{s}/{s}，新鲜期 {d}s）\n", .{
            self.cfg.cache_dir, CATALOG_CACHE_JSON, self.cfg.catalog_max_age,
        });
        return body;
    }

    /// 确保 4 个数据集（按配置）都在本地可用：缓存优先，缺失才联网。
    ///
    /// `force_check = true` 时即使本地齐全也比对目录版本（后台定时更新用）。
    /// 返回 `true` = 本次确实下载并安装了新版本（调用方据此决定是否重建定位器）。
    fn ensureAll(self: *Manager, force_check: bool) !bool {
        const check_updates = force_check or self.opts.check_updates;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const download_v6 = self.opts.download_v6 orelse self.cfg.download_v6;
        var needed: [4]Dataset = undefined;
        var needed_count: usize = 0;
        var missing_count: usize = 0;
        for ([_]Dataset{ .ip2region_v4, .ip2region_v6, .world, .asn }) |dataset| {
            if (dataset == .ip2region_v6 and !download_v6) continue;
            const has_local = try self.hasLocal(arena, dataset);
            if (!has_local) missing_count += 1;
            // 缺数据必须去拿；本地齐全时只有「检查更新」才需要目录
            if (!has_local or check_updates) {
                needed[needed_count] = dataset;
                needed_count += 1;
            }
        }
        if (needed_count == 0) return false;

        if (self.cfg.store_url.len == 0) {
            // 纯检查更新 + 离线模式：本地齐全就不必报错
            if (missing_count == 0) return false;
            self.setError("缺少 {d} 个数据集但未配置 StoreUrl（仅本地缓存模式；把数据放进 {s} 即可）", .{ missing_count, self.cfg.data_dir });
            return false;
        }

        // 同机多应用同时启动时，只让一个进程去下载（共享 CacheDir 时全机复用）
        var lock = SyncLock.acquire(self.io, self.cfg.cache_dir) orelse {
            std.debug.print("[pek-zip] 另一进程正在同步数据（锁：{s}/.sync.lock），本次跳过下载，直接复用共享缓存\n", .{self.cfg.cache_dir});
            return false;
        };
        defer lock.release();

        var client = try http_mod.Client.init(self.io, self.gpa, self.cfg.ca_file);
        defer client.deinit();
        client.timeout_ms = self.cfg.http_timeout_ms;

        // 镜像根：配置了就用配置的；没配就**自动探测本机 RAgent**（探测一次，失败即直连平台）。
        const mirror = self.resolveMirror(&client);
        const catalog_url = if (mirror) |root|
            // 镜像根就是 `/ipdb`（RAgent 的布局：`/ipdb/catalog.json` + `/ipdb/components/*.zip`），
            // 字节与平台一致，所以验签仍然对着平台公钥（镜像只转发不重签）。
            try std.fmt.allocPrint(arena, "{s}/catalog.json", .{root})
        else
            try std.fmt.allocPrint(arena, "{s}{s}", .{ self.cfg.store_url, CATALOG_PATH });

        // 目录本身有 TTL（`CatalogMaxAge`）：新鲜期内直接用本地缓存，不联网。
        var catalog_body: []const u8 = undefined;
        if (try self.loadCachedCatalog(arena)) |cached| {
            catalog_body = cached;
        } else {
            // 镜像优先，但**镜像不可用时自动回退平台**：镜像只是省带宽的优化，
            // 不能因为它缺文件/没启动就把同步搞挂（这是最容易上新功能时踩的坑）。
            var active_url = catalog_url;
            var response = client.getBytes(active_url, &.{}, MAX_CATALOG_BYTES) catch |mirror_err| blk: {
                if (mirror == null) {
                    self.setError("拉取组件目录失败：{s}；URL={s}（{s}）", .{ @errorName(mirror_err), active_url, fetchHint(mirror_err) });
                    return false;
                }
                active_url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.cfg.store_url, CATALOG_PATH });
                std.debug.print("[pek-zip] 镜像目录拉取失败：{s}（{s}），回退平台 {s}\n", .{ @errorName(mirror_err), catalog_url, active_url });
                break :blk client.getBytes(active_url, &.{}, MAX_CATALOG_BYTES) catch |err| {
                    self.setError("拉取组件目录失败：{s}；URL={s}（镜像 {s} 也不可用：{s}）", .{ @errorName(err), active_url, catalog_url, @errorName(mirror_err) });
                    return false;
                };
            };
            if (!response.isSuccess() and mirror != null and !std.mem.eql(u8, active_url, catalog_url)) {
                // 平台也失败：保持原状（下面统一报错）
            } else if (!response.isSuccess() and mirror != null) {
                response.deinit(self.gpa);
                active_url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.cfg.store_url, CATALOG_PATH });
                std.debug.print("[pek-zip] 镜像目录 HTTP {d}，回退平台 {s}\n", .{ response.status, active_url });
                response = client.getBytes(active_url, &.{}, MAX_CATALOG_BYTES) catch |err| {
                    self.setError("拉取组件目录失败：{s}；URL={s}（镜像 {s} 不可用）", .{ @errorName(err), active_url, catalog_url });
                    return false;
                };
            }
            defer response.deinit(self.gpa);
            if (!response.isSuccess()) {
                self.setError("拉取组件目录失败：HTTP {d}，URL={s}，响应片段：{s}", .{
                    response.status, active_url, response.snippet(200),
                });
                return false;
            }

            // 有可信公钥就必须验签（目录被篡改宁可不可用）：
            // 配置的 PubKey 优先；留空时用注册时 TOFU 学到的平台公钥（否则留空＝完全不验签，TOFU 形同虚设）
            var sig_text: ?[]const u8 = null;
            if (self.catalogVerifyKey()) |verify_key| {
                var reason: []const u8 = "";
                sig_text = self.verifyCatalogSig(arena, &client, active_url, response.body, verify_key, &reason) catch |sig_err| blk: {
                    const platform_url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.cfg.store_url, CATALOG_PATH });
                    const on_mirror = mirror != null and !std.mem.eql(u8, active_url, platform_url);
                    if (!on_mirror) {
                        self.setError("组件目录签名校验失败：{s}（{s}；URL={s}）", .{ @errorName(sig_err), reason, active_url });
                        return false;
                    }
                    // 镜像没转发 `.sig`（或签名对不上）→ 整个目录改从平台重取：
                    // 镜像只是省带宽的优化，不能把「有 Key 的客户端」直接卡死。
                    std.debug.print("[pek-zip] 镜像目录签名不可用：{s}（{s}），回退平台重取 {s}\n", .{ @errorName(sig_err), reason, platform_url });
                    response.deinit(self.gpa);
                    active_url = platform_url;
                    response = client.getBytes(active_url, &.{}, MAX_CATALOG_BYTES) catch |err| {
                        self.setError("拉取组件目录失败：{s}；URL={s}（镜像签名不可用：{s}）", .{ @errorName(err), active_url, reason });
                        return false;
                    };
                    if (!response.isSuccess()) {
                        self.setError("拉取组件目录失败：HTTP {d}，URL={s}（镜像签名不可用：{s}）", .{ response.status, active_url, reason });
                        return false;
                    }
                    break :blk self.verifyCatalogSig(arena, &client, active_url, response.body, verify_key, &reason) catch |err2| {
                        self.setError("组件目录签名校验失败：{s}（{s}；URL={s}，镜像回退后仍失败）", .{ @errorName(err2), reason, active_url });
                        return false;
                    };
                };
            } else {
                std.debug.print("[pek-zip] 尚无可信公钥（未配 PubKey 且还没注册过），本次目录不验签；注册成功后自动强制验签\n", .{});
            }
            writeCatalogCache(self.io, arena, self.cfg.cache_dir, response.body, sig_text);
            // response 马上 deinit，正文必须拷进 arena
            catalog_body = try arena.dupe(u8, response.body);
        }

        var catalog = catalog_mod.parse(self.gpa, catalog_body) catch |err| {
            self.setError("解析组件目录失败：{s}（URL={s}）", .{ @errorName(err), catalog_url });
            return false;
        };
        defer catalog.deinit();

        var downloaded = false;
        const target = currentTarget();
        for (needed[0..needed_count]) |dataset| {
            const entry = catalog_mod.select(catalog, dataset.id(), target) orelse {
                self.setError("组件目录里没有 {s}（target={s}）：请先在 Pek.RPanlServer 上传分类 {s} 的数据包", .{
                    dataset.id(), target, IP_DATABASE_CATEGORY,
                });
                continue;
            };
            if (check_updates) {
                // 只在远端版本更高时才下载（同版本/更低一律跳过，省带宽）
                const latest = self.store.findLocalLatest(arena, dataset.id()) catch |err| blk: {
                    std.debug.print("[pek-zip] 读取 {s} 本地版本失败：{s}（按需重新下载）\n", .{ dataset.id(), @errorName(err) });
                    break :blk null;
                };
                if (latest) |installed| {
                    if (catalog_mod.compareVersions(entry.version, installed.version) != .gt) {
                        std.debug.print("[pek-zip] {s} 已是最新（本地 {s}，目录 {s}）\n", .{
                            dataset.id(), installed.version, entry.version,
                        });
                        continue;
                    }
                    std.debug.print("[pek-zip] {s} 发现新版本：{s} → {s}\n", .{ dataset.id(), installed.version, entry.version });
                }
            }
            if (self.downloadAndInstall(arena, &client, dataset, entry)) |_| {
                downloaded = true;
            } else |err| {
                const hint = switch (err) {
                    error.AuthPending => "客户端已注册但等待平台批准：面板「分发中心 → IP 授权」点「批准」后重跑 zpk sync",
                    error.AuthRevoked => "客户端已被平台吐销：面板「IP 授权」页恢复并重新批准",
                    error.Denied => "平台拒给授权（检查 StateDir 里的 installId 是否被重置/公钥不匹配）",
                    error.BadSignature => "签名校验失败（配置的 PubKey 与平台不一致，或本地身份文件损坏）",
                    else => "",
                };
                if (hint.len > 0) {
                    self.setError("安装 {s} 失败：{s}（version={s}）→ {s}", .{ dataset.id(), @errorName(err), entry.version, hint });
                } else {
                    self.setError("安装 {s} 失败：{s}（version={s}，url={s}）", .{ dataset.id(), @errorName(err), entry.version, entry.url });
                }
            }
        }
        return downloaded;
    }

    /// 目录验签公钥来源。
    pub const VerifyKeySource = enum { configured, tofu, none };
    /// 目录验签用的公钥：配置的 `PubKey` 优先；留空时用注册时 TOFU 学到的平台公钥。
    ///
    /// 为什么必须有 TOFU 分支：配置注释写着「留空 = 注册时学习公钥并落盘固定，不需要每个应用都配」，
    /// 但若验签只看 `cfg.pubkey`，留空就等于**完全不验签**（改目录 + 换包即可绕过），TOFU 形同虚设。
    /// 返回 null 只发生在「既没配 PubKey、也还没注册过」的首次联网 —— 注册成功后自动开始强制验签。
    pub fn catalogVerifyKey(self: *Manager) ?[]const u8 {
        if (self.cfg.pubkey.len > 0) return self.cfg.pubkey;
        const auth = self.authClient() catch |err| {
            std.debug.print("[pek-zip] 读取授权身份失败（{s}），本次无法用 TOFU 公钥校验目录签名\n", .{@errorName(err)});
            return null;
        };
        return auth.platformPubKeyHex();
    }

    /// 公钥来源（给 `zpk status` 与错误文案用）。
    pub fn verifyKeySource(self: *Manager) VerifyKeySource {
        if (self.cfg.pubkey.len > 0) return .configured;
        return if (self.catalogVerifyKey() != null) .tofu else .none;
    }

    pub fn verifyKeySourceText(self: *Manager) []const u8 {
        return switch (self.verifyKeySource()) {
            .configured => "配置的 PubKey",
            .tofu => "TOFU 学到的平台公钥",
            .none => "无公钥（不验签）",
        };
    }

    /// 取 `{base_url}.sig` 并验签；成功返回**已 trim 且拷进 arena** 的签名文本。
    ///
    /// 失败时把可读原因写进 `reason`（上层拼日志用）并返回 error。
    /// 注：返回值必须拷进 arena——签名响应体在函数返回时就释放，直接外传会成悬垂指针
    ///（本项目实测过：把 'UUUU…' 写进缓存，导致下次启动缓存验签必失败、TTL 形同虚设）。
    fn verifyCatalogSig(
        self: *Manager,
        arena: std.mem.Allocator,
        client: *http_mod.Client,
        base_url: []const u8,
        body: []const u8,
        verify_key: []const u8,
        reason: *[]const u8,
    ) ![]const u8 {
        const sig_url = std.fmt.allocPrint(arena, "{s}.sig", .{base_url}) catch {
            reason.* = "分配签名 URL 失败";
            return error.OutOfMemory;
        };
        var sig_response = client.getBytes(sig_url, &.{}, MAX_SIGNATURE_BYTES) catch |err| {
            reason.* = std.fmt.allocPrint(arena, "拉取签名失败 {s}：{s}（{s}）", .{ @errorName(err), sig_url, fetchHint(err) }) catch "拉取签名失败";
            return err;
        };
        defer sig_response.deinit(self.gpa);
        if (!sig_response.isSuccess()) {
            reason.* = std.fmt.allocPrint(arena, "签名 HTTP {d}（{s}）", .{ sig_response.status, sig_url }) catch "签名缺失";
            return error.HttpStatus;
        }
        const trimmed = std.mem.trim(u8, sig_response.body, " \t\r\n");
        auth_mod.verifyBase64(verify_key, body, trimmed) catch |err| {
            reason.* = std.fmt.allocPrint(arena, "验签失败 {s}（公钥来源 {s}）", .{ @errorName(err), self.verifyKeySourceText() }) catch "验签失败";
            return err;
        };
        const dup = arena.dupe(u8, trimmed) catch return error.OutOfMemory;
        reason.* = "";
        return dup;
    }

    /// 镜像根：配置优先；留空则**自动探测本机 RAgent**（`MirrorProbeUrl`，默认 5501/ipdb）。
    ///
    /// 探测只做一次（成功/失败都记住），超时 800ms：探不到就当没有，直接直连平台，
    /// 不能因为“你可能装了代理”就拖慢启动或同步。
    fn resolveMirror(self: *Manager, client: *http_mod.Client) ?[]const u8 {
        if (self.cfg.mirror_url.len > 0) return self.cfg.mirror_url;
        if (self.cfg.mirror_probe_url.len == 0) return null;
        if (self.mirror_probed) return if (self.mirror_detected) |m| m else null;
        self.mirror_probed = true;

        const probe_url = std.fmt.allocPrint(self.gpa, "{s}/catalog.json", .{self.cfg.mirror_probe_url}) catch return null;
        defer self.gpa.free(probe_url);
        const saved_timeout = client.timeout_ms;
        client.timeout_ms = MIRROR_PROBE_TIMEOUT_MS;
        defer client.timeout_ms = saved_timeout;

        if (client.getBytes(probe_url, &.{}, MAX_CATALOG_BYTES)) |response_const| {
            var response = response_const;
            defer response.deinit(self.gpa);
            if (response.isSuccess()) {
                self.mirror_detected = self.gpa.dupe(u8, self.cfg.mirror_probe_url) catch null;
                if (self.mirror_detected != null) {
                    std.debug.print("[pek-zip] 已自动发现本机镜像：{s}（探测 {s} 返回 HTTP {d}）\n", .{
                        self.cfg.mirror_probe_url, probe_url, response.status,
                    });
                }
            }
        } else |_| {
            // 探不到（没有代理/未启用/端口改过）属正常待：静默直连平台，不吐日志避免刷屏
        }
        return if (self.mirror_detected) |m| m else null;
    }

    /// 已自动探测到的镜像根（未配置 `MirrorUrl` 时用于 `zpk status` 展示）。
    pub fn detectedMirror(self: *Manager) ?[]const u8 {
        return if (self.mirror_detected) |m| m else null;
    }

    /// 是否已经做过一次自动探测（没做过说明本次进程还没走到联网路径）。
    pub fn mirrorProbeDone(self: *Manager) bool {
        return self.mirror_probed;
    }

    /// 懒加载授权客户端（身份文件在 `StateDir`，首次创建后持久化）。
    fn authClient(self: *Manager) !*auth_mod.AuthClient {
        if (self.auth == null) {
            const platform_pubkey: ?[]const u8 = if (self.cfg.pubkey.len > 0) self.cfg.pubkey else null;
            self.auth = try auth_mod.AuthClient.loadOrCreate(self.io, self.gpa, self.cfg.state_dir, platform_pubkey);
        }
        return &self.auth.?;
    }

    /// 客户端 installId（未初始化时会创建身份）。
    pub fn installId(self: *Manager) ![]const u8 {
        const client = try self.authClient();
        return client.installId();
    }

    /// 客户端公钥（hex）。
    pub fn clientPubKey(self: *Manager) ![]const u8 {
        const client = try self.authClient();
        return client.pubKeyHex();
    }

    /// 主动注册/续期 License（CLI `zpk enroll`）：`true` = 已批准；`error.AuthPending` = 等待批准。
    pub fn enrollNow(self: *Manager) !void {
        if (self.cfg.store_url.len == 0) return error.NoStoreUrl;
        var client = try http_mod.Client.init(self.io, self.gpa, self.cfg.ca_file);
        defer client.deinit();
        client.timeout_ms = self.cfg.http_timeout_ms;
        const auth = try self.authClient();
        auth.ensureLicense(self.cfg.store_url, &client) catch |err| switch (err) {
            error.Unsupported => return error.AuthUnsupported,
            else => return err,
        };
    }

    /// 解析下载 URL：优先用平台票据（自动注册 + Ed25519 签名）；旧平台回退公开 URL。
    fn downloadUrl(
        self: *Manager,
        arena: std.mem.Allocator,
        client: *http_mod.Client,
        entry: *const catalog_mod.Entry,
        buf: []u8,
    ) ![]const u8 {
        // 镜像模式：目录里的 url 是平台绝对地址，把 origin 换成镜像（只取文件名），
        // 且不走票据（镜像是本机/内网可信源，没有平台授权关系）。
        if (self.resolveMirror(client)) |root| {
            return mirrorComponentUrl(arena, root, entry.url);
        }
        return self.platformDownloadUrl(arena, client, entry, buf);
    }

    /// 平台侧下载 URL（票据优先，旧平台回退公开 URL）——镜像不可用时的回退路径。
    fn platformDownloadUrl(
        self: *Manager,
        arena: std.mem.Allocator,
        client: *http_mod.Client,
        entry: *const catalog_mod.Entry,
        buf: []u8,
    ) ![]const u8 {
        if (!self.cfg.auto_enroll or self.cfg.store_url.len == 0) {
            return absoluteUrl(arena, self.cfg.store_url, entry.url);
        }
        const auth = try self.authClient();
        const ticket_url = auth.ticket(self.cfg.store_url, client, entry.id, entry.version, buf) catch |err| switch (err) {
            error.Unsupported => {
                std.debug.print("[pek-zip] 平台未启用 IP 下载授权（旧版本），回退公开下载：{s}\n", .{entry.url});
                return absoluteUrl(arena, self.cfg.store_url, entry.url);
            },
            error.Pending => return error.AuthPending,
            error.Revoked => return error.AuthRevoked,
            else => return err,
        };
        return ticket_url;
    }

    fn downloadAndInstall(
        self: *Manager,
        arena: std.mem.Allocator,
        client: *http_mod.Client,
        dataset: Dataset,
        entry: *const catalog_mod.Entry,
    ) !void {
        var url_buf: [2048]u8 = undefined;
        var url = try self.downloadUrl(arena, client, entry, &url_buf);
        const mirror_on = self.resolveMirror(client) != null;
        const stamp = std.Io.Clock.real.now(self.io).nanoseconds;
        const temp_path = try std.fmt.allocPrint(arena, "{s}/.download-{s}-{s}-{d}.zip", .{
            self.cfg.cache_dir, entry.id, entry.version, @as(u64, @intCast(@mod(stamp, 1_000_000_000))),
        });

        std.Io.Dir.cwd().createDirPath(self.io, self.cfg.cache_dir) catch {};
        var status = client.getToFile(url, &.{}, temp_path) catch |mirror_err| blk: {
            std.Io.Dir.cwd().deleteFile(self.io, temp_path) catch {};
            if (!mirror_on) return mirror_err;
            // 镜像只是省带宽的优化：缺文件/没启动/403 时必须回退平台（带票据），
            // 否则“开了镜像”反而比不开更容易失败。
            const fallback = try self.platformDownloadUrl(arena, client, entry, &url_buf);
            std.debug.print("[pek-zip] 镜像下载失败：{s}（{s}），回退平台下载：{s}\n", .{ @errorName(mirror_err), url, fallback });
            url = fallback;
            break :blk client.getToFile(url, &.{}, temp_path) catch |err| {
                std.Io.Dir.cwd().deleteFile(self.io, temp_path) catch {};
                return err;
            };
        };
        if ((status < 200 or status >= 300) and mirror_on) {
            std.Io.Dir.cwd().deleteFile(self.io, temp_path) catch {};
            const fallback = try self.platformDownloadUrl(arena, client, entry, &url_buf);
            std.debug.print("[pek-zip] 镜像返回 HTTP {d}（{s}），回退平台下载：{s}\n", .{ status, url, fallback });
            url = fallback;
            status = client.getToFile(url, &.{}, temp_path) catch |err| {
                std.Io.Dir.cwd().deleteFile(self.io, temp_path) catch {};
                return err;
            };
        }
        defer std.Io.Dir.cwd().deleteFile(self.io, temp_path) catch {};

        if (status < 200 or status >= 300) return error.HttpStatus;

        var installed = try self.store.installZip(arena, dataset.id(), entry.version, entry.sha256, temp_path);
        installed.sha256 = entry.sha256;
        std.debug.print("[pek-zip] 已安装 {s} {s} → {s}\n", .{ dataset.id(), installed.version, installed.dir });
    }

    /// 构建定位器（`download` 已由 ensureAll 完成；这里只打开文件）。
    fn buildLocator(self: *Manager, arena: std.mem.Allocator, log_errors: bool) !Locator {
        var locator = Locator{};

        const v4_path = try self.resolvePath(arena, .ip2region_v4, .xdb_v4, self.cfg.data_dir);
        if (v4_path.len > 0) {
            if (xdb_mod.XdbReader.open(self.io, self.gpa, v4_path)) |reader| {
                if (reader.ipVersion() == .v4) {
                    locator.xdb_v4 = reader;
                } else {
                    var owned = reader;
                    owned.deinit();
                    if (log_errors) std.debug.print("[pek-zip] {s} 不是 IPv4 xdb（ip_version={s}），已忽略\n", .{ v4_path, reader.ipVersion().asStr() });
                }
            } else |err| {
                if (log_errors) std.debug.print("[pek-zip] 打开 {s} 失败：{s}\n", .{ v4_path, @errorName(err) });
            }
        }

        const v6_path = try self.resolvePath(arena, .ip2region_v6, .xdb_v6, self.cfg.data_dir);
        if (v6_path.len > 0) {
            if (xdb_mod.XdbReader.open(self.io, self.gpa, v6_path)) |reader| {
                if (reader.ipVersion() == .v6) {
                    locator.xdb_v6 = reader;
                } else {
                    var owned = reader;
                    owned.deinit();
                }
            } else |err| {
                if (log_errors) std.debug.print("[pek-zip] 打开 {s} 失败：{s}\n", .{ v6_path, @errorName(err) });
            }
        }

        const world_path = try self.resolvePath(arena, .world, .world, self.cfg.data_dir);
        if (world_path.len > 0) {
            if (mmdb_mod.MmdbReader.open(self.io, self.gpa, world_path, .auto)) |reader| {
                locator.world = reader;
            } else |err| {
                if (log_errors) std.debug.print("[pek-zip] 打开 {s} 失败：{s}\n", .{ world_path, @errorName(err) });
            }
        }

        const asn_path = try self.resolvePath(arena, .asn, .asn, self.cfg.data_dir);
        if (asn_path.len > 0) {
            if (mmdb_mod.MmdbReader.open(self.io, self.gpa, asn_path, .auto)) |reader| {
                locator.world_asn = reader;
            } else |err| {
                if (log_errors) std.debug.print("[pek-zip] 打开 {s} 失败：{s}\n", .{ asn_path, @errorName(err) });
            }
        }

        if (try localPath(self.io, arena, .qqwry, self.cfg.data_dir)) |qqwry_path| {
            if (qqwry_mod.QqwryReader.open(self.io, self.gpa, qqwry_path)) |reader| {
                locator.qqwry = reader;
            } else |err| {
                if (log_errors) std.debug.print("[pek-zip] 打开 {s} 失败：{s}\n", .{ qqwry_path, @errorName(err) });
            }
        }
        return locator;
    }
};

fn destroyShared(gpa: std.mem.Allocator, shared: *Shared) void {
    var locator = shared.locator;
    locator.deinit();
    gpa.destroy(shared);
}

/// 网络失败的可定位提示：超时与普通传输失败必须能一眼分辨。
fn fetchHint(err: anyerror) []const u8 {
    return switch (err) {
        error.Timeout => "超过 HttpTimeoutMs 未响应：平台可能不可达或过慢，可调大 Config/Ip.toml 的 HttpTimeoutMs",
        else => "确认平台地址/网络/证书",
    };
}

/// 本地数据文件命名约定（不区分大小写；与 Pek.IP 一致，另加纯真 `ip.gz`）。
fn localPath(
    io: std.Io,
    arena: std.mem.Allocator,
    kind: Manager.Kind,
    data_dir: []const u8,
) !?[]const u8 {
    switch (kind) {
        .xdb_v4 => {
            for ([_][]const u8{ "ip2region_v4.xdb", "ip2region.xdb" }) |name| {
                const path = try std.fs.path.join(arena, &.{ data_dir, name });
                if (exists(io, path)) return path;
            }
            return null;
        },
        .xdb_v6 => {
            const path = try std.fs.path.join(arena, &.{ data_dir, "ip2region_v6.xdb" });
            return if (exists(io, path)) path else null;
        },
        .qqwry => {
            for ([_][]const u8{ "ip.gz", "qqwry.dat", "ip.dat" }) |name| {
                const path = try std.fs.path.join(arena, &.{ data_dir, name });
                if (exists(io, path)) return path;
            }
            return null;
        },
        .world, .asn => {
            var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true }) catch return null;
            defer dir.close(io);

            var best: ?[]const u8 = null;
            var best_priority: u8 = 255;
            var iterator = dir.iterate();
            while (iterator.next(io) catch return null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.ascii.endsWithIgnoreCase(entry.name, ".mmdb")) continue;
                const lower_priority = mmdbPriority(kind, entry.name) orelse continue;
                if (lower_priority < best_priority) {
                    best_priority = lower_priority;
                    best = try std.fs.path.join(arena, &.{ data_dir, entry.name });
                }
            }
            return best;
        },
    }
}

fn mmdbPriority(kind: Manager.Kind, name: []const u8) ?u8 {
    var lower_buf: [128]u8 = undefined;
    const n = @min(name.len, lower_buf.len);
    for (0..n) |i| lower_buf[i] = std.ascii.toLower(name[i]);
    const lower = lower_buf[0..n];

    switch (kind) {
        .world => {
            if (std.mem.indexOf(u8, lower, "city") != null) return 0;
            if (std.mem.indexOf(u8, lower, "country") != null) return 1;
            return null;
        },
        .asn => {
            if (std.mem.indexOf(u8, lower, "asn") != null) return 0;
            if (std.mem.indexOf(u8, lower, "isp") != null) return 1;
            return null;
        },
        else => return null,
    }
}

fn exists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn absoluteUrl(arena: std.mem.Allocator, origin: []const u8, url: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
        return arena.dupe(u8, url);
    }
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ origin, std.mem.trim(u8, url, "/") });
}

/// 当前平台标识（数据包通常 `any`，保留以兼容平台特定包）。
pub fn currentTarget() []const u8 {
    const builtin = @import("builtin");
    const os = @tagName(builtin.os.tag);
    const arch = @tagName(builtin.cpu.arch);
    const os_name = switch (builtin.os.tag) {
        .windows => "win",
        .linux => "linux",
        .macos => "macos",
        else => os,
    };
    const arch_name = switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => arch,
    };
    // 编译期拼接，无分配
    return std.fmt.comptimePrint("{s}-{s}", .{ os_name, arch_name });
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "镜像模式：包地址按文件名重拼到镜像（不绕过镜像直连平台）" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const platform = "https://p.sc8.fun/components/ip2region-v4-2026.10-any.zip";
    try testing.expectEqualStrings("ip2region-v4-2026.10-any.zip", componentFileName(platform));
    try testing.expectEqualStrings("x.zip", componentFileName("https://a/b/x.zip?v=2#frag"));
    try testing.expectEqualStrings("bare.zip", componentFileName("bare.zip"));

    const mirror = "http://127.0.0.1:8899/ipdb";
    try testing.expectEqualStrings(
        "http://127.0.0.1:8899/ipdb/components/ip2region-v4-2026.10-any.zip",
        try mirrorComponentUrl(arena, mirror, platform),
    );
}

test "本地已有数据时启动立即可用（无网络）" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = "G:/Code/Zig/Pek.ZIP/.zig-cache/mgrtest";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/data");

    var cfg = try config_mod.Config.load(io, gpa, base);
    // 复制真实 xdb 到测试目录（没有就跳过）
    const source = "G:/Code/Rust/Pek.IP/data/ip2region_v4.xdb";
    const dest = base ++ "/data/ip2region_v4.xdb";
    const src = std.Io.Dir.cwd().openFile(io, source, .{}) catch {
        std.debug.print("[SKIP] 无真实 xdb 可供启动测试\n", .{});
        cfg.deinit();
        std.Io.Dir.cwd().deleteTree(io, base) catch {};
        return;
    };
    defer src.close(io);
    const stat = try src.stat(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = src.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(gpa, .limited(stat.size));
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = bytes });
    cfg.deinit();

    const manager = try Manager.start(io, gpa, base, .{ .background = false });
    defer manager.destroy();

    var scratch: Scratch = .{};
    var buf: [128]u8 = undefined;
    const loc = try manager.lookupStr(&scratch, "114.114.114.114");
    std.debug.print("[manager] 114.114.114.114 → {s}（{s}）\n", .{ loc.displayShort(&buf), loc.source.label() });
    try testing.expect(loc.is_china);

    const reserved = try manager.lookupStr(&scratch, "10.0.0.1");
    try testing.expect(reserved.is_private);

    std.Io.Dir.cwd().deleteTree(io, base) catch {};
}

test "后台补缺失败不阻塞查询（错误可见、旧数据保留）" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = "G:/Code/Zig/Pek.ZIP/.zig-cache/mgrtest3";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/Config");
    // 指向必然拒绝连接的地址：验证「失败不崩、不阻塞、错误可见」
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = base ++ "/Config/Ip.toml",
        .data =
        \\StoreUrl = "http://127.0.0.1:1"
        \\DataDir = "data"
        \\CacheDir = "Data/IpCache"
        \\
        ,
    });

    const manager = try Manager.start(io, gpa, base, .{ .background = true, .allow_partial = true });
    defer manager.destroy();

    // 启动立即返回：不需要等网络
    var scratch: Scratch = .{};
    const loc = try manager.lookupStr(&scratch, "10.1.2.3");
    try testing.expect(loc.is_private);

    manager.waitIdle();
    try testing.expect(manager.lastError().len > 0);
    std.debug.print("[manager] 后台错误：{s}\n", .{manager.lastError()});

    // 旧数据（这里没有）不影响"保留地址"判定
    const again = try manager.lookupStr(&scratch, "192.168.0.1");
    try testing.expect(again.is_private);

    std.Io.Dir.cwd().deleteTree(io, base) catch {};
}

test "同步锁：第二个持有者被拒，释放后可再取（进程退出自动释放）" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "G:/Code/Zig/Pek.ZIP/.zig-cache/locktest";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var first = SyncLock.acquire(io, dir) orelse return error.TestUnexpectedResult;
    try testing.expect(SyncLock.acquire(io, dir) == null);
    first.release();

    var again = SyncLock.acquire(io, dir) orelse return error.TestUnexpectedResult;
    again.release();

    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}

test "组件目录缓存新鲜期（CatalogMaxAge）" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "G:/Code/Zig/Pek.ZIP/.zig-cache/catalogtest";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir) catch return error.TestUnexpectedResult;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const now_s: u64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));

    // 1) 没有任何缓存 → 必须联网
    try testing.expect(!catalogCacheFresh(io, arena, dir, 3600));

    // 2) 刚写入 → 新鲜期内可直接用；`max_age = 0` 表示每次都拉
    writeCatalogCache(io, arena, dir, "{\"components\":[]}", "c2ln");
    try testing.expect(catalogCacheFresh(io, arena, dir, 3600));
    try testing.expect(!catalogCacheFresh(io, arena, dir, 0));

    const meta_path = dir ++ "/.catalog.meta";
    var stamp_buf: [40]u8 = undefined;

    // 3) 时间戳回退 2 小时 → 超过 1 小时新鲜期
    const stale = try std.fmt.bufPrint(&stamp_buf, "{d}\n", .{now_s - 7200});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = meta_path, .data = stale });
    try testing.expect(!catalogCacheFresh(io, arena, dir, 3600));

    // 4) 时间戳在未来（时钟回拨）→ 当作不新鲜，重拉一次
    const future = try std.fmt.bufPrint(&stamp_buf, "{d}\n", .{now_s + 86_400});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = meta_path, .data = future });
    try testing.expect(!catalogCacheFresh(io, arena, dir, 3600));

    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}

test "目录缓存验签：留空 PubKey 时用 TOFU 学到的平台公钥（坏签名不被信任）" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = "G:/Code/Zig/Pek.ZIP/.zig-cache/tofutest";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/Data/IpClient");
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/Data/IpCache");

    // 模拟「注册时 TOFU 学到平台公钥」：只把公钥写进 StateDir，配置里的 PubKey 保持空
    const seed: [32]u8 = @splat(13);
    const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const pk = key_pair.public_key.toBytes();
    var pk_hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (pk, 0..) |byte, i| {
        pk_hex[i * 2] = hex_chars[byte >> 4];
        pk_hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = base ++ "/Data/IpClient/pubkey.txt",
        .data = &pk_hex,
    });

    const manager = try Manager.start(io, gpa, base, .{ .background = false });
    defer manager.destroy();

    // 配置留空 + 存在 TOFU 公钥 → 必须判定为「要验签」（旧实现这里是直接跳过验签）
    try testing.expectEqualStrings("", manager.cfg.pubkey);
    try testing.expect(manager.verifyKeySource() == .tofu);
    try testing.expectEqualStrings(&pk_hex, manager.catalogVerifyKey().?);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 正确签名 → 缓存可用
    const body = "{\"components\":[]}";
    const signature = try key_pair.sign(body, null);
    var sig_buf: [128]u8 = undefined;
    const sig_text = std.base64.standard.Encoder.encode(&sig_buf, &signature.toBytes());
    writeCatalogCache(io, arena, manager.cfg.cache_dir, body, sig_text);
    try testing.expectEqualStrings(body, (try manager.loadCachedCatalog(arena)).?);

    // 正文被改（签名不动）→ 缓存不可信，返回 null 触发联网重拉（撤掉修复后这里会拿到被篡改的目录）
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = base ++ "/Data/IpCache/.catalog.json",
        .data = "{\"components\":[{\"id\":\"evil\"}]}",
    });
    try testing.expect((try manager.loadCachedCatalog(arena)) == null);

    std.Io.Dir.cwd().deleteTree(io, base) catch {};
}

test "并发读取期间热替换不崩溃（引用计数）" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = "G:/Code/Zig/Pek.ZIP/.zig-cache/mgrtest2";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const manager = try Manager.start(io, gpa, base, .{ .background = false, .download_missing = false });
    defer manager.destroy();

    // 反复发布新的空定位器，模拟后台替换；同时并发读
    const Worker = struct {
        fn run(mgr: *Manager) void {
            var scratch: Scratch = .{};
            for (0..2000) |_| {
                if (mgr.acquire()) |shared| {
                    const loc = shared.locator.lookup(&scratch, .{ .v4 = 0x0808_0808 }) catch continue;
                    std.mem.doNotOptimizeAway(loc.source);
                    mgr.release(shared);
                }
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{manager});
    for (0..50) |_| manager.publish(Locator{});
    for (&threads) |thread| thread.join();

    std.Io.Dir.cwd().deleteTree(io, base) catch {};
}

test "定时检查更新：destroy 能立即叫停等待中的后台线程" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = "G:/Code/Zig/Pek.ZIP/.zig-cache/mgrtest3";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    // StoreUrl 留空（离线模式）：首轮 ensureAll 立刻返回，之后进入 60 分钟的等待
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/Config");
    try fsutil.writeFileAtomic(io, gpa, base ++ "/Config/Ip.toml",
        \\StoreUrl = "http://127.0.0.1:1"
        \\AutoEnroll = false
        \\DownloadV6 = false
        \\DataDir = "data"
        \\CacheDir = "cache"
        \\StateDir = "client"
        \\HttpTimeoutMs = 2000
        \\
    );

    const manager = try Manager.start(io, gpa, base, .{
        .background = true,
        .auto_update_minutes = 60,
    });
    manager.waitIdle(); // 首轮跑完

    const start = std.Io.Clock.real.now(io).nanoseconds;
    manager.destroy(); // 必须唤醒等待并退出，而不是等满 60 分钟
    const elapsed_ms = @divTrunc(std.Io.Clock.real.now(io).nanoseconds - start, std.time.ns_per_ms);
    try testing.expect(elapsed_ms < 3000);
}
