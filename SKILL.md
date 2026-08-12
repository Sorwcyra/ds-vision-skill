---
name: ds-vision-skill
metadata:
  version: 0.5.1
  repository: https://github.com/Sorwcyra/ds-vision-skill
description: >
  为纯文本推理模型补充视觉能力。用户提供图片、截图、照片、图表、UI 截图、代码截图、数学题图片、
  扫描件、PDF 或文档，并要求描述、理解、推理、阅读、OCR、提取文字、解析图表或分析内容时使用。
  默认调用 scripts/vision-router.ps1 做自动路由：图片理解先走免费竞速池 GLM/Agnes，再走 custom-1/custom-2/custom-3/local，文档解析走 MinerU，
  纯文字识别走 Baidu OCR 或 Windows OCR。所有工具输出标准 JSON，再交给主模型推理和总结。
---

# DS Vision Skill

这个 skill 负责把视觉输入转换成文本或结构化 JSON。它不替代主模型，只负责识别任务、选择工具、执行视觉/OCR/文档解析，并把结果交给主模型继续推理。

## 首选入口

优先使用统一路由脚本：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/vision-router.ps1 -Path "path/to/file.png" -Prompt "user request" -Intent auto -Json
```

如果 harness 默认使用 `cmd.exe`（例如 Zcode 或某些 Codex/Hermes 包装器），优先调用 `scripts/setup.cmd` 和 `scripts/vision-router.cmd`。不要把 PowerShell 专用语法或 `<KEY>` 占位符粘到 `cmd.exe` 中；`cmd.exe` 会把尖括号当成重定向符号，配置 key 时请使用 `"YOUR_KEY"` 这样的引号占位或真实引号值。

常用参数：

- `-Intent auto|reason|ocr|document`：默认 `auto`。图片默认走视觉理解免费竞速池；纯 OCR 请显式使用 `-Intent ocr`。
- `-Complex`：图表、数学、复杂 UI、代码截图、多步骤视觉推理时启用。
- `-AccurateOcr`：票据、扫描件、低清晰度文字识别时启用百度高精度 OCR。
- `-MaxTokens`：限制视觉模型输出长度，默认 `1024`；`-Complex` 未显式设置时使用 `2048`。
- `-TimeoutSec`：整场视觉竞速的最长等待时间，默认 `90` 秒。
- `-NoCache`：跳过缓存读取，也不写入本次结果。

只有在需要调试单个通道时，才直接调用底层脚本。

## 路由规则

1. PDF、论文、报告、长文档、多页扫描件：使用 `scripts/mineru-extract.ps1 -FilePath <file> -Mode flash -Json`。如果配置了 `MINERU_TOKEN` 且 flash 失败，再尝试 `-Mode extract`。
2. 图片且需要理解/推理：使用 `scripts/vision-router.ps1`，让 `agnes-2.5-flash`、`agnes-2.0-flash`、`glm`、`glm-thinking` 四个模型同时开始竞速；谁先成功返回就采用谁的结果。如果全部失败，再降级到 `custom-1`、`custom-2`、`custom-3` 和 `local`。
3. 图片默认进入视觉理解免费竞速池；需要纯文字识别时显式使用 `-Intent ocr`，优先 `scripts/baidu-ocr.ps1 -ImagePath <file> -Json`；未配置或失败时用 `scripts/windows-ocr.ps1 -ImagePath <file> -Json`。
4. 无法判断时：使用 `vision-router.ps1 -Intent auto -Complex -Json`。

## 降级链

- 视觉理解：`race(agnes-2.5-flash, agnes-2.0-flash, glm, glm-thinking) -> custom-1 -> custom-2 -> custom-3 -> local`。
- 文档解析：`mineru flash -> mineru extract`。
- OCR：`baidu-ocr -> windows-ocr -> vision reasoning`。
- 同一通道遇到 401、403、429、网络错误或空结果时，不要反复重试；直接切换下一通道。

## 输出规范

所有脚本在 `-Json` 模式下输出：

```json
{
  "task_type": "image_reasoning | document_parsing | ocr",
  "tool_used": "actual tool or model",
  "confidence": "high | medium | low",
  "result": "recognized or parsed content",
  "metadata": {}
}
```

主模型继续推理时，优先使用 `result` 字段。向用户报告时可简要说明 `tool_used` 和必要的降级过程。

## 预检

只在首次配置、诊断问题或所有通道失败时运行；正常执行不要在每次分析前运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/preflight.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/preflight.ps1 -Json
```

`-Json` 用于自动化读取通道、工具和本地运行时状态。

## 隐私

云端通道会把文件内容发送给对应服务商。用户明确关注隐私、合同、证件、医疗、财务等敏感内容时，优先使用 Windows OCR、本地模型或先征求确认。

## 维护约定

- PowerShell 脚本源码保持 ASCII-only，中文通过参数传入。
- 面向用户的 Markdown 文档使用 UTF-8。
- 面向 harness 或新用户的可复制 Windows 命令必须显式选择 shell：配置用 `scripts/setup.cmd`，路由用 `scripts/vision-router.cmd`，或完整写出 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...`。不要在 cmd 示例中使用 `<KEY>` 形式的占位符。
- 新增通道时优先接入 `vision-router.ps1`，再补充 README 和 `references/channels.md`。
- 评估性能或发布版本时先阅读[跨版本基准方法与数据](references/benchmarks.md)，并用 [`scripts/benchmark-race.ps1`](scripts/benchmark-race.ps1) 复现；不要仅凭单次 Live 请求下结论。
