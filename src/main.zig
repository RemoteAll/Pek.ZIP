//! `zpk` —— Pek.ZIP 命令行工具。
//!
//! ```text
//! zpk lookup  <ip>...   查询归属地（本地数据；同时后台补缺，便于观察启动异步行为）
//! zpk sync              阻塞式补齐数据（从 StoreUrl 下载缺失数据集）
//! zpk selfcheck         打印配置、数据集状态与样例查询（排障用）
//! zpk version           版本信息
//!
//! 公共参数：--base <目录>（默认当前目录，配置在 <目录>/Config/Ip.toml）
//! ```

const std = @import("std");
const pek = @import("pek_zip");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const code = run(io, gpa, args) catch |err| {
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "zpk: 失败：{s}\n", .{@errorName(err)}) catch "zpk: 失败\n";
        try std.Io.File.stderr().writeStreamingAll(io, text);
        return std.process.exit(2);
    };
    if (code != 0) std.process.exit(code);
}

fn run(io: std.Io, gpa: std.mem.Allocator, argv: []const [:0]const u8) !u8 {
    var base: []const u8 = ".";
    var online = false;
    var positional: [64][]const u8 = undefined;
    var positional_count: usize = 0;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--base")) {
            i += 1;
            if (i >= argv.len) return usage(io, "缺少 --base 的目录参数");
            base = argv[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--base=")) {
            base = arg["--base=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--online")) {
            online = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return usage(io, "未知参数");
        if (positional_count >= positional.len) return usage(io, "参数过多");
        positional[positional_count] = arg;
        positional_count += 1;
    }

    if (positional_count == 0) return usage(io, "缺少子命令");
    const command = positional[0];

    if (std.mem.eql(u8, command, "version")) {
        try stdout(io, "zpk " ++ VERSION ++ "（Pek.ZIP）\n");
        return 0;
    }

    if (std.mem.eql(u8, command, "lookup")) {
        if (positional_count < 2) return usage(io, "lookup 需要至少一个 IP");
        // 默认只读本地（不因网络卡住）；`--online` 才启用「后台补缺 + 等下载结束」
        const manager = try pek.Manager.start(io, gpa, base, .{
            .background = online,
            .allow_partial = true,
        });
        defer manager.destroy();

        var scratch: pek.Scratch = .{};
        var buf: [128]u8 = undefined;
        var line: [512]u8 = undefined;
        for (positional[1..positional_count]) |text| {
            const location = manager.lookupStr(&scratch, text) catch |err| {
                const msg = try std.fmt.bufPrint(&line, "{s}\t查询失败：{s}\n", .{ text, @errorName(err) });
                try stdout(io, msg);
                continue;
            };
            var ip_buf: [46]u8 = undefined;
            const short = location.displayShort(&buf);
            const class_text = if (location.ip_class) |class| class.label() else "";
            const msg = try std.fmt.bufPrint(&line, "{s}\t{s}\t{s}\t{s}\n", .{
                location.ip.toString(&ip_buf),
                short,
                location.source.label(),
                // 保留地址的「国家」本身就是分类标签，不重复打印
                if (std.mem.eql(u8, class_text, short)) "" else class_text,
            });
            try stdout(io, msg);
        }

        // `--online`：等后台补数据结束再退出（既看到"立即可用"，又能确认下载结果）
        manager.waitIdle();
        if (manager.lastError().len > 0) {
            const msg = try std.fmt.bufPrint(&line, "后台数据任务：{s}\n", .{manager.lastError()});
            try stderr(io, msg);
            return 1;
        }
        return 0;
    }

    if (std.mem.eql(u8, command, "sync")) {
        const manager = try pek.Manager.start(io, gpa, base, .{ .background = false, .allow_partial = true });
        defer manager.destroy();
        try manager.ensureNow();
        try printStatus(io, manager);
        return if (manager.lastError().len > 0) 1 else 0;
    }

    if (std.mem.eql(u8, command, "selfcheck")) {
        const manager = try pek.Manager.start(io, gpa, base, .{ .background = false });
        defer manager.destroy();
        try printStatus(io, manager);

        var scratch: pek.Scratch = .{};
        var buf: [128]u8 = undefined;
        var line: [512]u8 = undefined;
        const samples = [_][]const u8{ "114.114.114.114", "8.8.8.8", "223.5.5.5", "10.0.0.1", "240e:3b7:3273:51d0::1" };
        for (samples) |text| {
            const location = manager.lookupStr(&scratch, text) catch |err| {
                const msg = try std.fmt.bufPrint(&line, "  {s}\t查询失败：{s}\n", .{ text, @errorName(err) });
                try stdout(io, msg);
                continue;
            };
            const msg = try std.fmt.bufPrint(&line, "  {s}\t{s}\t({s})\n", .{
                text, location.displayShort(&buf), location.source.label(),
            });
            try stdout(io, msg);
        }
        return 0;
    }

    if (std.mem.eql(u8, command, "mkxdb")) {
        // 测试/演示用：生成一个最小合法的 IPv4 xdb（一条 1.0.0.0/24 记录）
        if (positional_count < 2) return usage(io, "mkxdb 需要输出路径");
        const out_path = positional[1];
        const region: []const u8 = if (positional_count > 2) positional[2] else "中国|测试省|测试市|测试运营商|CN";
        const records = [_]pek.xdb.TestRecordV4{
            // 覆盖自检/回归样例：114.114.114.114 与 8.8.8.8
            .{ .start = 0x7272_7200, .end = 0x7272_72ff, .region = region },
            .{ .start = 0x0808_0800, .end = 0x0808_08ff, .region = "Australia|Queensland|Brisbane|0|AU" },
        };
        const bytes = try pek.xdb.buildXdbV4(gpa, &records, 1);
        defer gpa.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = bytes });
        try stdout(io, "已生成最小 xdb\n");
        return 0;
    }

    return usage(io, "未知子命令");
}

fn printStatus(io: std.Io, manager: *pek.Manager) !void {
    var line: [1024]u8 = undefined;
    const cfg = manager.cfg;
    try stdout(io, try std.fmt.bufPrint(&line, "StoreUrl : {s}\nDataDir  : {s}\nCacheDir : {s}\nPubKey   : {s}\nDownloadV6: {}\n", .{
        cfg.store_url,
        cfg.data_dir,
        cfg.cache_dir,
        if (cfg.pubkey.len == 0) "(未配置：不校验目录签名)" else cfg.pubkey,
        cfg.download_v6,
    }));

    for ([_]pek.Dataset{ .ip2region_v4, .ip2region_v6, .world, .asn }) |dataset| {
        const state = manager.datasetState(dataset);
        try stdout(io, try std.fmt.bufPrint(&line, "{s:<18} {s}\n", .{
            dataset.label(),
            if (state.path.len > 0) state.path else state.error_text,
        }));
    }
    if (manager.lastError().len > 0) {
        try stdout(io, try std.fmt.bufPrint(&line, "最近错误  : {s}\n", .{manager.lastError()}));
    }
}

fn usage(io: std.Io, reason: []const u8) !u8 {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf,
        \\zpk: {s}
        \\
        \\用法：
        \\  zpk lookup <ip>... [--online] [--base <目录>]
        \\  zpk sync [--base <目录>]
        \\  zpk selfcheck [--base <目录>]
        \\  zpk version
        \\
    , .{reason}) catch "zpk: 用法错误\n";
    try stderr(io, text);
    return 2;
}

fn stdout(io: std.Io, text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

fn stderr(io: std.Io, text: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, text);
}

const VERSION = "0.1.0";
