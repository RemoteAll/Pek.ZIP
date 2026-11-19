# Pek.ZIP

`Pek.ZIP` 是 Pek 生态 IP 归属地库的 **Zig** 实现（crate/module `pek_zip`），对标：

- Rust [`Pek.IP`](../Rust/Pek.IP)（`xdb v3` + MaxMind MMDB + 双源合并 + 按需下载）；
- C# [`DH.NIP`](../../Pek.FrameWork/DH.NIP)（NewLife.IP：纯真 `ip.gz` + 在线 API + DB-IP CSV 转换）。

Zig **0.17.1**（本机实测版本；`build.zig.zon` 的最低版本仍为 0.17.0），**零第三方依赖**（全部 std：`Io`/`File.createMemoryMap`/`compress.flate`/`zip`/`json`/`http`）。

## 特性

| 能力 | 说明 |
|------|------|
| 国内 | ip2region **xdb v3**（IPv4/IPv6，Vector/BTree 索引，省/市/运营商） |
| 国外 | **MMDB**（GeoLite2 / GeoIP2 / DB-IP；City/Country/ASN/ISP；24/28/32 位记录） |
| 兼容 | **纯真 QQWry**（`ip.gz`，GBK→UTF-8，`std.compress.flate` 直接解压） |
| 特殊地址 | 内网/回环/链路本地/组播/文档/基准/保留/NAT64/ORCHID —— 查库前短路 |
| 合并 | 国内省市以 xdb 为准，经纬度/时区/区县由 MMDB 补齐；ASN 兜底 ISP |
| 启动异步 | 本地数据**毫秒级**就绪，缺的由后台线程从 **Pek.RPanlServer** 组件源下载后**原子热替换** |
| 性能 | mmap 只读 + 零分配查询 + 无锁共享（见下方实测） |

## 快速开始

```zig
const pek = @import("pek_zip");

// 1) 启动时异步：本地有就立即用，缺的后台下载（推荐）
var manager = try pek.Manager.start(io, gpa, ".", .{ .background = true });
defer manager.destroy();

var scratch: pek.Scratch = .{};
const loc = try manager.lookupStr(&scratch, "114.114.114.114");
var buf: [128]u8 = undefined;
std.debug.print("{s}（{s}）\n", .{ loc.displayShort(&buf), loc.source.label() });
```

```zig
// 2) 手动组装（数据文件自己管）
var locator = pek.Locator{};
defer locator.deinit();
locator.xdb_v4 = try pek.XdbReader.open(io, gpa, "data/ip2region_v4.xdb");
locator.world  = try pek.MmdbReader.open(io, gpa, "data/dbip-city-lite.mmdb", .auto);
locator.world_asn = try pek.MmdbReader.open(io, gpa, "data/dbip-asn-lite.mmdb", .auto);
```

命令行：

```text
zpk lookup 114.114.114.114 8.8.8.8   # 查询（默认只读本地，不因网络卡住）
zpk lookup 114.114.114.114 --online  # 后台补缺并等下载结束再退出
zpk lookup 114.114.114.114 --fast    # 国内命中即跳过 MMDB（快 ~9.5×；代价：无经纬度/时区/区县/ASN）
zpk sync                             # 检查更新：本地齐全也比对目录版本，有新版本才下
zpk sync --force                     # 忽略 CatalogMaxAge 目录缓存，强制联网刷新
zpk selfcheck                        # 配置 + 数据集状态 + 样例查询
zpk mkxdb out.xdb                    # 生成最小 xdb（测试/演示）
```

## 配置（`Config/Ip.toml`，首次运行自动生成）

```toml
StoreUrl   = "https://p.sc8.fun"   # Pek.RPanlServer 平台（固定，一般不改）
PubKey     = ""                   # 留空 = 注册时从平台响应 TOFU 学习公钥并落盘；之后目录强制验签
DataDir    = "data"               # 本地数据目录（xdb/mmdb/ip.gz）
CacheDir   = "Data/IpCache"       # 下载缓存（{id}/{version}/ + .pek-zip.json）
StateDir   = "Data/IpClient"      # 客户端身份（install.id / client.key / pubkey.txt / License）
AutoEnroll = true                 # 未批准时自动向平台申请授权（票据下载）
DownloadV6 = false                # IPv6 xdb 约 37 MiB，默认不下载
CatalogMaxAge = 3600              # 组件目录缓存新鲜期（秒）；期间只读本地，0 = 每次都拉
HttpTimeoutMs = 120000            # 单次请求总超时（毫秒；0 = 不限）
AutoUpdateMinutes = 0             # 后台定时检查更新（分钟；0 = 关闭，常驻服务推荐 360）
# MirrorUrl = "http://127.0.0.1:8899/ipdb"  # 本机镜像（留空 = 自动探测 MirrorProbeUrl）
MirrorProbeUrl = "http://127.0.0.1:5501/ipdb"  # 自动探测地址（空串 = 关闭探测）
# CaFile   = "Config/ca.pem"      # 内网/自签平台的自定义根证书
```

### 带宽与更新策略

- **目录不重复拉**：`catalog.json` 落到 `{CacheDir}/.catalog.json`，`CatalogMaxAge` 内直接用本地缓存
  （**只要拿到过可信公钥就连缓存一起验签**：`PubKey` 非空用配置的，留空用注册时 TOFU 学到的平台公钥；
  时钟回拨/缓存损坏一律按不新鲜处理）。
- **包只在新版本时下**：`zpk sync` 比对目录版本与本地已装版本，同版本/更低一律跳过。
- **同机只下一次**：共享 `CacheDir` 时由 `{CacheDir}/.sync.lock` 独占创建保证一个进程去下载，
  其余进程直接复用；崩溃残留超 10 分钟自动视为陈旧。
- **可从本机镜像取（默认自动发现）**：服务器装了 **Pek.RAgent** 时，客户端会**自动探测**
  `http://127.0.0.1:5501/ipdb`（它的 `/ipdb`；探测超时 800 ms，只在真要联网时探一次，命中即用、未命中直连平台）。
  要改端口/地址就用 `MirrorUrl` 显式指定，或改 `MirrorProbeUrl`；置 `MirrorProbeUrl = ""` 可关闭自动探测。
  镜像布局是 `/ipdb/catalog.json` + `/ipdb/components/*.zip`，只转发平台原始字节，**验签仍用平台公钥**。
  镜像缺文件/没启动/返回非 2xx 时**自动回退平台**，不会因开镜像而同步失败。
  镜像不可用时日志会带**可定位提示**（不是光一句 `HTTP 404`）：
  `404` → RAgent 版本较旧或没开 `IpdbMirrorEnabled`；`403` → 被 WAF 拦或未开镜像；
  `301`／传输失败 → 旧版 RAgent 把明文 301 到 https（升级 RAgent 后可用 http 回环地址）；
  响应是 HTML → 地址可能指到了面板首页（应指向 `/ipdb`）。
  RAgent 面板即使开了 HTTPS，镜像也走上面的 **http 回环地址**：RAgent 连接层只对回环放行 `/ipdb`
  的明文请求（本机取数据不必导入自签证书），非本机访问才 301 到 https。
  RAgent 侧开 `IpdbAutoEnroll` 后会以独立身份向平台注册（首次需在「分发中心 → IP 授权」批准一次），
  之后它就自己取票下包，本机各应用零配置、不再各自连平台。
- **定时更新**：由任一个常驻进程（或计划任务）定时跑 `zpk sync` 即可，其余应用启动只读共享缓存。
  常驻服务可以直接开 `AutoUpdateMinutes`（配置）或 `StartOptions.auto_update_minutes`：
  后台线程按间隔检查，**只在新版本时才下包并在进程内热替换**（`ensureNow` 同路径），
  `destroy()` 会立即叫停而不等满间隔。默认 `0` = 关闭——周期任务默认不开。

### 与 zzig 的关系（复用生态，不重复造）

本项目只依赖 Zig 标准库，但会**对齐并复用自研生态 zzig 的既定口径**（而不是另搞一套）：

| zzig 能力 | 本项目 |
|---|---|
| `http.fetchBytesWithTimeout`（`io.concurrent` + `Future.cancel`） | ✅ 已复用该机制实现请求总超时 |
| `fsio.writeFileAtomic` / `replaceFile`（`.tmp` + 替换） | ✅ `src/fsutil.zig` 同口径，用于客户端身份、`Config/Ip.toml` |
| `net/socket_timeout.setRecvTimeout` | ⏭ 不适用：socket 由 `std.http.Client` 内部持有 |
| `crypto/hash_util.sha256Hex` | ⏭ 我们要的是**流式**算文件 SHA-256，`std.crypto` 已够 |
| `archive/zip.Reader` | ⏭ `std.zip.extract` 已拒绝绝对路径与 `..` |

不直接 `b.dependency("zzig")`：zzig 的 `build.zig.zon` 依赖本地路径 `../lighting`，
作为独立仓库的 Pek.ZIP 绑这个路径会在别的机器上直接跑不起来。

### 性能与调优（实测，ReleaseFast，20 万次/项）

| 场景 | ns/op | 备注 |
|---|---|---|
| xdb（ip2region v4） | 44.9 | 比 ip2region 官方 full-cache（167 ns）还快，因为 mmap 零拷贝 |
| MMDB（国外库） | 1552.6 | 二进制搜索树 + 数据段解析 |
| 合并 lookup（默认） | 1765.4 | 国内 IP 也会为补经纬度/时区/区县 付一次 MMDB |
| 合并 lookup（`--fast` / `skip_world_for_china`） | **186.6** | 国内命中即跳过 MMDB，**9.5×** |
| 保留地址短路 | 9.8 | 内网/回环等不查库 |

- **不做内存缓存/整文件加载**：mmap + 文件内 Vector Index 已经快于官方 full-cache，且零拷贝、多进程共享 page cache。
- **国内快路径默认关闭**：开了会静默丢掉经纬度/时区/区县/ASN，必须显式选。

### 请求超时（复用 zzig 的原生取消，不是自造看门狗）

Zig 0.17.1 的 `std.http.Client` **没有生效的超时**：`ConnectTcpOptions.timeout` 声明了但 `connectTcpOptions` 从不读取它。
但 0.17 有**原生并发取消**：`Io.concurrent(io, fn, args)` → `Future`，`Future.cancel(io)` 会请求取消并**等任务结束**。
同生态 `zzig/src/http/http.zig` 的 `fetchBytesWithTimeout` 已是这套做法（已上线），本项目直接复用该机制（仅把轮询换成
`Io.Condition.waitTimeout`，事件驱动、无空转）。

效果：超时 → 取消请求并**把线程收回来**（不泄漏线程）；实测“只 accept 不回包”的监听 + `HttpTimeoutMs=1200` → **1.25s 返回 Timeout**。

数据文件命名（不区分大小写，与 Pek.IP 一致）：

- IPv4：`data/ip2region_v4.xdb`（兼容 `ip2region.xdb`）
- IPv6：`data/ip2region_v6.xdb`
- 城市/国家：`data/*.mmdb` 且名称含 `city` / `country`
- ASN/ISP：`data/*.mmdb` 且名称含 `asn` / `isp`
- 纯真：`data/ip.gz`（`qqwry.dat` / `ip.dat` 也认）

## 启动时异步：时序

```mermaid
sequenceDiagram
    participant App as 业务
    participant M as Manager
    participant L as Locator(本地)
    participant W as 后台线程
    participant P as Pek.RPanlServer
    App->>M: start(background=true)
    M->>L: mmap 本地 data/ + 缓存（毫秒级）
    M-->>App: 立即可查询（即便一个库都没有）
    M->>W: spawn
    W->>P: GET /components/catalog.json
    W->>P: GET 数据包 zip
    W->>W: SHA-256 校验 → 解压 → 写缓存标记
    W->>L: 重建定位器 → 原子替换（读方无锁）
```

- **读方不取锁**：`acquire` 一次原子加 + 指针复核；旧定位器进「退休列表」，运行期不销毁（廉价 hazard pointer 替代），退出时统一回收。
- **失败不降级**：下载/校验失败只记 `lastError()`，旧数据继续服务；`zpk sync` 返回码 1。
- **为什么是线程**：Zig 0.17 在 Windows 上 socket 读仍是同步 `deviceIoControl`，真异步需自建 AFD/IOCP；放独立线程是当前平台唯一能「启动不等网络」的做法（POSIX 可换 `Io.concurrent`，接口不变）。

## 性能（实测，ReleaseFast，本机 2026-11-19）

数据：`ip2region_v4.xdb`（11 MiB）+ `dbip-country-lite-2026-10.mmdb`（8 MiB，IPv6 树）+ `dbip-asn-lite`，20 万次/项。
样例 IP 取国内段 114.114.0.0/16（中文场景的真实分布）：

| 场景 | ns/op | QPS |
|------|-------|-----|
| xdb（ip2region v4） | 45 | 22,262,542 |
| MMDB（国外库） | 1,553 | 644,072 |
| 合并 lookup | 1,765 | 566,445 |
| 合并 lookup（`skip_world_for_china`） | **187** | **5,358,913** |
| 保留地址短路 | 9.8 | 101,786,350 |
| 4 线程并发 lookup | 471 | 2,123,900 |

参照：ip2region 官方 Rust binding 的 full-cache 是 120–139 ns（avg 167 ns），**我们的 mmap + Vector Index 更快**，
不需要再上内存缓存。复现：`zig build bench -- 'G:/Code/Rust/Pek.IP/data' 200000`（库模块同样 ReleaseFast）。

设计要点：mmap 只读（v6 库 37 MiB 不进进程私有内存，多进程共享页缓存）、查询零分配（切片借用映射内存）、标签/国家名走编译期静态表二分。

## 数据与许可

| 数据 | 用途 | 许可 |
|------|------|------|
| `ip2region_v4.xdb` / `ip2region_v6.xdb` | 国内城市级 | Apache-2.0（ip2region） |
| `dbip-country-lite-*.mmdb` / `dbip-asn-lite-*.mmdb` / `dbip-city-lite-*.mmdb` | 国外 | CC BY 4.0（db-ip.com） |
| `GeoLite2-*.mmdb` | 国外 | MaxMind EULA（需账号） |
| `ip.gz`（纯真） | 兼容旧数据 | 纯真网络（自备） |

**数据文件不入库**（`.gitignore`）：由使用方按各自许可获取，或上传到 Pek.RPanlServer 组件源（分类 `ip-database`）。

## 与两个参考项目的差异

| 项 | Pek.IP | Pek.ZIP |
|----|--------|---------|
| 语言/依赖 | Rust + `maxminddb` + `dhrust` | Zig 0.17 + 纯 std |
| 查询分配 | 返回 `String` | **零分配**（切片借用 mmap） |
| 文件加载 | 全量读入内存 | **mmap 只读**（可 `no_mmap` 退化） |
| 纯真 QQWry | 不支持 | **支持**（GBK 解码 + gzip） |
| 在线 API | 不支持 | **支持**（ip-api / 腾讯 / 百度 / 高德 四格式，`zpk online`） |
| 下载授权 | Ed25519 自动注册 + 票据 | **支持**（Ed25519 自动注册 + 票据；目录签名强制验签：配置公钥或注册时 TOFU） |
| 请求超时 | 60 s | **支持**（`HttpTimeoutMs` 默认 120 s；原生 `io.concurrent` + `Future.cancel`，非自造看门狗） |
| DB-IP CSV 转换 | 无 | **支持**（`zpk csv2db` → 纯真格式，GBK 码表由 `tools/gen_gbk_table.ps1` 生成） |

## 文档

- 接续与决策：`docs/项目接续指南.md`、`docs/决策记录.md`
- 一键回归：`tools/regression.ps1`（构建 → 单测 → CLI 自检 → 真实数据）
- 升级链路端到端：`tools/verify-sync-e2e.ps1`（起本地假平台，验证「平台发新版 → 下载 → 安装 → 旧版清理 → 查询用上新数据」；
  需要 `python` 与一个本地端口，故不进一键回归）
