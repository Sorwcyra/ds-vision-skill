---
name: ds-vision-skill
description: >
  给纯文本模型（DeepSeek 等）加"眼睛"的多通道视觉路由。当用户发送、粘贴或引用图片、截图、照片、图表、架构图、UI 截图、代码截图、数学题图片、扫描件、PDF 或文档，并要求描述、理解、推理、阅读、提取文字、OCR、解析图表或分析内容时使用（例如"看看这张图"、"识别图中文字"、"解析这个图表"）。三层能力：视觉理解（GLM-4V-Flash 简单任务 / GLM-4.1V-Thinking-Flash 复杂推理）、文档解析（MinerU）、OCR（百度 OCR 优先，Windows OCR 本地兜底）。所有工具结果输出标准化 JSON。把像素转成文字后交给主模型（DeepSeek）推理。
---

# DS 视觉桥（Vision Enhancement Skill）

本技能是 DeepSeek 的视觉能力扩展模块：负责视觉任务识别、工具选择、结果整理，不直接替代 DeepSeek。所有视觉输入先转成文本/结构化 JSON，再交给 DeepSeek 推理。

## 角色与能力

| 层 | 工具 | 职责 |
|---|---|---|
| 视觉理解 | GLM-4V-Flash（简单）、GLM-4.1V-Thinking-Flash（复杂） | 图片理解、图像推理、图表/架构图分析、UI 截图、代码截图、数学题、复杂视觉推理 |
| 文档解析 | MinerU（flash / extract） | PDF/论文/报告解析、表格提取、公式识别、多栏排版恢复、Markdown 结构化输出 |
| OCR | 百度 OCR（优先）、Windows OCR（本地兜底，另可部署 PaddleOCR/Tesseract） | 图片文字提取、扫描件识别、表格文字、票据识别、低清图片文字恢复 |

## 路由决策

输入：用户上传图片、PDF、截图、扫描件等。按以下顺序判断：

1. **PDF / 论文 / 长文档 / 多页扫描** → 文档解析：`scripts/mineru-extract.ps1 -FilePath <file> [-Mode flash|extract] [-Json]`。不要用视觉模型处理超长文档；`extract` 模式需要 `MINERU_TOKEN`。
2. **图片 + 需要理解/推理**（描述、问答、图表、架构、UI、代码、数学题）→ 视觉理解：
   - 简单任务：`scripts/vlm-vision.ps1 -ImagePath <path> -Prompt "<问题>" -Channel glm [-Json]`
   - 复杂推理任务：`scripts/vlm-vision.ps1 -ImagePath <path> -Prompt "<问题>" -Channel glm-thinking [-Json]`
   - 复杂 vs 简单判断：多步骤推理、逻辑/数学、密集图表、截图细节、多元素交互 → glm-thinking；其余 → glm。
3. **图片 + 只要文字**（OCR、扫描件文字、票据、表格文字）→ OCR：`scripts/baidu-ocr.ps1 -ImagePath <path> [-Accurate] [-Json]`；无百度 key 或失败 → `scripts/windows-ocr.ps1 -ImagePath <path> [-Json]`（离线）→ 仍需要版式/表格时 → MinerU。
4. **无法判断** → 优先调用 `glm-thinking`（GLM-4.1V-Thinking-Flash）。

执行前可运行 `scripts/preflight.ps1` 确认可用通道；执行后必须按下方输出规范整理结果。

## 输出规范

所有视觉工具调用结果必须标准化为 JSON：

```json
{
  "task_type": "image_reasoning | document_parsing | ocr",
  "tool_used": "实际调用的模型或工具",
  "confidence": "high | medium | low",
  "result": "视觉分析内容",
  "metadata": { "额外信息" }
}
```

- `vlm-vision.ps1`、`windows-ocr.ps1`、`baidu-ocr.ps1`、`mineru-extract.ps1` 均支持 `-Json` 直接输出该结构；`-Json` 未指定时输出纯文本（快速预览用）。
- DeepSeek 推理时只使用 `result` 字段内容；向用户汇报时附带 `task_type` 与 `tool_used`。
- `confidence` 由工具默认给出；OCR 结果乱码、视觉模型回答可疑时，把置信度降级并在 metadata 说明。

## 降级链（异常处理）

- 视觉理解失败（401/429/网络/空响应）：glm → glm-thinking → custom → local；全失败 → 用 OCR 提取文字后交回 DeepSeek。
- MinerU 失败或无内容：降级 OCR（baidu-ocr → windows-ocr），把识别文本交回 DeepSeek。
- OCR 质量低（乱码/缺行/置信度 low）：调用 `glm-thinking` 重新理解原图。
- 同一通道失败不要反复重试；429/401/网络错误直接切下一通道。
- 全部失败：明确告诉用户失败原因，请其描述图片。

## 成本优化策略

- 简单任务只用 GLM-4V-Flash（免费、快）；复杂任务才用 GLM-4.1V-Thinking-Flash。
- 长文档优先 MinerU，不用视觉模型逐页喂图。
- 缓存默认开启：`vlm-vision.ps1` 按"图片哈希 + prompt + 通道 + 模型"缓存到 `%USERPROFILE%\.ds-vision\cache\`，命中直接复用；`-NoCache` 强制重跑。
- 同一图片同一问题不重复解析；优先复用本会话已得结果。
- OCR 优先百度免费额度；无网络/失败时才用本地 OCR。

## 脚本用法

- `scripts/preflight.ps1`：探测 key/工具/本地端口，输出"任务类型 → 可用通道"矩阵（只读，不联网）。
- `scripts/vlm-vision.ps1 -ImagePath <path> -Prompt "<问题>" -Channel <glm|glm-thinking|custom|local> [-Json] [-NoCache]`：视觉理解/推理。`-Model/-BaseUrl/-ApiKey` 可覆盖通道默认；`local` 自动探测 Ollama(11434)/LM Studio(1234)/llama.cpp(8080)。
- `scripts/baidu-ocr.ps1 -ImagePath <path> [-Accurate] [-Json]`：百度 OCR（标准/高精度），需要 `BAIDU_API_KEY`+`BAIDU_SECRET_KEY`。
- `scripts/windows-ocr.ps1 -ImagePath <path> [-Json]`：Windows 离线 OCR。
- `scripts/mineru-extract.ps1 -FilePath <file> [-Mode flash|extract] [-Json]`：MinerU 文档解析封装，输出 Markdown。
- `scripts/local-select.ps1 [-Force]`：llmfit 选本地视觉模型，结果缓存到 `%USERPROFILE%\.ds-vision\local-profile.json`。
- `scripts/setup.ps1 -Status / -Help / -SetKey / -RemoveKey / -SetCustom / -Verify`：配置引导。

约定：脚本源码 ASCII-only，中文通过参数传入；图片 >15MB 先缩放或用 MinerU；多张图片循环处理、汇总输出。

## 配置引导（安装后）

1. 运行 `scripts/setup.ps1 -Status` 展示各通道状态；需要注册链接时运行 `scripts/setup.ps1 -Help`。
2. 云端通道：glm / glm-thinking 共用 `GLM_API_KEY`（`setup.ps1 -SetKey -Channel glm -Key <key> -Verify`）；baidu-ocr 需要 `-Key` + `-Secret`（`setup.ps1 -SetKey -Channel baidu-ocr -Key <ak> -Secret <sk> -Verify`）。验证通过才保存；`-Force` 强制保存。
3. 自定义中转：`scripts/setup.ps1 -SetCustom -BaseUrl <url> -Key <key> -Model <model> [-Verify]`。
4. 本地通道：询问用户是否安装 Ollama（`winget install Ollama.Ollama` + `ollama pull qwen2.5-vl:3b`，安装前需用户确认）；完成后运行 `scripts/local-select.ps1 -Force`。
5. 配置立即生效（写入用户级环境变量）；移除用 `scripts/setup.ps1 -RemoveKey -Channel <name>`。
6. 配置完再跑一次 `scripts/setup.ps1 -Status` 汇报最终可用通道。

## 报告与隐私

- 每次识图报告 `task_type` + `tool_used` + 结果概要；多通道试过时简要说明降级过程。
- 云端通道会把图片发送到智谱/百度/你的中转服务商服务器；用户明确在意隐私时，优先 Windows OCR（不出网）或本地通道。
