//! 查询热路径基准（固定 `ReleaseFast`）。
//!
//! ```text
//! zig build bench -- <数据目录> [轮数=200000]
//! ```
//!
//! 输出：xdb / MMDB / 合并 / 纯保留地址 四类查询的 **ns/op 与 QPS**，
//! 并单独测「多线程并发读」的聚合吞吐（验证零锁共享）。

const std = @import("std");
const pek = @import("pek_zip");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const data_dir: []const u8 = if (args.len > 1) args[1] else "G:/Code/Rust/Pek.IP/data";
    const rounds: u32 = if (args.len > 2) std.fmt.parseInt(u32, args[2], 10) catch 200_000 else 200_000;

    var locator = pek.Locator{};
    defer locator.deinit();

    const v4_path = try std.fmt.allocPrint(arena, "{s}/ip2region_v4.xdb", .{data_dir});
    const world_path = try std.fmt.allocPrint(arena, "{s}/dbip-country-lite-2026-10.mmdb", .{data_dir});
    const asn_path = try std.fmt.allocPrint(arena, "{s}/dbip-asn-lite-2026-10.mmdb", .{data_dir});

    locator.xdb_v4 = try pek.XdbReader.open(io, gpa, v4_path);
    if (std.Io.Dir.cwd().openFile(io, world_path, .{})) |file| {
        file.close(io);
        locator.world = try pek.MmdbReader.open(io, gpa, world_path, .auto);
    } else |_| {}
    if (std.Io.Dir.cwd().openFile(io, asn_path, .{})) |file| {
        file.close(io);
        locator.world_asn = try pek.MmdbReader.open(io, gpa, asn_path, .auto);
    } else |_| {}

    // 固定的伪随机 IP 序列（同一序列复用，避免随机数开销干扰测量）
    var ips: std.ArrayList(pek.IpAddr) = .empty;
    defer ips.deinit(gpa);
    var state: u64 = 0x2545_f491_4f6c_dd1d;
    for (0..4096) |_| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const value: u32 = @truncate(state >> 32);
        ips.append(gpa, state: {
            // 取国内段（114.114.0.0/16 = 江苏等）——中文场景下绝大多数查询是国内 IP，
            // 这样「合并 vs 国内快路径」的差异才是真实业务差异
            const high: u32 = (value & 0x0000_ffff) | 0x7272_0000; // 114.114.0.0/16（江苏，国内命中）
            break :state .{ .v4 = high };
        }) catch unreachable;
    }

    var out_buf: [256]u8 = undefined;
    const out = &out_buf;
    _ = out;

    const results = [_]struct { name: []const u8, kind: Kind }{
        .{ .name = "xdb (ip2region v4)", .kind = .xdb },
        .{ .name = "mmdb (国外库)", .kind = .mmdb },
        .{ .name = "合并 lookup", .kind = .merged },
        .{ .name = "合并 lookup（国内快路径）", .kind = .merged_fast },
        .{ .name = "保留地址短路", .kind = .reserved },
    };

    for (results) |item| {
        var scratch: pek.Scratch = .{};
        var sink: u64 = 0;
        const start = std.Io.Clock.real.now(io).nanoseconds;
        for (0..rounds) |index| {
            const ip = ips.items[index % ips.items.len];
            switch (item.kind) {
                .xdb => {
                    const text = locator.xdb_v4.?.lookup(ip) catch null;
                    if (text) |t| sink +%= t.len;
                },
                .mmdb => {
                    const rec = locator.world.?.lookupWorld(ip) catch null;
                    if (rec) |r| {
                        if (r.country_code) |code| sink +%= code.len;
                    }
                },
                .merged => {
                    const loc = locator.lookup(&scratch, ip) catch continue;
                    sink +%= loc.source.label().len;
                },
                .merged_fast => {
                    const loc = locator.lookupOptions(&scratch, ip, .{ .skip_world_for_china = true }) catch continue;
                    sink +%= loc.source.label().len;
                },
                .reserved => {
                    const loc = locator.lookup(&scratch, .{ .v4 = 0x0a00_0001 }) catch continue;
                    sink +%= if (loc.is_private) 1 else 0;
                },
            }
        }
        const elapsed_ns: u64 = @intCast(std.Io.Clock.real.now(io).nanoseconds - start);
        std.mem.doNotOptimizeAway(sink);

        var line: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "{s:<22} {d:>8} 次  {d:>9.1} ns/op  {d:>10.0} QPS\n", .{
            item.name,
            rounds,
            @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(rounds)),
            @as(f64, @floatFromInt(rounds)) * 1e9 / @as(f64, @floatFromInt(elapsed_ns)),
        });
        try std.Io.File.stdout().writeStreamingAll(io, text);
    }

    // 并发读：4 线程共享同一个只读定位器
    const Worker = struct {
        fn run(loc: *const pek.Locator, list: []const pek.IpAddr, count: u32, sink_out: *u64) void {
            var scratch: pek.Scratch = .{};
            var sink: u64 = 0;
            for (0..count) |index| {
                const location = loc.lookup(&scratch, list[index % list.len]) catch continue;
                sink +%= location.source.label().len;
            }
            sink_out.* = sink;
        }
    };

    const per_thread = rounds / 4;
    const start = std.Io.Clock.real.now(io).nanoseconds;
    var sinks: [4]u64 = @splat(0);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &locator, ips.items, per_thread, &sinks[index] });
    }
    for (&threads) |thread| thread.join();
    const elapsed_ns: u64 = @intCast(std.Io.Clock.real.now(io).nanoseconds - start);
    for (sinks) |sink| std.mem.doNotOptimizeAway(sink);

    var line: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&line, "{s:<22} {d:>8} 次  {d:>9.1} ns/op  {d:>10.0} QPS\n", .{
        "4 线程并发 lookup",
        per_thread * 4,
        @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(per_thread * 4)),
        @as(f64, @floatFromInt(per_thread * 4)) * 1e9 / @as(f64, @floatFromInt(elapsed_ns)),
    });
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

const Kind = enum { xdb, mmdb, merged, merged_fast, reserved };
