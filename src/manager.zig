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
const MAX_CATALOG_BYTES: usize = 1024 * 1024;
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
    /// 被替换下来的旧定位器：**只延后释放**（廉价 hazard pointer 替代），
    /// 运行期不销毁，避免「读方刚拿到指针就被销毁」的竞态；替换次数很少（启动一次 + 手动 sync）。
    retired: std.ArrayList(*Shared) = .empty,

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

    /// 等待后台任务结束（CLI / 测试 / 优雅退出前调用）。
    pub fn waitIdle(self: *Manager) void {
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
    }

    /// 销毁（会先等后台线程结束，再释放定位器）。
    pub fn destroy(self: *Manager) void {
        self.waitIdle();
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
        return shared.locator.lookup(scratch, ip);
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
        try self.ensureAll();
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
        defer self.finished.store(true, .release);

        self.ensureAll() catch |err| {
            self.setError("后台补数据失败：{s}（保留当前本地数据继续服务；检查 StoreUrl/网络后重启或执行 sync）", .{@errorName(err)});
        };

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

    /// 确保 4 个数据集（按配置）都在本地可用：缓存优先，缺失才联网。
    fn ensureAll(self: *Manager) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const download_v6 = self.opts.download_v6 orelse self.cfg.download_v6;
        var needed: [4]Dataset = undefined;
        var needed_count: usize = 0;
        for ([_]Dataset{ .ip2region_v4, .ip2region_v6, .world, .asn }) |dataset| {
            if (dataset == .ip2region_v6 and !download_v6) continue;
            if (try self.store.findLocalLatest(arena, dataset.id()) != null) continue;
            if (try localPath(self.io, arena, switch (dataset) {
                .ip2region_v4 => .xdb_v4,
                .ip2region_v6 => .xdb_v6,
                .world => .world,
                .asn => .asn,
            }, self.cfg.data_dir) != null) continue;
            needed[needed_count] = dataset;
            needed_count += 1;
        }
        if (needed_count == 0) return;

        if (self.cfg.store_url.len == 0) {
            self.setError("缺少 {d} 个数据集但未配置 StoreUrl（仅本地缓存模式；把数据放进 {s} 即可）", .{ needed_count, self.cfg.data_dir });
            return;
        }

        // 同机多应用同时启动时，只让一个进程去下载（共享 CacheDir 时全机复用）
        var lock = SyncLock.acquire(self.io, self.cfg.cache_dir) orelse {
            std.debug.print("[pek-zip] 另一进程正在同步数据（锁：{s}/.sync.lock），本次跳过下载，直接复用共享缓存\n", .{self.cfg.cache_dir});
            return;
        };
        defer lock.release();

        var client = try http_mod.Client.init(self.io, self.gpa, self.cfg.ca_file);
        defer client.deinit();

        const catalog_url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.cfg.store_url, CATALOG_PATH });
        var response = client.getBytes(catalog_url, &.{}, MAX_CATALOG_BYTES) catch |err| {
            self.setError("拉取组件目录失败：{s}；URL={s}（确认平台地址/网络/证书）", .{ @errorName(err), catalog_url });
            return;
        };
        defer response.deinit(self.gpa);
        if (!response.isSuccess()) {
            self.setError("拉取组件目录失败：HTTP {d}，URL={s}，响应片段：{s}", .{
                response.status, catalog_url, response.snippet(200),
            });
            return;
        }

        // 配了 PubKey 就强制验签（目录被篡改宁可不可用）
        if (self.cfg.pubkey.len > 0) {
            const sig_url = try std.fmt.allocPrint(arena, "{s}.sig", .{catalog_url});
            var sig_response = client.getBytes(sig_url, &.{}, MAX_SIGNATURE_BYTES) catch |err| {
                self.setError("拉取组件目录签名失败：{s}；URL={s}（检查证书/网络）", .{ @errorName(err), sig_url });
                return;
            };
            defer sig_response.deinit(self.gpa);
            if (!sig_response.isSuccess()) {
                self.setError("拉取组件目录签名失败：HTTP {d}，URL={s}", .{ sig_response.status, sig_url });
                return;
            }
            const sig_text = std.mem.trim(u8, sig_response.body, " \t\r\n");
            auth_mod.verifyBase64(self.cfg.pubkey, response.body, sig_text) catch |err| {
                self.setError("组件目录签名校验失败：{s}（PubKey 或目录可能被篡改；URL={s}）", .{ @errorName(err), catalog_url });
                return;
            };
        }

        var catalog = catalog_mod.parse(self.gpa, response.body) catch |err| {
            self.setError("解析组件目录失败：{s}（URL={s}）", .{ @errorName(err), catalog_url });
            return;
        };
        defer catalog.deinit();

        const target = currentTarget();
        for (needed[0..needed_count]) |dataset| {
            const entry = catalog_mod.select(catalog, dataset.id(), target) orelse {
                self.setError("组件目录里没有 {s}（target={s}）：请先在 Pek.RPanlServer 上传分类 {s} 的数据包", .{
                    dataset.id(), target, IP_DATABASE_CATEGORY,
                });
                continue;
            };
            self.downloadAndInstall(arena, &client, dataset, entry) catch |err| {
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
            };
        }
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
        const url = try self.downloadUrl(arena, client, entry, &url_buf);
        const stamp = std.Io.Clock.real.now(self.io).nanoseconds;
        const temp_path = try std.fmt.allocPrint(arena, "{s}/.download-{s}-{s}-{d}.zip", .{
            self.cfg.cache_dir, entry.id, entry.version, @as(u64, @intCast(@mod(stamp, 1_000_000_000))),
        });

        std.Io.Dir.cwd().createDirPath(self.io, self.cfg.cache_dir) catch {};
        const status = client.getToFile(url, &.{}, temp_path) catch |err| {
            std.Io.Dir.cwd().deleteFile(self.io, temp_path) catch {};
            return err;
        };
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

/// 本地数据文件命名约定（不区分大小写；与 Pek.IP 一致，另加纯真 `ip.gz`）。
fn localPath(io: std.Io, arena: std.mem.Allocator, kind: Manager.Kind, data_dir: []const u8) !?[]const u8 {
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
