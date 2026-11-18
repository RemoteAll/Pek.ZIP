//! 数据文件内存视图：`mmap` 只读映射 / 堆读入 / 借用字节，三者统一生命周期。
//!
//! xdb / MMDB / QQWry 都需要「把整个数据文件当作只读字节切片」，
//! 差异只在如何取得这段内存；该逻辑只在这里实现一次（禁止第三份拷贝）。
//!
//! - `open`：默认 `File.createMemoryMap` 只读映射（Windows/POSIX 由 std.Io 后端实现），
//!   37 MiB 的 v6 库不占进程私有内存，多进程共享页缓存；失败时退化为整文件读入。
//! - `borrow`：借用调用方已有字节（测试 / 上层自行加载）。
//! - `deinit`：只释放自己拥有的资源（映射、堆内存、路径副本）。

const std = @import("std");

/// 打开错误（调用方补齐路径与业务上下文后再报给用户）。
pub const OpenError = error{
    MissingFile,
    EmptyFile,
    ReadFailed,
};

const Storage = union(enum) {
    borrowed,
    owned: []u8,
    mapped: struct {
        mm: std.Io.File.MemoryMap,
        io: std.Io,
    },
};

pub const Blob = struct {
    bytes: []const u8,
    storage: Storage,
    path: ?[]u8,
    gpa: ?std.mem.Allocator,

    pub const OpenOptions = struct {
        /// 不映射，整文件读入堆内存（调试 / 受限环境）。
        no_mmap: bool = false,
    };

    /// 借用已有字节（不接管所有权，`deinit` 不释放）。
    pub fn borrow(bytes: []const u8) Blob {
        return .{ .bytes = bytes, .storage = .borrowed, .path = null, .gpa = null };
    }

    /// 打开文件并建立只读视图。
    pub fn open(io: std.Io, gpa: std.mem.Allocator, path: []const u8, options: OpenOptions) OpenError!Blob {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return OpenError.MissingFile,
            else => return OpenError.ReadFailed,
        };
        defer file.close(io);

        const stat = file.stat(io) catch return OpenError.ReadFailed;
        if (stat.size == 0) return OpenError.EmptyFile;

        const dup_path = gpa.dupe(u8, path) catch return OpenError.ReadFailed;
        errdefer gpa.free(dup_path);

        if (!options.no_mmap) {
            const mapped = file.createMemoryMap(io, .{
                .len = @intCast(stat.size),
                .protection = .{ .read = true },
                .populate = false,
            }) catch null;
            if (mapped) |mm| {
                var blob = Blob{
                    .bytes = mm.memory,
                    .storage = .{ .mapped = .{ .mm = mm, .io = io } },
                    .path = dup_path,
                    .gpa = gpa,
                };
                blob.bytes = blob.storage.mapped.mm.memory;
                return blob;
            }
        }

        const bytes = blk: {
            var read_buffer: [16 * 1024]u8 = undefined;
            var file_reader = file.reader(io, &read_buffer);
            break :blk file_reader.interface.allocRemaining(gpa, .limited(stat.size)) catch return OpenError.ReadFailed;
        };
        errdefer gpa.free(bytes);
        return .{ .bytes = bytes, .storage = .{ .owned = bytes }, .path = dup_path, .gpa = gpa };
    }

    pub fn deinit(self: *Blob) void {
        switch (self.storage) {
            .borrowed => {},
            .owned => |bytes| if (self.gpa) |gpa| gpa.free(bytes),
            .mapped => |mapping| {
                var mm = mapping.mm;
                mm.destroy(mapping.io);
            },
        }
        if (self.path) |p| {
            if (self.gpa) |gpa| gpa.free(p);
            self.path = null;
        }
        self.storage = .borrowed;
        self.bytes = &.{};
    }

    pub fn len(self: Blob) usize {
        return self.bytes.len;
    }

    /// 是否来自 mmap。
    pub fn isMapped(self: Blob) bool {
        return self.storage == .mapped;
    }
};

test "借用 / 打开 / 关闭" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const borrowed = Blob.borrow("abc");
    try std.testing.expectEqualStrings("abc", borrowed.bytes);
    try std.testing.expect(!borrowed.isMapped());

    const path = "G:/Code/Rust/Pek.IP/data/README.md";
    const maybe = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
        std.debug.print("[SKIP] 未找到 {s}\n", .{path});
        return;
    };
    maybe.close(io);

    var blob = try Blob.open(io, gpa, path, .{});
    defer blob.deinit();
    try std.testing.expect(blob.len() > 0);
    try std.testing.expectEqualStrings(path, blob.path.?);

    var blob2 = try Blob.open(io, gpa, path, .{ .no_mmap = true });
    defer blob2.deinit();
    try std.testing.expectEqual(blob.len(), blob2.len());
}
