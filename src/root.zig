//! Pek.ZIP —— Pek 生态 Zig 实现的 IP 归属地库。
//!
//! 对标 Rust `Pek.IP` 与 C# `DH.NIP`（NewLife.IP）：
//!
//! - **国内**：ip2region xdb v3（IPv4/IPv6，省/市/运营商，中文）；
//! - **国外**：MaxMind GeoLite2 / GeoIP2 / DB-IP MMDB（国家/省/市/经纬度/时区/ASN）；
//! - **兼容**：纯真 QQWry（`ip.gz`，GB2312）——DH.NIP 的历史数据格式；
//! - **特殊地址**：内网/回环/链路本地/组播/文档/保留，查库前直接短路；
//! - **启动异步**：先用本地数据立即可用，后台向 Pek.RPanlServer 拉取缺失数据集后热替换。

pub const ip = @import("ip.zig");
pub const country = @import("country.zig");
pub const region = @import("region.zig");
pub const blob = @import("blob.zig");
pub const gb2312 = @import("gb2312.zig");
pub const xdb = @import("xdb.zig");
pub const mmdb = @import("mmdb.zig");
pub const qqwry = @import("qqwry.zig");
pub const qqwry_writer = @import("qqwry_writer.zig");
pub const online = @import("online.zig");
pub const locator = @import("locator.zig");
pub const config = @import("config.zig");
pub const catalog = @import("catalog.zig");
pub const store = @import("store.zig");
pub const http = @import("http.zig");
pub const auth = @import("auth.zig");
pub const manager = @import("manager.zig");

pub const IpAddr = ip.IpAddr;
pub const IpClass = ip.IpClass;
pub const CnRegion = region.CnRegion;
pub const XdbReader = xdb.XdbReader;
pub const MmdbReader = mmdb.MmdbReader;
pub const QqwryReader = qqwry.QqwryReader;
pub const Locator = locator.Locator;
pub const Location = locator.Location;
pub const DataSource = locator.DataSource;
pub const Scratch = locator.Scratch;
pub const Config = config.Config;
pub const Manager = manager.Manager;
pub const StartOptions = manager.StartOptions;
pub const Dataset = manager.Dataset;

// 未使用声明检查：以下类型名对外公开
test {
    _ = ip;
    _ = country;
    _ = region;
    _ = blob;
    _ = gb2312;
    _ = xdb;
    _ = mmdb;
    _ = qqwry;
    _ = qqwry_writer;
    _ = online;
    _ = locator;
    _ = config;
    _ = catalog;
    _ = store;
    _ = http;
    _ = auth;
    _ = manager;
}
