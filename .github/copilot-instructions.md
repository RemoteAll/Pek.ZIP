# Pek.ZIP · 项目指令

> 全项目通用规则见用户级《跨项目接续协议》（本机 `%APPDATA%\Code\User\prompts\跨项目接续协议.instructions.md`；模板在 `tools/continuity/templates/`）。
> **开工先读（存在则读，按序）**：`.github/copilot-instructions.md` → `docs/项目接续指南.md` → `docs/用户档案.md` → `docs/项目记忆.md` → `docs/决策记录.md` 最新节。

## 项目速览

- **定位**：Pek 生态 IP 归属地库的 **Zig** 实现；对标 Rust `Pek.IP`（xdb v3 + MMDB + 合并 + 按需下载）与 C# `DH.NIP`（纯真 `ip.gz` + 在线 API + CSV 转换）。
- **技术栈**：Zig **0.17.1**（本机实测；`build.zig.zon` 最低 0.17.0，补丁版本兼容），**零第三方依赖**（`std.Io` / `File.createMemoryMap` / `compress.flate` / `zip` / `json` / `http` / `crypto`）。
- **产物**：库模块 `pek_zip`（`src/root.zig`）+ CLI `zpk`（`src/main.zig`）+ 基准 `zpk-bench`（`bench/`）。

## 关键约定（改动前必读）

- **零分配是硬口径**：`XdbReader.lookup` / `MmdbReader.lookupWorld|lookupAsn` / `Locator.lookup` 一律返回**借用切片**，不 new String；只有 QQWry 的 GBK→UTF-8 写入调用方 `Scratch`。新增字段若需要拼串，先想能不能借用或写进 scratch。
- **数据视图只走 `Blob`**（`src/blob.zig`）：mmap / 堆 / 借用三种来源 + 生命周期只实现一次；**禁止**第三个模块自己 `readToEndAlloc` 或自己管 `MemoryMap`。
- **格式细节不许猜**：xdb v3 布局、MMDB 指针解析（`data_offset = record - node_count - 16`，数据段内 pointer 相对 data section 起点）、QQWry 的 `0x01/0x02` 重定向，全部有源码/真实数据依据；改动必须用真实文件回归（`G:\Code\Rust\Pek.IP\data`、`G:\Code\Pek.FrameWork\DH.NIP\ip.gz`）。
- **GBK 码表是生成物**：`src/gb2312.bin` 由 `tools/gen_gbk_table.ps1`（.NET CP936）生成，24066×u16；**不要手改二进制**，改生成脚本后重跑。
- **启动异步的分层**：`Manager.start` 只做本地 mmap（毫秒级），网络动作全部在后台线程；热路径 `acquire/release` 不加锁；被替换的旧定位器进「退休列表」，**运行期不销毁**（避免读者 use-after-free），`destroy()` 时统一回收。
- **危险默认值**：
  - 配了 `PubKey` 但验签未实现 → **拒绝下载**（不静默放行），并在 `lastError()` 里说明；
  - `StoreUrl` 为空 = 仅本地缓存模式（离线/内网部署）；
  - `DownloadV6 = false`（37 MiB 默认不拉）。
- **错误日志三要素**：做什么 + 为什么 + 上下文（URL/状态码/响应片段/路径），见 `manager.setError` 的既有文案；不要写"操作失败"这类无信息量的话。
- 中文 `.ps1` 必须 **UTF-8 with BOM**；PS 5.1 调外部命令后判 `$LASTEXITCODE`，并在外部命令期间临时 `$ErrorActionPreference='Continue'`。

## 构建与验证

```powershell
zig build                      # 出 CLI：zig-out\bin\zpk.exe
zig build test                 # 48 项单测（xdb/mmdb/qqwry/合并/目录/安装/管理器）
zig test src/root.zig          # 直接跑测试，可看 "All 48 tests passed"
zig build bench -- 'G:/Code/Rust/Pek.IP/data' 200000   # 性能（库模块也 ReleaseFast）
zpk selfcheck --base .         # 配置 + 数据集状态 + 样例查询
powershell -NoProfile -ExecutionPolicy Bypass -File tools\regression.ps1
```

回归门槛（写死在 `tools/regression.ps1`）：测试数 ≥ **48** 且 0 失败；自检三项（合成国内/国外/内网）必须 PASS；真实数据存在时必须 PASS（缺失显式 SKIP）。

## 每轮收尾（务必）

① `docs/决策记录.md` 新增一节（**含用户原话**）；② 运行 `tools/continuity/sync-memory.ps1`（项目根目录或 `-ProjectPath`）把 `docs/项目记忆.md` 与本机 repo 记忆对齐；③ 跑 `tools/regression.ps1` 并如实汇报（贴 PASS/FAIL 行，不写"已通过"了事）。
