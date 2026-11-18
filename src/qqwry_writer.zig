//! DB-IP CSV → 纯真 QQWry 数据库转换（对标 C# `DH.NIP::IpCsv`）。
//!
//! 适用场景：手头只有 DB-IP 的 CSV（CC BY 4.0），而线上还在用纯真格式读取。
//!
//! CSV 列序（DB-IP 官方）：
//! `start_ip,end_ip,country_code,country_name,state_prov,district,city,...`
//! 区域串 = `country_name–state_prov–district–city`（空字段跳过；`–` 为 en dash，与 C# 版一致）。
//!
//! 输出格式（纯真，单文件）：
//! ```text
//! [0..4)  索引区起始（固定 8）
//! [4..8)  索引区结束（= 8 + n*7 - 1）
//! 索引：start u32 LE + 数据偏移 u24 LE（7 字节/条，按 start 升序）
//! 数据：end u32 LE + 区域串 GBK + 0x00 + 地址串（空）+ 0x00
//! ```
//!
//! **限制（明确报错，不静默写坏）**：纯真格式的数据偏移只有 24 位，数据区必须 < 16 MiB。
//! DB-IP **city** 级 CSV（数百万行）通常装不下；country/asn 级或按国家裁剪后才可转换。

const std = @import("std");
const gbk = @import("gb2312.zig");
const qqwry = @import("qqwry.zig");

/// 转换错误。
pub const Error = error{
    CsvTooLarge,
    CsvReadFailed,
    NoRecords,
    /// 数据区超过 24 位偏移上限（16 MiB）
    TooLarge,
    WriteFailed,
    OutOfMemory,
};

/// 转换统计。
pub const Stats = struct {
    records: usize,
    data_bytes: usize,
    output_bytes: usize,
    skipped: usize,
};

const Record = struct {
    start: u32,
    end: u32,
    area: []const u8,
};

/// 转换 DB-IP CSV 到纯真格式文件。
pub fn convert(io: std.Io, gpa: std.mem.Allocator, csv_path: []const u8, out_path: []const u8) Error!Stats {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var records: std.ArrayList(Record) = .empty;
    var skipped: usize = 0;

    // ---- 读 CSV ----
    {
        const file = std.Io.Dir.cwd().openFile(io, csv_path, .{}) catch return Error.CsvReadFailed;
        defer file.close(io);

        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &buffer);
        const r = &reader.interface;

        var fields: [16][]const u8 = undefined;
        var seen_first = false;
        while (true) {
            // 必须用 takeDelimiter（返回 ?[]u8）：takeDelimiterExclusive 在真正 EOF 处
            // 会反复返回 0 长度切片而不报 error.EndOfStream，配合 `line.len == 0 → continue` 会死循环。
            const line_opt = r.takeDelimiter('\n') catch return Error.CsvReadFailed;
            const raw = line_opt orelse break;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;

            const count = splitCsvLine(line, &fields);
            // 首个非空行若是 DB-IP 表头（`start_ip,...`），跳过且不计入 skipped：
            // 表头不是被丢弃的数据行，计进去会让"跳过了多少脏数据"这个指标失真。
            if (!seen_first) {
                seen_first = true;
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, fields[0], " \t\""), "start_ip")) continue;
            }
            if (count < 7) {
                skipped += 1;
                continue;
            }
            const start_ip = parseIpv4(fields[0]) orelse {
                skipped += 1;
                continue;
            };
            const end_ip = parseIpv4(fields[1]) orelse {
                skipped += 1;
                continue;
            };
            if (end_ip < start_ip) {
                skipped += 1;
                continue;
            }
            const area = joinArea(arena, &.{ fields[3], fields[4], fields[5], fields[6] }) catch return Error.OutOfMemory;
            if (area.len == 0) {
                skipped += 1;
                continue;
            }
            records.append(arena, .{ .start = start_ip, .end = end_ip, .area = area }) catch return Error.OutOfMemory;
        }
    }

    if (records.items.len == 0) return Error.NoRecords;

    std.mem.sort(Record, records.items, {}, struct {
        fn lessThan(_: void, a: Record, b: Record) bool {
            return a.start < b.start;
        }
    }.lessThan);

    // ---- 编码并写文件 ----
    const n = records.items.len;
    const index_start: u32 = 8;
    const index_bytes: u32 = @intCast(n * 7);
    var data_offset: u32 = index_start + index_bytes;

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var encoder = gbk.Encoder.init(gpa) catch return Error.OutOfMemory;
    defer encoder.deinit();

    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(gpa);
    offsets.ensureTotalCapacity(gpa, n) catch return Error.OutOfMemory;

    for (records.items) |rec| {
        if (data_offset > 0xFF_FFFF) return Error.TooLarge;
        offsets.appendAssumeCapacity(data_offset);

        // before 必须取在写 end_ip **之前**：每条数据块 = 4B end_ip + 区域串 + 2×0x00，
        // 漏算那 4 字节会让后续记录的偏移全部前移 4B，读回时 end_ip 落在区域串尾部（表现为查不到）。
        const before = data.items.len;
        var end_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &end_buf, rec.end, .little);
        data.appendSlice(gpa, &end_buf) catch return Error.OutOfMemory;

        encoder.encodeString(rec.area, &data, gpa) catch return Error.OutOfMemory;
        data.append(gpa, 0) catch return Error.OutOfMemory;
        data.append(gpa, 0) catch return Error.OutOfMemory; // 地址段为空串
        data_offset += @intCast(data.items.len - before);
    }
    if (data_offset > 0xFF_FFFF) return Error.TooLarge;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.ensureTotalCapacity(gpa, data_offset) catch return Error.OutOfMemory;

    var head: [8]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], index_start, .little);
    std.mem.writeInt(u32, head[4..8], index_start + index_bytes - 1, .little);
    out.appendSlice(gpa, &head) catch return Error.OutOfMemory;

    for (records.items, 0..) |rec, i| {
        var start_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &start_buf, rec.start, .little);
        out.appendSlice(gpa, &start_buf) catch return Error.OutOfMemory;
        const off = offsets.items[i];
        out.appendSlice(gpa, &[_]u8{
            @intCast(off & 0xff),
            @intCast((off >> 8) & 0xff),
            @intCast((off >> 16) & 0xff),
        }) catch return Error.OutOfMemory;
    }
    out.appendSlice(gpa, data.items) catch return Error.OutOfMemory;

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.items }) catch return Error.WriteFailed;

    return .{
        .records = n,
        .data_bytes = data.items.len,
        .output_bytes = out.items.len,
        .skipped = skipped,
    };
}

/// 读纯真库校验（转换后用一次，确保能被本库读回）。
pub fn verify(io: std.Io, gpa: std.mem.Allocator, path: []const u8) bool {
    var reader = qqwry.QqwryReader.open(io, gpa, path) catch return false;
    defer reader.deinit();
    return reader.recordCount() > 0;
}

fn parseIpv4(text_in: []const u8) ?u32 {
    const text = std.mem.trim(u8, text_in, " \t\"");
    const ip = @import("ip.zig").IpAddr.parse(text) catch return null;
    return switch (ip) {
        .v4 => |v| v,
        .v6 => null,
    };
}

/// 逗号分隔（支持双引号包裹与 `""` 转义）。
fn splitCsvLine(line: []const u8, out: *[16][]const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i <= line.len and count < out.len) {
        if (i < line.len and line[i] == '"') {
            i += 1;
            const start = i;
            while (i < line.len) : (i += 1) {
                if (line[i] == '"') {
                    if (i + 1 < line.len and line[i + 1] == '"') {
                        i += 1; // 转义的引号
                        continue;
                    }
                    break;
                }
            }
            out[count] = line[start..@min(i, line.len)];
            count += 1;
            // 跳到下一个逗号
            while (i < line.len and line[i] != ',') : (i += 1) {}
            i += 1;
            if (i > line.len) break;
            continue;
        }
        const start = i;
        while (i < line.len and line[i] != ',') : (i += 1) {}
        out[count] = std.mem.trim(u8, line[start..i], " \t");
        count += 1;
        i += 1;
        if (i > line.len) break;
    }
    return count;
}

/// 拼接区域（`–` 分隔，跳过空字段与 "0"）。
fn joinArea(gpa: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var first = true;
    for (parts) |part| {
        const text = std.mem.trim(u8, part, " \t\"");
        if (text.len == 0 or std.mem.eql(u8, text, "0")) continue;
        if (!first) try list.appendSlice(gpa, "\u{2013}");
        try list.appendSlice(gpa, text);
        first = false;
    }
    return list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "CSV → 纯真格式 → 读回" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "G:/Code/Zig/Pek.ZIP/.zig-cache/csvtest";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const csv_path = dir ++ "/dbip.csv";
    const db_path = dir ++ "/qqwry.dat";

    const csv =
        \\start_ip,end_ip,country_code,country_name,state_prov,district,city
        \\1.0.0.0,1.0.0.255,AU,Australia,Queensland,,Brisbane
        \\114.114.114.0,114.114.114.255,CN,China,Jiangsu,Nanjing,Nanjing
        \\not-an-ip,1.2.3.4,XX,Nope,,,
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = csv_path, .data = csv });

    const stats = try convert(io, gpa, csv_path, db_path);
    try testing.expectEqual(@as(usize, 2), stats.records);
    try testing.expectEqual(@as(usize, 1), stats.skipped);

    var reader = try qqwry.QqwryReader.open(io, gpa, db_path);
    defer reader.deinit();
    try testing.expectEqual(@as(u32, 2), reader.recordCount());

    var scratch: qqwry.Scratch = .{};
    const au = (try reader.lookupUtf8(&scratch, 0x0100_0001)).?;
    try testing.expectEqualStrings("Australia\u{2013}Queensland\u{2013}Brisbane", au.area);

    var scratch2: qqwry.Scratch = .{};
    const cn = (try reader.lookupUtf8(&scratch2, 0x7272_7201)).?;
    try testing.expectEqualStrings("China\u{2013}Jiangsu\u{2013}Nanjing\u{2013}Nanjing", cn.area);

    // 中文区域经 GBK 往返
    // 注意：输出文件不能复用 db_path —— 上面的 reader 仍持有该文件的 mmap，
    // 在 Windows 上对已映射的文件再 createFile 会直接 USER_MAPPED_FILE/AccessDenied。
    const csv2 = "start_ip,end_ip,country_code,country_name,state_prov,district,city\n1.0.0.0,1.0.0.255,CN,中国,江苏省,南京市,南京市\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = csv_path, .data = csv2 });
    const db_path2 = dir ++ "/qqwry2.dat";
    _ = try convert(io, gpa, csv_path, db_path2);
    var reader2 = try qqwry.QqwryReader.open(io, gpa, db_path2);
    defer reader2.deinit();
    var scratch3: qqwry.Scratch = .{};
    const zh = (try reader2.lookupUtf8(&scratch3, 0x0100_0001)).?;
    try testing.expectEqualStrings("中国\u{2013}江苏省\u{2013}南京市\u{2013}南京市", zh.area);

    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}

test "CSV 行解析（引号与转义）" {
    var fields: [16][]const u8 = undefined;
    const n = splitCsvLine("1.0.0.0,1.0.0.255,CN,\"China, Mainland\",Jiangsu,,Nanjing", &fields);
    try testing.expectEqual(@as(usize, 7), n);
    try testing.expectEqualStrings("China, Mainland", fields[3]);
    try testing.expectEqualStrings("Nanjing", fields[6]);
}
