---
name: ds-vision-skill
description: >
  为纯文本推理模型补充视觉能力。用户提供图片、截图、照片、图表、UI 截图、代码截图、数学题图片、
  扫描件、PDF 或文档，并要求描述、理解、推理、阅读、OCR、提取文字、解析图表或分析内容时使用。
  默认调用 scripts/vision-router.ps1 做自动路由：图片理解走 GLM/custom/local，文档解析走 MinerU，
  纯文字识别走 Baidu OCR 或 Windows OCR。所有工具输出标准 JSON，再交给主模型推理和总结。
---

# DS Vision Skill

这个 skill 负责把视觉输入转换成文本或结构化 JSON。它不替代主模型，只负责识别任务、选择工具、执行视觉/OCR/文档解析，并把结果交给主模型继续推理。

## 首选入口

优先使用统一路由脚本：

```powershell
scripts/vision-router.ps1 -Path <file> -Prompt "<user request>" -Intent auto -Json
```

常用参数：

- `-Intent auto|reason|ocr|document`：默认 `auto`，按文件类型和 prompt 自动判断。
- `-Complex`：图表、数学、复杂 UI、代码截图、多步骤视觉推理时启用。
- `-AccurateOcr`：票据、扫描件、低清晰度文字识别时启用百度高精度 OCR。
- `-NoCache`：强制重新调用视觉模型。

只有在需要调试单个通道时，才直接调用底层脚本。

## 路由规则

1. PDF、论文、报告、长文档、多页扫描件：使用 `scripts/mineru-extract.ps1 -FilePath <file> -Mode flash -Json`。如果配置了 `MINERU_TOKEN` 且 flash 失败，再尝试 `-Mode extract`。
2. 图片且需要理解/推理：使用 `scripts/vlm-vision.ps1`。简单任务走 `glm`，复杂图表、数学、UI/代码截图、密集信息图走 `glm-thinking`。
3. 图片且只要文字：优先 `scripts/baidu-ocr.ps1 -ImagePath <file> -Json`；未配置或失败时用 `scripts/windows-ocr.ps1 -ImagePath <file> -Json`。
4. 无法判断时：使用 `vision-router.ps1 -Intent auto -Complex -Json`。

## 降级链

- 视觉理解：`glm -> glm-thinking -> custom -> local`。
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

执行前可运行：

```powershell
scripts/preflight.ps1
scripts/preflight.ps1 -Json
```

`-Json` 用于自动化读取通道、工具和本地运行时状态。

## 隐私

云端通道会把文件内容发送给对应服务商。用户明确关注隐私、合同、证件、医疗、财务等敏感内容时，优先使用 Windows OCR、本地模型或先征求确认。

## 维护约定

- PowerShell 脚本源码保持 ASCII-only，中文通过参数传入。
- 面向用户的 Markdown 文档使用 UTF-8。
- 新增通道时优先接入 `vision-router.ps1`，再补充 README 和 `references/channels.md`。
