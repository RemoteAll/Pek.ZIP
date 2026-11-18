//! Pek.RPanlServer 组件目录（`/components/catalog.json`）解析与选择。
//!
//! 条目字段与平台一致：`id / name / category / version / target / sha256 / url / sizeKB / notes`。
//! 单条无效不影响其它条目（与平台端驱动/插件源同策略）。

const std = @import("std");

pub const Error = error{
    InvalidJson,
    MissingComponents,
    OutOfMemory,
};

/// 组件条目。
pub const Entry = struct {
    id: []u8,
    name: []u8,
    category: []u8,
    version: []u8,
    target: []u8,
    /// 小写 hex（64 位）。
    sha256: []u8,
    url: []u8,
    size_kb: i64,
    notes: []u8,

    pub fn deinit(self: Entry, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.category);
        gpa.free(self.version);
        gpa.free(self.target);
        gpa.free(self.sha256);
        gpa.free(self.url);
        gpa.free(self.notes);
    }
};

/// 目录（条目按平台返回顺序）。
pub const Catalog = struct {
    entries: []Entry,
    /// 被跳过的无效条目数（字段缺失/哈希非法）。
    skipped: usize,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Catalog) void {
        for (self.entries) |entry| entry.deinit(self.gpa);
        self.gpa.free(self.entries);
        self.entries = &.{};
    }
};

/// 解析目录 JSON。
pub fn parse(gpa: std.mem.Allocator, text: []const u8) Error!Catalog {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return Error.InvalidJson;
    defer parsed.deinit();

    const components = switch (parsed.value) {
        .object => |obj| obj.get("components") orelse return Error.MissingComponents,
        else => return Error.MissingComponents,
    };
    const items = switch (components) {
        .array => |arr| arr.items,
        else => return Error.MissingComponents,
    };

    var list: std.ArrayList(Entry) = .empty;
    errdefer {
        for (list.items) |entry| entry.deinit(gpa);
        list.deinit(gpa);
    }
    var skipped: usize = 0;

    for (items) |item| {
        const entry = parseEntry(gpa, item) catch {
            skipped += 1;
            continue;
        };
        list.append(gpa, entry) catch {
            entry.deinit(gpa);
            return Error.OutOfMemory;
        };
    }

    return .{
        .entries = list.toOwnedSlice(gpa) catch return Error.OutOfMemory,
        .skipped = skipped,
        .gpa = gpa,
    };
}

fn parseEntry(gpa: std.mem.Allocator, item: std.json.Value) !Entry {
    const object = switch (item) {
        .object => |obj| obj,
        else => return error.InvalidEntry,
    };

    const id = try fieldString(gpa, object, "id");
    errdefer gpa.free(id);
    if (id.len == 0) return error.InvalidEntry;

    const version = try fieldString(gpa, object, "version");
    errdefer gpa.free(version);
    if (version.len == 0) return error.InvalidEntry;

    const sha256 = try fieldString(gpa, object, "sha256");
    errdefer gpa.free(sha256);
    if (sha256.len != 64) return error.InvalidEntry;
    for (sha256) |c| {
        if (!std.ascii.isHex(c)) return error.InvalidEntry;
    }
    for (sha256) |*c| c.* = std.ascii.toLower(c.*);

    const url = try fieldString(gpa, object, "url");
    errdefer gpa.free(url);
    if (url.len == 0) return error.InvalidEntry;

    const name = try fieldString(gpa, object, "name");
    errdefer gpa.free(name);
    const category = try fieldString(gpa, object, "category");
    errdefer gpa.free(category);
    var target = try fieldString(gpa, object, "target");
    errdefer gpa.free(target);
    if (target.len == 0) {
        gpa.free(target);
        target = try gpa.dupe(u8, "any");
    }
    const notes = try fieldString(gpa, object, "notes");
    errdefer gpa.free(notes);

    const size_kb: i64 = switch (object.get("sizeKB") orelse .null) {
        .integer => |v| v,
        .float => |v| @intFromFloat(v),
        else => 0,
    };

    return .{
        .id = id,
        .name = name,
        .category = category,
        .version = version,
        .target = target,
        .sha256 = sha256,
        .url = url,
        .size_kb = size_kb,
        .notes = notes,
    };
}

fn fieldString(gpa: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return gpa.dupe(u8, "");
    return switch (value) {
        .string => |s| gpa.dupe(u8, std.mem.trim(u8, s, " \t\r\n")),
        else => gpa.dupe(u8, ""),
    };
}

/// 选包：id 匹配 → `any` 优先、其次当前平台；同优先级取最高版本。
pub fn select(catalog: Catalog, dataset_id: []const u8, target: []const u8) ?*const Entry {
    var best: ?*const Entry = null;
    for (catalog.entries) |*entry| {
        if (!std.ascii.eqlIgnoreCase(entry.id, dataset_id)) continue;
        const is_any = std.ascii.eqlIgnoreCase(entry.target, "any");
        if (!is_any and !std.ascii.eqlIgnoreCase(entry.target, target)) continue;
        if (best) |current| {
            const current_any = std.ascii.eqlIgnoreCase(current.target, "any");
            if (is_any == current_any) {
                if (compareVersions(entry.version, current.version) != .gt) continue;
            } else if (!is_any) {
                continue; // any 优先
            }
        }
        best = entry;
    }
    return best;
}

/// 版本号按数字分段比较（`2026.10.1 > 2026.9.9`；非数字段按字典序）。
pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const pa = ia.next();
        const pb = ib.next();
        if (pa == null and pb == null) return .eq;
        if (pa == null) return .lt;
        if (pb == null) return .gt;

        const na = std.fmt.parseInt(u64, pa.?, 10) catch null;
        const nb = std.fmt.parseInt(u64, pb.?, 10) catch null;
        if (na != null and nb != null) {
            if (na.? < nb.?) return .lt;
            if (na.? > nb.?) return .gt;
            continue;
        }
        switch (std.mem.order(u8, pa.?, pb.?)) {
            .lt => return .lt,
            .gt => return .gt,
            .eq => continue,
        }
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

const sample =
    \\{"components":[
    \\ {"id":"ip2region-v4","name":"ip2region IPv4","category":"ip-database","version":"2026.10","target":"any",
    \\  "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","url":"/components/a.zip","sizeKB":5120},
    \\ {"id":"ip2region-v4","name":"ip2region IPv4 (win)","category":"ip-database","version":"2026.11","target":"win-x64",
    \\  "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","url":"/components/b.zip","sizeKB":5120},
    \\ {"id":"geolite2-city","version":"2026.09","sha256":"bad","url":"/components/c.zip"},
    \\ {"version":"2026.01","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","url":"/x"}
    \\]}
;

test "解析目录并跳过无效条目" {
    const gpa = testing.allocator;
    var catalog = try parse(gpa, sample);
    defer catalog.deinit();
    try testing.expectEqual(@as(usize, 2), catalog.entries.len);
    try testing.expectEqual(@as(usize, 2), catalog.skipped);
    try testing.expectEqualStrings("any", catalog.entries[0].target);
}

test "选包：any 优先、其次平台、再比版本" {
    const gpa = testing.allocator;
    var catalog = try parse(gpa, sample);
    defer catalog.deinit();

    const any_entry = select(catalog, "ip2region-v4", "win-x64").?;
    try testing.expectEqualStrings("any", any_entry.target);

    const catalog2_text =
        \\{"components":[
        \\ {"id":"x","version":"2026.10","target":"win-x64","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","url":"/a.zip"},
        \\ {"id":"x","version":"2026.9","target":"win-x64","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","url":"/b.zip"}
        \\]}
    ;
    var catalog2 = try parse(gpa, catalog2_text);
    defer catalog2.deinit();
    const newest = select(catalog2, "x", "win-x64").?;
    try testing.expectEqualStrings("2026.10", newest.version);
    try testing.expect(select(catalog2, "x", "linux-x64") == null);
    try testing.expect(select(catalog2, "nope", "win-x64") == null);
}

test "版本号比较" {
    try testing.expectEqual(std.math.Order.lt, compareVersions("2026.9", "2026.10"));
    try testing.expectEqual(std.math.Order.gt, compareVersions("2026.10.1", "2026.10"));
    try testing.expectEqual(std.math.Order.eq, compareVersions("2026.10", "2026.10"));
    // 非数字段按字典序："10-a" > "10"（真实版本号不用这种写法，仅保证稳定排序）
    try testing.expectEqual(std.math.Order.gt, compareVersions("2026.10-a", "2026.10"));
}
