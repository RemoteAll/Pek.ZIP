//! 数据包本地缓存与安装（`{cache}/{dataset}/{version}/`）。
//!
//! 与 Rust `Pek.IP::manager` 同布局：
//!
//! - 解压前先校验 **SHA-256**（调用方算好传入）与 `PK` 头；
//! - 解压用 `std.zip.extract`（已拒绝绝对路径与 `..`，防目录穿越）；
//! - 装完写 `.pek-zip.json` 缓存标记（id / version / sha256 / installedAt / files）；
//! - 先解压到 `.install-*` 临时目录，成功后再整体改名成 `{version}`，避免半成品被当成可用版本；
//! - 只保留最近 `keep_versions` 个版本（默认 1）。
//!
//! 返回的路径/字符串都分配在调用方给的 `arena` 上，随 arena 一起释放。

const std = @import("std");
const catalog_mod = @import("catalog.zig");

pub const Error = error{
    InvalidName,
    NotFound,
    BadMarker,
    NotZip,
    PackageTooLarge,
    ExtractFailed,
    NoDataFiles,
    InstallFailed,
    ReadFailed,
    WriteFailed,
    OutOfMemory,
};

/// 缓存标记文件名。
pub const MARKER_FILE = ".pek-zip.json";

/// 已安装的数据集。
pub const InstalledDb = struct {
    id: []const u8,
    version: []const u8,
    dir: []const u8,
    files: []const []const u8,
    sha256: []const u8,
    installed_at: u64,

    /// 按扩展名查第一个文件（大小写不敏感，`ext` 可带或不带点）。
    pub fn fileWithExt(self: InstalledDb, ext: []const u8) ?[]const u8 {
        const want = if (ext.len > 0 and ext[0] == '.') ext[1..] else ext;
        for (self.files) |path| {
            const found = std.fs.path.extension(path);
            if (found.len != want.len + 1) continue;
            if (std.ascii.eqlIgnoreCase(found[1..], want)) return path;
        }
        return null;
    }

    /// 主数据文件（第一个 `.xdb`，否则第一个 `.mmdb`）。
    pub fn primaryFile(self: InstalledDb) ?[]const u8 {
        return self.fileWithExt("xdb") orelse self.fileWithExt("mmdb");
    }
};

pub const Store = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    cache_dir: []const u8,
    keep_versions: usize = 1,
    package_limit: usize = 512 * 1024 * 1024,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, cache_dir: []const u8) Store {
        return .{ .io = io, .gpa = gpa, .cache_dir = cache_dir };
    }

    /// 查找某数据集的本地最新版本（离线优先）。
    pub fn findLocalLatest(self: Store, arena: std.mem.Allocator, dataset_id: []const u8) Error!?InstalledDb {
        if (!validName(dataset_id)) return Error.InvalidName;
        const dir_path = try std.fs.path.join(arena, &.{ self.cache_dir, dataset_id });
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return Error.ReadFailed,
        };
        defer dir.close(self.io);

        var best: ?[]const u8 = null;
        var iterator = dir.iterate();
        while (iterator.next(self.io) catch return Error.ReadFailed) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (!validName(entry.name)) continue;
            if (best) |current| {
                if (catalog_mod.compareVersions(entry.name, current) != .gt) continue;
            }
            best = try arena.dupe(u8, entry.name);
        }
        const version = best orelse return null;

        return self.loadInstalled(arena, dataset_id, version) catch |err| switch (err) {
            Error.BadMarker, Error.NotFound, Error.ReadFailed => null,
            else => err,
        };
    }

    /// 读取已安装版本（校验缓存标记与文件存在性）。
    pub fn loadInstalled(self: Store, arena: std.mem.Allocator, dataset_id: []const u8, version: []const u8) Error!InstalledDb {
        if (!validName(dataset_id) or !validName(version)) return Error.InvalidName;
        const dir_path = try std.fs.path.join(arena, &.{ self.cache_dir, dataset_id, version });
        const marker_path = try std.fs.path.join(arena, &.{ dir_path, MARKER_FILE });

        const text = blk: {
            const file = std.Io.Dir.cwd().openFile(self.io, marker_path, .{}) catch return Error.NotFound;
            defer file.close(self.io);
            const stat = file.stat(self.io) catch return Error.ReadFailed;
            if (stat.size == 0 or stat.size > 64 * 1024) return Error.BadMarker;
            var buffer: [4096]u8 = undefined;
            var reader = file.reader(self.io, &buffer);
            break :blk reader.interface.allocRemaining(arena, .limited(64 * 1024)) catch return Error.ReadFailed;
        };

        const Marker = struct {
            id: []const u8 = "",
            version: []const u8 = "",
            sha256: []const u8 = "",
            installedAt: u64 = 0,
            files: []const []const u8 = &.{},
        };
        const parsed = std.json.parseFromSlice(Marker, arena, text, .{ .ignore_unknown_fields = true }) catch
            return Error.BadMarker;
        const marker = parsed.value;

        if (!std.ascii.eqlIgnoreCase(marker.id, dataset_id) or marker.version.len == 0) return Error.BadMarker;
        if (marker.files.len == 0) return Error.BadMarker;

        var files: std.ArrayList([]const u8) = .empty;
        for (marker.files) |relative| {
            if (relative.len == 0) continue;
            const full = try std.fs.path.join(arena, &.{ dir_path, relative });
            const file = std.Io.Dir.cwd().openFile(self.io, full, .{}) catch continue;
            file.close(self.io);
            try files.append(arena, full);
        }
        if (files.items.len == 0) return Error.NotFound;

        return .{
            .id = try arena.dupe(u8, marker.id),
            .version = try arena.dupe(u8, marker.version),
            .dir = dir_path,
            .files = try files.toOwnedSlice(arena),
            .sha256 = try arena.dupe(u8, marker.sha256),
            .installed_at = marker.installedAt,
        };
    }

    /// 从本地 zip 安装（SHA-256 由调用方传入并在此与文件内容核对）。
    pub fn installZip(
        self: Store,
        arena: std.mem.Allocator,
        dataset_id: []const u8,
        version: []const u8,
        expected_sha256: []const u8,
        zip_path: []const u8,
    ) Error!InstalledDb {
        if (!validName(dataset_id) or !validName(version)) return Error.InvalidName;

        const stat = std.Io.Dir.cwd().statFile(self.io, zip_path, .{}) catch return Error.NotFound;
        if (stat.size > self.package_limit) return Error.PackageTooLarge;
        if (stat.size < 4) return Error.NotZip;

        // PK\x03\x04 / PK\x05\x06（空包）都接受
        var magic: [4]u8 = undefined;
        {
            const file = std.Io.Dir.cwd().openFile(self.io, zip_path, .{}) catch return Error.NotFound;
            defer file.close(self.io);
            const n = file.readPositionalAll(self.io, &magic, 0) catch return Error.ReadFailed;
            if (n < 2) return Error.NotZip;
            if (magic[0] != 'P' or magic[1] != 'K') return Error.NotZip;
        }

        const actual = try sha256FileHex(self.io, self.gpa, zip_path);
        if (!std.ascii.eqlIgnoreCase(&actual, expected_sha256)) return Error.ExtractFailed;
        const sha_hex = try arena.dupe(u8, &actual);

        const dataset_dir = try std.fs.path.join(arena, &.{ self.cache_dir, dataset_id });
        std.Io.Dir.cwd().createDirPath(self.io, dataset_dir) catch return Error.InstallFailed;

        const stamp = std.Io.Clock.real.now(self.io).nanoseconds;
        const temp_name = try std.fmt.allocPrint(arena, ".install-{s}-{d}", .{ version, @as(u64, @intCast(@mod(stamp, 1_000_000_000))) });
        const temp_dir = try std.fs.path.join(arena, &.{ dataset_dir, temp_name });
        std.Io.Dir.cwd().deleteTree(self.io, temp_dir) catch {};
        std.Io.Dir.cwd().createDirPath(self.io, temp_dir) catch return Error.InstallFailed;
        errdefer std.Io.Dir.cwd().deleteTree(self.io, temp_dir) catch {};

        const extract_dir = try std.fs.path.join(arena, &.{ temp_dir, "data" });
        std.Io.Dir.cwd().createDirPath(self.io, extract_dir) catch return Error.InstallFailed;

        {
            const file = std.Io.Dir.cwd().openFile(self.io, zip_path, .{}) catch return Error.NotFound;
            defer file.close(self.io);
            var buffer: [64 * 1024]u8 = undefined;
            var file_reader = file.reader(self.io, &buffer);
            const dest = std.Io.Dir.cwd().openDir(self.io, extract_dir, .{}) catch return Error.ExtractFailed;
            defer dest.close(self.io);
            std.zip.extract(dest, &file_reader, .{}) catch return Error.ExtractFailed;
        }

        var found: std.ArrayList([]const u8) = .empty;
        try collectDataFiles(self.io, arena, extract_dir, "", &found);
        if (found.items.len == 0) return Error.NoDataFiles;

        const relative_files = try arena.dupe([]const u8, found.items);
        try writeMarker(self.io, arena, extract_dir, dataset_id, version, sha_hex, relative_files);

        const final_dir = try std.fs.path.join(arena, &.{ dataset_dir, version });
        std.Io.Dir.cwd().deleteTree(self.io, final_dir) catch {};
        std.Io.Dir.cwd().rename(extract_dir, std.Io.Dir.cwd(), final_dir, self.io) catch
            return Error.InstallFailed;
        std.Io.Dir.cwd().deleteTree(self.io, temp_dir) catch {};

        self.cleanOldVersions(arena, dataset_id, version) catch {};

        return self.loadInstalled(arena, dataset_id, version);
    }

    /// 只保留最近 `keep_versions` 个版本目录（失败的删除不影响已装版本）。
    pub fn cleanOldVersions(self: Store, arena: std.mem.Allocator, dataset_id: []const u8, keep_version: []const u8) Error!void {
        const keep = if (self.keep_versions == 0) 1 else self.keep_versions;
        const dir_path = try std.fs.path.join(arena, &.{ self.cache_dir, dataset_id });
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var versions: std.ArrayList([]const u8) = .empty;
        var iterator = dir.iterate();
        while (iterator.next(self.io) catch return) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (!validName(entry.name)) continue;
            if (std.mem.eql(u8, entry.name, keep_version)) continue;
            try versions.append(arena, try arena.dupe(u8, entry.name));
        }
        if (versions.items.len < keep) return;

        std.mem.sort([]const u8, versions.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return catalog_mod.compareVersions(a, b) == .lt;
            }
        }.lessThan);

        const removable = versions.items.len - keep + 1;
        for (versions.items[0..removable]) |old| {
            const path = try std.fs.path.join(arena, &.{ dir_path, old });
            std.Io.Dir.cwd().deleteTree(self.io, path) catch {};
        }
    }
};

fn validName(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    if (text[0] == '.') return false;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (c == '.' or c == '_' or c == '-') continue;
        return false;
    }
    return true;
}

/// 递归收集 `.xdb` / `.mmdb`（返回相对 `root` 的路径，正斜杠）。
fn collectDataFiles(
    io: std.Io,
    arena: std.mem.Allocator,
    root: []const u8,
    prefix: []const u8,
    out: *std.ArrayList([]const u8),
) Error!void {
    const path = if (prefix.len == 0)
        try arena.dupe(u8, root)
    else
        try std.fs.path.join(arena, &.{ root, prefix });

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iterator = dir.iterate();
    while (iterator.next(io) catch return) |entry| {
        const relative = if (prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });

        switch (entry.kind) {
            .directory => try collectDataFiles(io, arena, root, relative, out),
            .file => {
                const ext = std.fs.path.extension(entry.name);
                if (std.ascii.eqlIgnoreCase(ext, ".xdb") or std.ascii.eqlIgnoreCase(ext, ".mmdb")) {
                    try out.append(arena, relative);
                }
            },
            else => {},
        }
    }
}

fn writeMarker(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: []const u8,
    id: []const u8,
    version: []const u8,
    sha256: []const u8,
    files: []const []const u8,
) Error!void {
    var buffer: std.ArrayList(u8) = .empty;
    const writer = &buffer;
    writer.appendSlice(arena, "{\n  \"schema\": 1,\n  \"id\": ") catch return Error.OutOfMemory;
    try appendJsonString(writer, arena, id);
    writer.appendSlice(arena, ",\n  \"version\": ") catch return Error.OutOfMemory;
    try appendJsonString(writer, arena, version);
    writer.appendSlice(arena, ",\n  \"sha256\": ") catch return Error.OutOfMemory;
    try appendJsonString(writer, arena, sha256);
    const stamp = std.Io.Clock.real.now(io).nanoseconds;
    const epoch: u64 = if (stamp > 0) @intCast(@divTrunc(stamp, std.time.ns_per_s)) else 0;
    const installed_line = std.fmt.allocPrint(arena, ",\n  \"installedAt\": {d},\n  \"files\": [", .{epoch}) catch return Error.OutOfMemory;
    writer.appendSlice(arena, installed_line) catch return Error.OutOfMemory;
    for (files, 0..) |file, index| {
        if (index > 0) writer.appendSlice(arena, ", ") catch return Error.OutOfMemory;
        try appendJsonString(writer, arena, file);
    }
    writer.appendSlice(arena, "]\n}\n") catch return Error.OutOfMemory;

    const marker_path = std.fs.path.join(arena, &.{ dir, MARKER_FILE }) catch return Error.OutOfMemory;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker_path, .data = buffer.items }) catch
        return Error.WriteFailed;
}

fn appendJsonString(list: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) Error!void {
    list.append(gpa, '"') catch return Error.OutOfMemory;
    for (text) |c| {
        switch (c) {
            '"' => list.appendSlice(gpa, "\\\"") catch return Error.OutOfMemory,
            '\\' => list.appendSlice(gpa, "\\\\") catch return Error.OutOfMemory,
            '\n' => list.appendSlice(gpa, "\\n") catch return Error.OutOfMemory,
            '\r' => list.appendSlice(gpa, "\\r") catch return Error.OutOfMemory,
            '\t' => list.appendSlice(gpa, "\\t") catch return Error.OutOfMemory,
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const escaped = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                    list.appendSlice(gpa, escaped) catch return Error.OutOfMemory;
                } else {
                    list.append(gpa, c) catch return Error.OutOfMemory;
                }
            },
        }
    }
    list.append(gpa, '"') catch return Error.OutOfMemory;
}

/// 流式计算文件 SHA-256（小写 hex，栈上返回）。
pub fn sha256FileHex(io: std.Io, gpa: std.mem.Allocator, path: []const u8) Error![64]u8 {
    _ = gpa;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return Error.NotFound;
    defer file.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = file.readPositionalAll(io, &buffer, offset) catch return Error.ReadFailed;
        if (n == 0) break;
        hasher.update(buffer[0..n]);
        offset += n;
    }
    const digest = hasher.finalResult();
    var out: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return out;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "缓存标记写入与读取（含版本选择）" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = "G:/Code/Zig/Pek.ZIP/.zig-cache/storetest";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const store = Store.init(io, gpa, root);
    const v1 = root ++ "/demo/2026.9";
    try std.Io.Dir.cwd().createDirPath(io, v1);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = v1 ++ "/a.xdb", .data = "x" });
    try writeMarker(io, arena, v1, "demo", "2026.9", "00", &.{"a.xdb"});

    const loaded = try store.loadInstalled(arena, "demo", "2026.9");
    try testing.expectEqual(@as(usize, 1), loaded.files.len);
    try testing.expect(loaded.primaryFile() != null);

    const latest = (try store.findLocalLatest(arena, "demo")).?;
    try testing.expectEqualStrings("2026.9", latest.version);

    try testing.expectError(Error.InvalidName, store.findLocalLatest(arena, "../etc"));

    std.Io.Dir.cwd().deleteTree(io, root) catch {};
}

test "安装真实 zip 固件（SHA-256 + 解压 + 标记 + 版本清理）" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zip_path = "G:/Code/Zig/Pek.ZIP/tests/data/ip2region-test.zip";
    const file = std.Io.Dir.cwd().openFile(io, zip_path, .{}) catch {
        std.debug.print("[SKIP] 缺少固件 {s}（先跑 zpk mkxdb + Compress-Archive）\n", .{zip_path});
        return;
    };
    file.close(io);

    const root = "G:/Code/Zig/Pek.ZIP/.zig-cache/installtest";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const store = Store.init(io, gpa, root);
    const sha = try sha256FileHex(io, gpa, zip_path);

    // 1) 哈希不符必须拒绝，且不留下半成品
    try testing.expectError(Error.ExtractFailed, store.installZip(arena, "ip2region-v4", "2026.10", "00", zip_path));
    try testing.expect((try store.findLocalLatest(arena, "ip2region-v4")) == null);

    // 2) 正确哈希安装成功
    const installed = try store.installZip(arena, "ip2region-v4", "2026.10", &sha, zip_path);
    try testing.expectEqual(@as(usize, 1), installed.files.len);
    try testing.expect(installed.primaryFile() != null);
    try testing.expect(std.mem.endsWith(u8, installed.primaryFile().?, ".xdb"));

    // 3) 能被"最新版本"发现，且 xdb 可正常打开
    const latest = (try store.findLocalLatest(arena, "ip2region-v4")).?;
    try testing.expectEqualStrings("2026.10", latest.version);
    const db = try @import("xdb.zig").XdbReader.open(io, gpa, latest.primaryFile().?);
    defer {
        var owned = db;
        owned.deinit();
    }
    try testing.expectEqualStrings("中国|测试省|测试市|测试运营商|CN", (try db.lookup(.{ .v4 = 0x0100_0001 })).?);

    // 4) 安装第二版后，旧版本按 keep_versions=1 被清掉
    const installed2 = try store.installZip(arena, "ip2region-v4", "2026.11", &sha, zip_path);
    try testing.expectEqualStrings("2026.11", installed2.version);
    try testing.expectError(Error.NotFound, store.loadInstalled(arena, "ip2region-v4", "2026.10"));

    std.Io.Dir.cwd().deleteTree(io, root) catch {};
}
