//! GBK（CP936，GB2312 超集）↔ Unicode 映射。
//!
//! 纯真 QQWry 数据（DH.NIP 的 `ip.gz`）里区域/地址串是 GB2312/GBK 编码；
//! 本模块把双字节码位翻成 Unicode 码点，供 `qqwry.zig` 输出 UTF-8。
//!
//! 码表由 `tools/gen_gbk_table.ps1` 用 .NET CP936 生成（与 C#
//! `Encoding.GetEncoding("GB2312")` 同一张表），落在 `src/gb2312.bin`：
//! 126 × 191 = 24066 项，每项 2 字节小端，0 = 不可映射，共 48132 字节。
//! 用二进制 + `@embedFile` 而不是 24k 行 Zig 字面量：源码瘦、编译快、.rodata 只 47 KiB。

const std = @import("std");

/// 码表二进制（24066 × u16 小端）。
const table_bytes = @embedFile("gb2312.bin");

const ROW_COUNT: usize = 191; // 0x40..0xFE（含 0x7F 占位）
const ENTRY_COUNT: usize = 126 * ROW_COUNT;

comptime {
    if (table_bytes.len != ENTRY_COUNT * 2) {
        @compileError("gb2312.bin 尺寸不符：请重新运行 tools/gen_gbk_table.ps1");
    }
}

/// 双字节码位 → Unicode 码点（不可映射返回 null）。
pub fn decode(code: u16) ?u21 {
    const hi: usize = code >> 8;
    const lo: usize = code & 0xff;
    if (hi < 0x81 or hi > 0xFE or lo < 0x40 or lo > 0xFE or lo == 0x7F) return null;
    const index = (hi - 0x81) * ROW_COUNT + (lo - 0x40);
    const offset = index * 2;
    const cp = std.mem.readInt(u16, table_bytes[offset..][0..2], .little);
    if (cp == 0) return null;
    return @intCast(cp);
}

/// 双字节码位 → UTF-8 字节（写入 `out`，返回切片；不可映射返回 null）。
pub fn decodeInto(code: u16, out: *[3]u8) ?[]const u8 {
    const cp = decode(code) orelse return null;
    const len = std.unicode.utf8Encode(cp, out) catch return null;
    return out[0..len];
}

/// 单字节（ASCII）直接透传；用于 QQWry 串里混排的英文。
pub fn isSingleByte(byte: u8) bool {
    return byte < 0x80;
}

/// 反向编码器（Unicode → GBK），供 DB-IP CSV → QQWry 转换工具使用。
///
/// 构建时把码表展开成按码点升序的数组（约 2.4 万项，一次性 ~2 ms），
/// 之后二分查找。只在批量转换工具里各建一次，查询热路径不使用。
pub const Encoder = struct {
    pub const Pair = struct { cp: u21, code: u16 };

    pairs: []Pair,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) !Encoder {
        var list: std.ArrayList(Pair) = .empty;
        errdefer list.deinit(gpa);
        try list.ensureTotalCapacity(gpa, ENTRY_COUNT);

        var hi: u16 = 0x81;
        while (hi <= 0xFE) : (hi += 1) {
            var lo: u16 = 0x40;
            while (lo <= 0xFE) : (lo += 1) {
                if (lo == 0x7F) continue;
                const code = (hi << 8) | lo;
                if (decode(code)) |cp| {
                    list.appendAssumeCapacity(.{ .cp = cp, .code = code });
                }
            }
        }

        const pairs = try list.toOwnedSlice(gpa);
        std.mem.sort(Pair, pairs, {}, struct {
            fn lessThan(_: void, a: Pair, b: Pair) bool {
                return a.cp < b.cp;
            }
        }.lessThan);
        return .{ .pairs = pairs, .gpa = gpa };
    }

    pub fn deinit(self: *Encoder) void {
        self.gpa.free(self.pairs);
        self.pairs = &.{};
    }

    /// Unicode 码点 → GBK 双字节码位。
    pub fn encode(self: Encoder, cp: u21) ?u16 {
        var lo: usize = 0;
        var hi: usize = self.pairs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const item = self.pairs[mid];
            if (item.cp == cp) return item.code;
            if (item.cp < cp) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// UTF-8 文本 → GBK 字节（不可映射的码点写入 `?`）。
    pub fn encodeString(self: Encoder, utf8: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        var view = std.unicode.Utf8View.init(utf8) catch {
            // 非法 UTF-8：整体写 '?'，不静默丢数据
            try out.append(gpa, '?');
            return;
        };
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp < 0x80) {
                try out.append(gpa, @intCast(cp));
                continue;
            }
            if (self.encode(cp)) |code| {
                try out.append(gpa, @intCast(code >> 8));
                try out.append(gpa, @intCast(code & 0xff));
            } else {
                try out.append(gpa, '?');
            }
        }
    }
};

test "典型 GBK 码位" {
    var buf: [3]u8 = undefined;
    // 「中」= D6 D0，「国」= B9 FA
    try std.testing.expectEqualStrings("中", decodeInto(0xD6D0, &buf).?);
    try std.testing.expectEqualStrings("国", decodeInto(0xB9FA, &buf).?);
    try std.testing.expectEqualStrings("电", decodeInto(0xB5E7, &buf).?);
    try std.testing.expect(decode(0x0000) == null);
    try std.testing.expect(decode(0x817F) == null); // 0x7F 无效列
    try std.testing.expect(decode(0xFFFE) == null);
}

test "反向编码往返" {
    const gpa = std.testing.allocator;
    var encoder = try Encoder.init(gpa);
    defer encoder.deinit();

    try std.testing.expectEqual(@as(u16, 0xD6D0), encoder.encode('中').?);
    try std.testing.expectEqual(@as(u16, 0xB9FA), encoder.encode('国').?);
    try std.testing.expect(encoder.encode(0x1F600) == null);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try encoder.encodeString("中国电信", &out, gpa);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xD6, 0xD0, 0xB9, 0xFA, 0xB5, 0xE7, 0xD0, 0xC5 }, out.items);
}
