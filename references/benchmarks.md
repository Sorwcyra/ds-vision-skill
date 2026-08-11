# 跨版本速度基准

本文记录 `ds-vision-skill` 从 0.4.1 到 0.5.0 的竞速实现变化、可复现测试方法和结果边界。这里测量的是视觉路由与四模型竞速的运行速度，不评价模型回答质量。

## 对比版本

| 版本 | 发布提交 | 四模型竞速实现 | 主要变化 |
|---|---|---|---|
| 0.4.1 | [`ba795e63f16e6d8f2d2e107661c62a9e8775f6af`](https://github.com/Sorwcyra/ds-vision-skill/commit/ba795e63f16e6d8f2d2e107661c62a9e8775f6af) | 每个通道启动一个 `powershell.exe` 子进程；主循环每 100 ms 轮询一次 | 建立 Agnes 2.5、Agnes 2.0、GLM 和 GLM-thinking 的 first-success 竞速 |
| 0.4.2 | [`096ce662b3114d37e3eb11c2f2714e230f4f5cc6`](https://github.com/Sorwcyra/ds-vision-skill/commit/096ce662b3114d37e3eb11c2f2714e230f4f5cc6) | 进程内 PowerShell runspace；主循环每 50 ms 轮询一次 | 消除四个子进程的启动成本，图片只准备一次并由 worker 共享 |
| 0.5.0 | [`d48ab934026aa3da6a1be085008b61880df7b48c`](https://github.com/Sorwcyra/ds-vision-skill/commit/d48ab934026aa3da6a1be085008b61880df7b48c) | 共享 `HttpClient`、异步请求与 `Task.WaitAny`；不再轮询 | 四路请求紧密启动，首个有效结果胜出并取消其余请求，同时减少重复序列化 |

对应发布标签为 [`v0.4.1`](https://github.com/Sorwcyra/ds-vision-skill/tree/v0.4.1)、[`v0.4.2`](https://github.com/Sorwcyra/ds-vision-skill/tree/v0.4.2) 和 [`v0.5.0`](https://github.com/Sorwcyra/ds-vision-skill/tree/v0.5.0)，可直接检出历史快照复现。

三个版本都以四个模型同时竞速为目标；0.5.0 没有通过减少模型数量获得速度提升。

## 测试分层

基准必须把可控 Mock 和真实 API 分开报告。两者回答的问题不同，结果不得合并成一个统计量。

### 可控 Mock

Mock 测试用于比较框架开销。四个本地 OpenAI-compatible 端点返回固定、有效且简短的 JSON，并为每个模型施加固定延迟。它不需要真实 API Key；测试脚本仅设置无权限的占位值以激活四个通道。

每个版本按原发布代码（as shipped）运行。测试程序从上述提交分别导出完整临时快照，不切换或修改当前工作树。所有快照必须使用同一份外部 fixture、同一提示词、相同 Mock 延迟和相同 PowerShell 版本。

0.4.1 和 0.4.2 已支持 `AGNES_BASE_URL`，但 GLM 地址写死为生产端点。为了让旧版四路请求全部进入本地 Mock，测试程序只在临时快照中把固定的 GLM endpoint 替换成本地测试 endpoint。这个 test-only endpoint injection 不改变竞速、轮询、缓存、序列化或错误处理逻辑；临时快照在测试结束后删除，仓库中的历史提交不被改写。0.5.0 直接使用 `GLM_BASE_URL` 和 `AGNES_BASE_URL`。

Mock 报告必须注明：

- 操作系统、CPU、内存和 PowerShell 完整版本。
- fixture 的文件名、字节数和 SHA-256；三个版本必须读取完全相同的文件。
- 提示词、warm-up 次数、计入统计的轮数和版本运行顺序。
- 四个模型各自的固定服务端延迟。
- 临时快照的提交哈希，以及旧版 GLM endpoint 注入是否成功。

不得让各历史快照使用各自版本的 `assets/star-history.png`，因为该图片在历史提交之间发生过变化。基准脚本的默认 fixture 是从固定的 0.5.0 发布快照 `d48ab934026aa3da6a1be085008b61880df7b48c` 中导出的 `star-history.png`，并校验固定 SHA-256；它不是当前工作树里可能继续变化的 asset。三个版本通过同一绝对路径读取这一个临时文件。只有显式传入 `-ImagePath` 时才改用操作者提供的 fixture。

### 真实 API

Live 测试用于观察真实网络和提供商延迟下的用户体验。完整四模型测试同时需要：

- `AGNES_API_KEY`：启用 `agnes-2.5-flash` 和 `agnes-2.0-flash`。
- `GLM_API_KEY`：启用 `glm` 和 `glm-thinking`。

基准程序只检查环境变量是否存在，绝不读取到结果、日志或文档中，也绝不提交、回显或记录任何 Key。缺少其中一把 Key 时，只能把测试标为不完整通道测试，不能称为“四模型 Live 基准”。Baidu OCR 和 MinerU Key 与本基准无关。

Live 数据必须单独注明测试日期、时区、网络位置、fixture、提示词、轮数、赢家分布和失败次数。提供商负载、限流、网络路径与模型端生成时间都会变化，因此 Live 结果不能单独证明框架优化幅度。

## 缓存与发布行为

所有性能轮次都应避免缓存命中。每轮使用唯一 prompt nonce，并把 `USERPROFILE` 指向隔离的临时目录，以免读取或污染用户的真实缓存。

`-NoCache` 的发布语义并不完全一致：

- 0.4.1 和 0.4.2 会跳过缓存读取，但成功 worker 仍可能写入缓存。
- 0.5.0 同时跳过缓存读取和写入。

因此，end-to-end 墙钟时间应保留各发布版的原始行为，这也是用户实际承担的成本；HTTP 赢家延迟则在缓存写入前停止计时，用于更集中地观察请求与解析热路径。报告不得通过修改旧版缓存代码来“校正”结果。

## 指标定义

| 指标 | 定义 | 用途 |
|---|---|---|
| End-to-end wall time | 从启动独立 PowerShell 命令到进程退出并获得有效 JSON 的墙钟时间 | 用户实际等待时间，包含 PowerShell 启动、脚本解析、图片准备、竞速和发布版缓存行为 |
| Winner request latency | 获胜 worker 的 `metadata.latency_ms`；从该 worker 发起 HTTP 请求到收到并解析有效响应 | 比较竞速 HTTP/解析热路径；不等同于完整命令耗时 |
| Request arrival spread | Mock 服务端收到四路请求时，最后一条与第一条的到达时间差 | 验证四路启动是否紧密，单位为毫秒 |
| Received channel count | Mock 每轮实际收到的不同模型请求数量 | 验证是否确实启动四路；完整轮次应为 4 |
| Success rate | 返回有效 JSON 的轮次占比 | 排除“更快但失败”的错误优化 |

每项耗时至少报告样本数、p50、p90、p95、平均值和标准差，并保留逐轮原始值。三版本应采用固定随机种子或平衡轮换顺序交错执行，避免把热机、后台负载或网络漂移误认为版本差异。warm-up 数据不计入正式统计。

## 结果

### 可控四模型 Mock

本批数据生成于 `2026-08-11T01:34:26.9581667Z`，基准状态为有效。环境为 Microsoft Windows 11 专业版 `10.0.26200`（build `26200`）、AMD64 Family 25 Model 80 Stepping 0（AuthenticAMD）、12 个逻辑处理器、16,483,667,968 bytes 内存、Windows PowerShell `5.1.26100.8875`、Git `2.52.0.windows.1`、Python `3.12.13`，时区为 China Standard Time。

每个版本先 warm-up 2 轮，再计入 24 轮；每个样本启动新的 `powershell.exe`，三个版本按六种固定平衡排列循环执行。默认 fixture 来自上述固定 0.5.0 快照，尺寸为 1960 x 1307、73,894 bytes，SHA-256 为 `1556668875623ec5d7aa6faef537f8c85311eaa42d79c9d677a44fa9f51449c6`。Mock 使用 IPv4 loopback HTTP/1.1，固定延迟为：`glm-4v-flash` 100 ms、`agnes-2.5-flash` 250 ms、`agnes-2.0-flash` 400 ms、`glm-4.1v-thinking-flash` 550 ms。

End-to-end 墙钟时间（ms，nearest-rank 百分位）：

| 版本 | 有效样本 | 严格成功率 | p50 | p90 | p95 | 平均值 | 标准差 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 0.4.1 | 24/24 | 100% | 3250.604 | 3429.866 | 3466.575 | 3274.614 | 78.708 |
| 0.4.2 | 24/24 | 100% | 1858.165 | 1946.013 | 1948.726 | 1881.815 | 59.350 |
| 0.5.0 | 24/24 | 100% | 1793.656 | 1855.022 | 1859.934 | 1807.855 | 29.205 |

赢家请求延迟（ms；只作诊断，因为各版本计时边界并非完全相同）：

| 版本 | p50 | p90 | p95 | 平均值 | 标准差 |
|---|---:|---:|---:|---:|---:|
| 0.4.1 | 301 | 348 | 451 | 316.917 | 44.199 |
| 0.4.2 | 282 | 309 | 358 | 290.000 | 22.543 |
| 0.5.0 | 134 | 137 | 137 | 133.875 | 2.421 |

四路 fanout 与选择正确性：

| 版本 | 四路接收率 | 服务端 race p50 / p90 / p95 (ms) | 到达 spread p50 / p90 / p95 (ms) | 选择固定最快模型 | 选择 first-ready | 赢家分布 |
|---|---:|---:|---:|---:|---:|---|
| 0.4.1 | 100% | 169.896 / 188.647 / 201.089 | 91.021 / 117.310 / 122.471 | 91.67% | 91.67% | GLM 22；Agnes 2.5 2 |
| 0.4.2 | 100% | 103.269 / 104.176 / 104.364 | 3.130 / 3.660 / 3.683 | 91.67% | 91.67% | GLM 22；Agnes 2.5 2 |
| 0.5.0 | 100% | 102.835 / 104.552 / 105.213 | 3.188 / 4.032 / 4.204 | 100% | 100% | GLM 24 |

版本比较以“耗时减少”为正值：0.4.1 -> 0.4.2 的墙钟 p50/p95 分别减少 42.84%/43.79%；0.4.2 -> 0.5.0 分别减少 3.47%/4.56%；0.4.1 -> 0.5.0 分别减少 44.82%/46.35%。0.4.2 -> 0.5.0 的服务端 race p50 只减少 0.42%，fanout spread p50 反而增加 1.85%；这说明本地 Mock 下 0.5.0 的主要收益不应被描述成提供商响应更快。

逐轮样本、快照校验值和完整统计见 [`../benchmarks/cross-version-mock-2026-08-11.json`](../benchmarks/cross-version-mock-2026-08-11.json)。

### 真实四模型 API

本批数据生成于 `2026-08-11T01:37:17.6431704Z`，基准状态为有效。机器、PowerShell、fixture 和提示词与 Mock 批次相同；每个版本 warm-up 1 轮，计入 6 轮，单样本进程超时为 180 秒。请求使用 Agnes 与 GLM 官方提供商端点，两把 Key 在运行时均存在，原始结果明确记录 `keys_recorded: false`。网络位置没有写入原始数据，因此不能据此推断其他地区或网络的表现。

End-to-end 墙钟时间（ms，nearest-rank 百分位）：

| 版本 | 有效样本 | 严格成功率 | 四通道启动率 | p50 | p90 | p95 | 平均值 | 标准差 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.4.1 | 6/6 | 100% | 100% | 5171.974 | 9547.502 | 9547.502 | 6108.990 | 1685.967 |
| 0.4.2 | 6/6 | 100% | 100% | 3989.412 | 10592.810 | 10592.810 | 5261.326 | 2522.591 |
| 0.5.0 | 6/6 | 100% | 100% | 4929.828 | 13279.189 | 13279.189 | 7236.589 | 3847.598 |

赢家请求延迟（ms；同样只作诊断）：

| 版本 | p50 | p90 | p95 | 平均值 | 标准差 | 赢家分布 |
|---|---:|---:|---:|---:|---:|---|
| 0.4.1 | 2252 | 6534 | 6534 | 3218.333 | 1637.794 | Agnes 2.0 2；Agnes 2.5 3；GLM 1 |
| 0.4.2 | 2398 | 8976 | 8976 | 3663.667 | 2513.924 | Agnes 2.0 4；Agnes 2.5 2 |
| 0.5.0 | 3254 | 11644 | 11644 | 5591.500 | 3855.006 | Agnes 2.0 4；Agnes 2.5 1；GLM-thinking 1 |

Live 模式无法像本地 Mock 一样观测服务端每个模型的 ready 时间，因此 fastest-model 与 first-ready 选择率均为不可用，而不是 0%。本批只有每版本 6 个正式样本，波动很大：0.4.1 -> 0.4.2 的墙钟 p50 减少 22.86%，但 p95 增加 10.95%；0.4.2 -> 0.5.0 的 p50 增加 23.57%、p95 增加 25.36%；0.4.1 -> 0.5.0 的 p50 减少 4.68%，但 p95 增加 39.09%。因此必须如实说明：在这 6 轮 Live 批次中，0.5.0 的 p50 并不优于 0.4.2，且尾延迟更高。该小样本现场结果不能推翻可控 Mock 的框架开销结论，也不能被包装成 0.5.0 的 Live 提速证明。

逐轮样本和完整统计见 [`../benchmarks/cross-version-live-2026-08-11.json`](../benchmarks/cross-version-live-2026-08-11.json)。

## 结果解读限制

- Mock 数字只反映本机、指定 PowerShell 和固定响应延迟下的框架成本，不代表提供商真实响应速度。
- Live 数字同时包含网络、服务商排队和模型生成时间，只能视为带日期的现场样本。
- `metadata.latency_ms` 在三个版本中都围绕单个 worker 请求计时，但实现载体不同；应与 end-to-end 数据一起阅读。
- p90 在样本较少时波动明显，报告必须同时展示样本数和原始数据。
- 首个有效响应获胜；HTTP 成功但 JSON 无效或结果为空的响应不会被视为成功。
- 基准只比较速度与竞速行为，不比较视觉理解准确率、输出完整度或服务成本。

## 复现原则

可复现脚本应默认运行本地 Mock，只有显式指定 Live 模式时才允许调用云端。它应验证版本提交、fixture SHA-256、四路接收数量和 JSON 成功率；任一校验失败时，结果必须标记为无效而不是静默纳入统计。所有临时文件和历史快照应位于隔离目录，测试完成后删除，且不触碰当前工作树和用户缓存。

基准驱动见 [`../scripts/benchmark-race.ps1`](../scripts/benchmark-race.ps1)。在仓库根目录复现本批 Mock：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\benchmark-race.ps1 `
  -Mode Mock -WarmupRuns 2 -RunsPerVersion 24 -ProcessTimeoutSec 60 `
  -OutputPath benchmarks\cross-version-mock-2026-08-11.json
```

Live 会把图片发送给四个官方云模型。先在环境中配置 `AGNES_API_KEY` 与 `GLM_API_KEY`，再显式运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\benchmark-race.ps1 `
  -Mode Live -WarmupRuns 1 -RunsPerVersion 6 -ProcessTimeoutSec 180 `
  -OutputPath benchmarks\cross-version-live-2026-08-11.json
```

复现时建议改用新的 `-OutputPath`，避免覆盖仓库中已经发布的原始数据。脚本不会把 Key 写入结果；如果两把 Key 任一缺失，Live 模式会直接拒绝运行。
