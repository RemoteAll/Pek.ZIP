//! 文件写入小工具（与 zzig `fsio` 同口径：先写 `.tmp` 再替换）。
//!
//! 为什么要原子写：`Config/Ip.toml`、客户端身份（`install.id` / `client.key` / `pubkey.txt`）
//! 一旦被断电/崩溃截断，轻则配置回退默认、重则客户端身份丢失 → 平台侧要重新审批授权。
//! 目录缓存（`.catalog.*`）坏了只是多拉一次，但顺手也走同一路径，少一套写法。
//!
//! 语义对齐 `G:\Code\Zig\zzig\src\file\fsio.zig`：
//! `writeFileAtomic` = 写 `<path>.tmp` → `replaceFile`（Windows 上覆盖必须先删目标再 rename）。

const std = @import("std");

/// 替换目标文件（先删后 rename；目标不存在也算成功）。
pub fn replaceFile(io: std.Io, from: []const u8, to: []const u8) !void {
    if (std.fs.path.dirname(to)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    std.Io.Dir.cwd().deleteFile(io, to) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.Io.Dir.rename(std.Io.Dir.cwd(), from, std.Io.Dir.cwd(), to, io);
}

/// 原子写：先写 `<path>.tmp`，成功后再替换目标。（临时路径由本函数自己释放）
pub fn writeFileAtomic(io: std.Io, gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    // 目标目录可能还不存在（首次运行），tmp 文件也在同一目录里
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = bytes });
    replaceFile(io, tmp_path, path) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return err;
    };
}

test "原子写：覆盖已有内容且不留 .tmp 残留" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = "G:/Code/Zig/Pek.ZIP/.zig-cache/fsatomic";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const path = dir ++ "/Config/Ip.toml";
    try writeFileAtomic(io, arena, path, "v1");
    try writeFileAtomic(io, arena, path, "v2-longer");

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [64]u8 = undefined;
    var reader = file.reader(io, &buf);
    const text = try reader.interface.allocRemaining(gpa, .limited(64));
    defer gpa.free(text);
    try std.testing.expectEqualStrings("v2-longer", text);

    // 临时文件必须已经被替换掉，不能残留
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, tmp, .{}));
}
