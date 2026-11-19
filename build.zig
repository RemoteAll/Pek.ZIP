const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 库模块：其它 Zig 项目通过 `b.dependency("pek_zip", .{}).module("pek_zip")` 引用
    const lib_module = b.addModule("pek_zip", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    // **测试必须真跑**：Zig 默认会缓存「run test」步的结果，命中缓存时 `zig build test`
    // 只打印 "run test cached"、一行测试输出都没有（看起来像"什么都没做就通过"）。
    // 置 has_side_effects 后每次都真正执行测试二进制。
    //
    // 另注：Zig 0.17.1 的 build runner 在跑 test 产物时会用 `--listen=-` 协议，
    // 我们的测试有大量 stderr 输出（真实数据用例的对照行），某些情况下 stderr 里会出现一行
    // `failed command: ... --listen=-`；实测同一次运行的行内汇总仍是 `67/67 tests passed`、
    // 退出码 0，而同一个二进制**不带 `--listen` 直接跑**（`zig test src/root.zig`）从无此现象。
    // 因此：一键回归以 `zig test src/root.zig` 为准（见 tools/regression.ps1），本步只作开发便捷入口。
    run_tests.has_side_effects = true;
    const test_step = b.step("test", "运行单元测试（含 xdb/mmdb/qqwry 与内核合并逻辑）");
    test_step.dependOn(&run_tests.step);

    // CLI：lookup / selfcheck / sync / bench
    const exe = b.addExecutable(.{
        .name = "zpk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("pek_zip", lib_module);
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.addPassthruArgs();
    const run_step = b.step("run", "运行 CLI（lookup / selfcheck / sync / bench）");
    run_step.dependOn(&run_exe.step);

    // 基准：固定 ReleaseFast（性能测量不能用 debug 档）
    // 库模块也必须 ReleaseFast，否则被测代码仍是 -Odebug，测出来的是调试版性能。
    const fast_lib_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench = b.addExecutable(.{
        .name = "zpk-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/lookup_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench.root_module.addImport("pek_zip", fast_lib_module);
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    const bench_step = b.step("bench", "查询热路径基准（ReleaseFast）");
    bench_step.dependOn(&run_bench.step);
}
