//! ISO 3166-1 alpha-2 → 简体中文名 / 洲代码 → 中文名。
//!
//! 数据与 Rust `Pek.IP::country` 完全一致（Unicode CLDR zh-Hans territories 子集），
//! 编译期排序后用二分查找：不分配内存、O(log n)、大小写不敏感。

const std = @import("std");

const Entry = struct { code: []const u8, zh: []const u8 };

const raw_entries = [_]Entry{
    .{ .code = "AC", .zh = "阿森松岛" },
    .{ .code = "AD", .zh = "安道尔" },
    .{ .code = "AE", .zh = "阿拉伯联合酋长国" },
    .{ .code = "AF", .zh = "阿富汗" },
    .{ .code = "AG", .zh = "安提瓜和巴布达" },
    .{ .code = "AI", .zh = "安圭拉" },
    .{ .code = "AL", .zh = "阿尔巴尼亚" },
    .{ .code = "AM", .zh = "亚美尼亚" },
    .{ .code = "AO", .zh = "安哥拉" },
    .{ .code = "AQ", .zh = "南极洲" },
    .{ .code = "AR", .zh = "阿根廷" },
    .{ .code = "AS", .zh = "美属萨摩亚" },
    .{ .code = "AT", .zh = "奥地利" },
    .{ .code = "AU", .zh = "澳大利亚" },
    .{ .code = "AW", .zh = "阿鲁巴" },
    .{ .code = "AX", .zh = "奥兰群岛" },
    .{ .code = "AZ", .zh = "阿塞拜疆" },
    .{ .code = "BA", .zh = "波斯尼亚和黑塞哥维那" },
    .{ .code = "BB", .zh = "巴巴多斯" },
    .{ .code = "BD", .zh = "孟加拉国" },
    .{ .code = "BE", .zh = "比利时" },
    .{ .code = "BF", .zh = "布基纳法索" },
    .{ .code = "BG", .zh = "保加利亚" },
    .{ .code = "BH", .zh = "巴林" },
    .{ .code = "BI", .zh = "布隆迪" },
    .{ .code = "BJ", .zh = "贝宁" },
    .{ .code = "BL", .zh = "圣巴泰勒米" },
    .{ .code = "BM", .zh = "百慕大" },
    .{ .code = "BN", .zh = "文莱" },
    .{ .code = "BO", .zh = "玻利维亚" },
    .{ .code = "BQ", .zh = "荷属加勒比区" },
    .{ .code = "BR", .zh = "巴西" },
    .{ .code = "BS", .zh = "巴哈马" },
    .{ .code = "BT", .zh = "不丹" },
    .{ .code = "BV", .zh = "布韦岛" },
    .{ .code = "BW", .zh = "博茨瓦纳" },
    .{ .code = "BY", .zh = "白俄罗斯" },
    .{ .code = "BZ", .zh = "伯利兹" },
    .{ .code = "CA", .zh = "加拿大" },
    .{ .code = "CC", .zh = "科科斯（基林）群岛" },
    .{ .code = "CD", .zh = "刚果（金）" },
    .{ .code = "CF", .zh = "中非共和国" },
    .{ .code = "CG", .zh = "刚果（布）" },
    .{ .code = "CH", .zh = "瑞士" },
    .{ .code = "CI", .zh = "科特迪瓦" },
    .{ .code = "CK", .zh = "库克群岛" },
    .{ .code = "CL", .zh = "智利" },
    .{ .code = "CM", .zh = "喀麦隆" },
    .{ .code = "CN", .zh = "中国" },
    .{ .code = "CO", .zh = "哥伦比亚" },
    .{ .code = "CP", .zh = "克利珀顿岛" },
    .{ .code = "CQ", .zh = "萨克岛" },
    .{ .code = "CR", .zh = "哥斯达黎加" },
    .{ .code = "CU", .zh = "古巴" },
    .{ .code = "CV", .zh = "佛得角" },
    .{ .code = "CW", .zh = "库拉索" },
    .{ .code = "CX", .zh = "圣诞岛" },
    .{ .code = "CY", .zh = "塞浦路斯" },
    .{ .code = "CZ", .zh = "捷克" },
    .{ .code = "DE", .zh = "德国" },
    .{ .code = "DG", .zh = "迪戈加西亚岛" },
    .{ .code = "DJ", .zh = "吉布提" },
    .{ .code = "DK", .zh = "丹麦" },
    .{ .code = "DM", .zh = "多米尼克" },
    .{ .code = "DO", .zh = "多米尼加共和国" },
    .{ .code = "DZ", .zh = "阿尔及利亚" },
    .{ .code = "EA", .zh = "休达及梅利利亚" },
    .{ .code = "EC", .zh = "厄瓜多尔" },
    .{ .code = "EE", .zh = "爱沙尼亚" },
    .{ .code = "EG", .zh = "埃及" },
    .{ .code = "EH", .zh = "西撒哈拉" },
    .{ .code = "ER", .zh = "厄立特里亚" },
    .{ .code = "ES", .zh = "西班牙" },
    .{ .code = "ET", .zh = "埃塞俄比亚" },
    .{ .code = "EU", .zh = "欧盟" },
    .{ .code = "EZ", .zh = "欧元区" },
    .{ .code = "FI", .zh = "芬兰" },
    .{ .code = "FJ", .zh = "斐济" },
    .{ .code = "FK", .zh = "福克兰群岛" },
    .{ .code = "FM", .zh = "密克罗尼西亚" },
    .{ .code = "FO", .zh = "法罗群岛" },
    .{ .code = "FR", .zh = "法国" },
    .{ .code = "GA", .zh = "加蓬" },
    .{ .code = "GB", .zh = "英国" },
    .{ .code = "GD", .zh = "格林纳达" },
    .{ .code = "GE", .zh = "格鲁吉亚" },
    .{ .code = "GF", .zh = "法属圭亚那" },
    .{ .code = "GG", .zh = "根西岛" },
    .{ .code = "GH", .zh = "加纳" },
    .{ .code = "GI", .zh = "直布罗陀" },
    .{ .code = "GL", .zh = "格陵兰" },
    .{ .code = "GM", .zh = "冈比亚" },
    .{ .code = "GN", .zh = "几内亚" },
    .{ .code = "GP", .zh = "瓜德罗普" },
    .{ .code = "GQ", .zh = "赤道几内亚" },
    .{ .code = "GR", .zh = "希腊" },
    .{ .code = "GS", .zh = "南乔治亚和南桑威奇群岛" },
    .{ .code = "GT", .zh = "危地马拉" },
    .{ .code = "GU", .zh = "关岛" },
    .{ .code = "GW", .zh = "几内亚比绍" },
    .{ .code = "GY", .zh = "圭亚那" },
    .{ .code = "HK", .zh = "中国香港特别行政区" },
    .{ .code = "HM", .zh = "赫德岛和麦克唐纳群岛" },
    .{ .code = "HN", .zh = "洪都拉斯" },
    .{ .code = "HR", .zh = "克罗地亚" },
    .{ .code = "HT", .zh = "海地" },
    .{ .code = "HU", .zh = "匈牙利" },
    .{ .code = "IC", .zh = "加纳利群岛" },
    .{ .code = "ID", .zh = "印度尼西亚" },
    .{ .code = "IE", .zh = "爱尔兰" },
    .{ .code = "IL", .zh = "以色列" },
    .{ .code = "IM", .zh = "马恩岛" },
    .{ .code = "IN", .zh = "印度" },
    .{ .code = "IO", .zh = "英属印度洋领地" },
    .{ .code = "IQ", .zh = "伊拉克" },
    .{ .code = "IR", .zh = "伊朗" },
    .{ .code = "IS", .zh = "冰岛" },
    .{ .code = "IT", .zh = "意大利" },
    .{ .code = "JE", .zh = "泽西岛" },
    .{ .code = "JM", .zh = "牙买加" },
    .{ .code = "JO", .zh = "约旦" },
    .{ .code = "JP", .zh = "日本" },
    .{ .code = "KE", .zh = "肯尼亚" },
    .{ .code = "KG", .zh = "吉尔吉斯斯坦" },
    .{ .code = "KH", .zh = "柬埔寨" },
    .{ .code = "KI", .zh = "基里巴斯" },
    .{ .code = "KM", .zh = "科摩罗" },
    .{ .code = "KN", .zh = "圣基茨和尼维斯" },
    .{ .code = "KP", .zh = "朝鲜" },
    .{ .code = "KR", .zh = "韩国" },
    .{ .code = "KW", .zh = "科威特" },
    .{ .code = "KY", .zh = "开曼群岛" },
    .{ .code = "KZ", .zh = "哈萨克斯坦" },
    .{ .code = "LA", .zh = "老挝" },
    .{ .code = "LB", .zh = "黎巴嫩" },
    .{ .code = "LC", .zh = "圣卢西亚" },
    .{ .code = "LI", .zh = "列支敦士登" },
    .{ .code = "LK", .zh = "斯里兰卡" },
    .{ .code = "LR", .zh = "利比里亚" },
    .{ .code = "LS", .zh = "莱索托" },
    .{ .code = "LT", .zh = "立陶宛" },
    .{ .code = "LU", .zh = "卢森堡" },
    .{ .code = "LV", .zh = "拉脱维亚" },
    .{ .code = "LY", .zh = "利比亚" },
    .{ .code = "MA", .zh = "摩洛哥" },
    .{ .code = "MC", .zh = "摩纳哥" },
    .{ .code = "MD", .zh = "摩尔多瓦" },
    .{ .code = "ME", .zh = "黑山" },
    .{ .code = "MF", .zh = "法属圣马丁" },
    .{ .code = "MG", .zh = "马达加斯加" },
    .{ .code = "MH", .zh = "马绍尔群岛" },
    .{ .code = "MK", .zh = "北马其顿" },
    .{ .code = "ML", .zh = "马里" },
    .{ .code = "MM", .zh = "缅甸" },
    .{ .code = "MN", .zh = "蒙古" },
    .{ .code = "MO", .zh = "中国澳门特别行政区" },
    .{ .code = "MP", .zh = "北马里亚纳群岛" },
    .{ .code = "MQ", .zh = "马提尼克" },
    .{ .code = "MR", .zh = "毛里塔尼亚" },
    .{ .code = "MS", .zh = "蒙特塞拉特" },
    .{ .code = "MT", .zh = "马耳他" },
    .{ .code = "MU", .zh = "毛里求斯" },
    .{ .code = "MV", .zh = "马尔代夫" },
    .{ .code = "MW", .zh = "马拉维" },
    .{ .code = "MX", .zh = "墨西哥" },
    .{ .code = "MY", .zh = "马来西亚" },
    .{ .code = "MZ", .zh = "莫桑比克" },
    .{ .code = "NA", .zh = "纳米比亚" },
    .{ .code = "NC", .zh = "新喀里多尼亚" },
    .{ .code = "NE", .zh = "尼日尔" },
    .{ .code = "NF", .zh = "诺福克岛" },
    .{ .code = "NG", .zh = "尼日利亚" },
    .{ .code = "NI", .zh = "尼加拉瓜" },
    .{ .code = "NL", .zh = "荷兰" },
    .{ .code = "NO", .zh = "挪威" },
    .{ .code = "NP", .zh = "尼泊尔" },
    .{ .code = "NR", .zh = "瑙鲁" },
    .{ .code = "NU", .zh = "纽埃" },
    .{ .code = "NZ", .zh = "新西兰" },
    .{ .code = "OM", .zh = "阿曼" },
    .{ .code = "PA", .zh = "巴拿马" },
    .{ .code = "PE", .zh = "秘鲁" },
    .{ .code = "PF", .zh = "法属波利尼西亚" },
    .{ .code = "PG", .zh = "巴布亚新几内亚" },
    .{ .code = "PH", .zh = "菲律宾" },
    .{ .code = "PK", .zh = "巴基斯坦" },
    .{ .code = "PL", .zh = "波兰" },
    .{ .code = "PM", .zh = "圣皮埃尔和密克隆群岛" },
    .{ .code = "PN", .zh = "皮特凯恩群岛" },
    .{ .code = "PR", .zh = "波多黎各" },
    .{ .code = "PS", .zh = "巴勒斯坦领土" },
    .{ .code = "PT", .zh = "葡萄牙" },
    .{ .code = "PW", .zh = "帕劳" },
    .{ .code = "PY", .zh = "巴拉圭" },
    .{ .code = "QA", .zh = "卡塔尔" },
    .{ .code = "QO", .zh = "大洋洲边远群岛" },
    .{ .code = "RE", .zh = "留尼汪" },
    .{ .code = "RO", .zh = "罗马尼亚" },
    .{ .code = "RS", .zh = "塞尔维亚" },
    .{ .code = "RU", .zh = "俄罗斯" },
    .{ .code = "RW", .zh = "卢旺达" },
    .{ .code = "SA", .zh = "沙特阿拉伯" },
    .{ .code = "SB", .zh = "所罗门群岛" },
    .{ .code = "SC", .zh = "塞舌尔" },
    .{ .code = "SD", .zh = "苏丹" },
    .{ .code = "SE", .zh = "瑞典" },
    .{ .code = "SG", .zh = "新加坡" },
    .{ .code = "SH", .zh = "圣赫勒拿" },
    .{ .code = "SI", .zh = "斯洛文尼亚" },
    .{ .code = "SJ", .zh = "斯瓦尔巴和扬马延" },
    .{ .code = "SK", .zh = "斯洛伐克" },
    .{ .code = "SL", .zh = "塞拉利昂" },
    .{ .code = "SM", .zh = "圣马力诺" },
    .{ .code = "SN", .zh = "塞内加尔" },
    .{ .code = "SO", .zh = "索马里" },
    .{ .code = "SR", .zh = "苏里南" },
    .{ .code = "SS", .zh = "南苏丹" },
    .{ .code = "ST", .zh = "圣多美和普林西比" },
    .{ .code = "SV", .zh = "萨尔瓦多" },
    .{ .code = "SX", .zh = "荷属圣马丁" },
    .{ .code = "SY", .zh = "叙利亚" },
    .{ .code = "SZ", .zh = "斯威士兰" },
    .{ .code = "TA", .zh = "特里斯坦-达库尼亚群岛" },
    .{ .code = "TC", .zh = "特克斯和凯科斯群岛" },
    .{ .code = "TD", .zh = "乍得" },
    .{ .code = "TF", .zh = "法属南部领地" },
    .{ .code = "TG", .zh = "多哥" },
    .{ .code = "TH", .zh = "泰国" },
    .{ .code = "TJ", .zh = "塔吉克斯坦" },
    .{ .code = "TK", .zh = "托克劳" },
    .{ .code = "TL", .zh = "东帝汶" },
    .{ .code = "TM", .zh = "土库曼斯坦" },
    .{ .code = "TN", .zh = "突尼斯" },
    .{ .code = "TO", .zh = "汤加" },
    .{ .code = "TR", .zh = "土耳其" },
    .{ .code = "TT", .zh = "特立尼达和多巴哥" },
    .{ .code = "TV", .zh = "图瓦卢" },
    .{ .code = "TW", .zh = "台湾" },
    .{ .code = "TZ", .zh = "坦桑尼亚" },
    .{ .code = "UA", .zh = "乌克兰" },
    .{ .code = "UG", .zh = "乌干达" },
    .{ .code = "UM", .zh = "美国本土外小岛屿" },
    .{ .code = "UN", .zh = "联合国" },
    .{ .code = "US", .zh = "美国" },
    .{ .code = "UY", .zh = "乌拉圭" },
    .{ .code = "UZ", .zh = "乌兹别克斯坦" },
    .{ .code = "VA", .zh = "梵蒂冈" },
    .{ .code = "VC", .zh = "圣文森特和格林纳丁斯" },
    .{ .code = "VE", .zh = "委内瑞拉" },
    .{ .code = "VG", .zh = "英属维尔京群岛" },
    .{ .code = "VI", .zh = "美属维尔京群岛" },
    .{ .code = "VN", .zh = "越南" },
    .{ .code = "VU", .zh = "瓦努阿图" },
    .{ .code = "WF", .zh = "瓦利斯和富图纳" },
    .{ .code = "WS", .zh = "萨摩亚" },
    .{ .code = "XA", .zh = "伪地区" },
    .{ .code = "XB", .zh = "伪双向语言地区" },
    .{ .code = "XK", .zh = "科索沃" },
    .{ .code = "YE", .zh = "也门" },
    .{ .code = "YT", .zh = "马约特" },
    .{ .code = "ZA", .zh = "南非" },
    .{ .code = "ZM", .zh = "赞比亚" },
    .{ .code = "ZW", .zh = "津巴布韦" },
    .{ .code = "ZZ", .zh = "未知地区" },
};

/// 编译期按代码升序排好（二分查找前置条件）。
const entries: [raw_entries.len]Entry = blk: {
    @setEvalBranchQuota(200_000);
    var copy = raw_entries;
    var i: usize = 1;
    while (i < copy.len) : (i += 1) {
        const item = copy[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, copy[j - 1].code, item.code) == .gt) : (j -= 1) {
            copy[j] = copy[j - 1];
        }
        copy[j] = item;
    }
    break :blk copy;
};

/// ISO 3166-1 alpha-2 → 简体中文名（大小写不敏感，容忍首尾空白）。
pub fn nameZh(code_in: []const u8) ?[]const u8 {
    const code = std.mem.trim(u8, code_in, " \t");
    if (code.len != 2) return null;
    if (!std.ascii.isAlphabetic(code[0]) or !std.ascii.isAlphabetic(code[1])) return null;

    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.ascii.orderIgnoreCase(code, entries[mid].code)) {
            .lt => hi = mid,
            .gt => lo = mid + 1,
            .eq => return entries[mid].zh,
        }
    }
    return null;
}

/// 常见中文国家名 → ISO 代码（ip2region 旧格式缺 ISO 字段时兜底）。
pub fn codeFromNameZh(name_in: []const u8) ?[]const u8 {
    const name = std.mem.trim(u8, name_in, " \t");
    const table = [_]struct { zh: []const u8, code: []const u8 }{
        .{ .zh = "中国", .code = "CN" },
        .{ .zh = "中华人民共和国", .code = "CN" },
        .{ .zh = "美国", .code = "US" },
        .{ .zh = "日本", .code = "JP" },
        .{ .zh = "韩国", .code = "KR" },
        .{ .zh = "朝鲜", .code = "KP" },
        .{ .zh = "英国", .code = "GB" },
        .{ .zh = "德国", .code = "DE" },
        .{ .zh = "法国", .code = "FR" },
        .{ .zh = "俄罗斯", .code = "RU" },
        .{ .zh = "加拿大", .code = "CA" },
        .{ .zh = "澳大利亚", .code = "AU" },
        .{ .zh = "新西兰", .code = "NZ" },
        .{ .zh = "新加坡", .code = "SG" },
        .{ .zh = "马来西亚", .code = "MY" },
        .{ .zh = "印度尼西亚", .code = "ID" },
        .{ .zh = "印尼", .code = "ID" },
        .{ .zh = "菲律宾", .code = "PH" },
        .{ .zh = "泰国", .code = "TH" },
        .{ .zh = "越南", .code = "VN" },
        .{ .zh = "印度", .code = "IN" },
        .{ .zh = "巴基斯坦", .code = "PK" },
        .{ .zh = "孟加拉国", .code = "BD" },
        .{ .zh = "巴西", .code = "BR" },
        .{ .zh = "阿根廷", .code = "AR" },
        .{ .zh = "墨西哥", .code = "MX" },
        .{ .zh = "智利", .code = "CL" },
        .{ .zh = "南非", .code = "ZA" },
        .{ .zh = "埃及", .code = "EG" },
        .{ .zh = "沙特阿拉伯", .code = "SA" },
        .{ .zh = "阿拉伯联合酋长国", .code = "AE" },
        .{ .zh = "阿联酋", .code = "AE" },
        .{ .zh = "土耳其", .code = "TR" },
        .{ .zh = "西班牙", .code = "ES" },
        .{ .zh = "意大利", .code = "IT" },
        .{ .zh = "荷兰", .code = "NL" },
        .{ .zh = "瑞士", .code = "CH" },
        .{ .zh = "瑞典", .code = "SE" },
        .{ .zh = "挪威", .code = "NO" },
        .{ .zh = "丹麦", .code = "DK" },
        .{ .zh = "芬兰", .code = "FI" },
        .{ .zh = "波兰", .code = "PL" },
        .{ .zh = "乌克兰", .code = "UA" },
        .{ .zh = "中国香港特别行政区", .code = "HK" },
        .{ .zh = "中国香港", .code = "HK" },
        .{ .zh = "香港", .code = "HK" },
        .{ .zh = "中国澳门特别行政区", .code = "MO" },
        .{ .zh = "中国澳门", .code = "MO" },
        .{ .zh = "澳门", .code = "MO" },
        .{ .zh = "台湾", .code = "TW" },
        .{ .zh = "中国台湾", .code = "TW" },
    };
    for (table) |item| {
        if (std.mem.eql(u8, item.zh, name)) return item.code;
    }
    return null;
}

/// 洲代码 → 简体中文名。
pub fn continentNameZh(code_in: []const u8) ?[]const u8 {
    const code = std.mem.trim(u8, code_in, " \t");
    if (code.len != 2) return null;
    const table = [_]struct { code: []const u8, zh: []const u8 }{
        .{ .code = "AF", .zh = "非洲" },
        .{ .code = "AN", .zh = "南极洲" },
        .{ .code = "AS", .zh = "亚洲" },
        .{ .code = "EU", .zh = "欧洲" },
        .{ .code = "NA", .zh = "北美洲" },
        .{ .code = "OC", .zh = "大洋洲" },
        .{ .code = "SA", .zh = "南美洲" },
    };
    for (table) |item| {
        if (std.ascii.eqlIgnoreCase(item.code, code)) return item.zh;
    }
    return null;
}

test "国家名与洲名" {
    try std.testing.expectEqualStrings("中国", nameZh("CN").?);
    try std.testing.expectEqualStrings("美国", nameZh("us").?);
    try std.testing.expectEqualStrings("日本", nameZh(" JP ").?);
    try std.testing.expect(nameZh("ZZZ") == null);
    try std.testing.expect(nameZh("1A") == null);

    try std.testing.expectEqualStrings("CN", codeFromNameZh("中国").?);
    try std.testing.expectEqualStrings("HK", codeFromNameZh("香港").?);
    try std.testing.expect(codeFromNameZh("不存在") == null);

    try std.testing.expectEqualStrings("亚洲", continentNameZh("AS").?);
    try std.testing.expectEqualStrings("北美洲", continentNameZh("na").?);
    try std.testing.expect(continentNameZh("XX") == null);
}

test "国家表严格有序且无重复" {
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        try std.testing.expect(std.mem.order(u8, entries[i - 1].code, entries[i].code) == .lt);
    }
}
