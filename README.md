# DS 视觉桥（ds-vision-skill）

给纯文本推理模型（DeepSeek 等）加"眼睛"的多通道视觉增强 Skill。它不替代主模型，而是负责**视觉任务识别、工具选择、结果整理**：把图片、截图、PDF、扫描件转成文本/标准化 JSON 后，交给 DeepSeek 推理。

## 功能特性

- **三层视觉能力**：视觉理解（GLM-4V-Flash 简单任务 / GLM-4.1V-Thinking-Flash 复杂推理）、文档解析（MinerU）、OCR（百度 OCR 优先，Windows 本地 OCR 兜底）
- **自动路由**：按任务类型（图片理解 / 文档解析 / 纯文字提取）选择工具；无法判断时默认走复杂推理模型
- **标准化输出**：所有工具结果统一为 `{task_type, tool_used, confidence, result, metadata}` JSON
- **降级链**：GLM 失败 → 切 Thinking/中转/本地 → OCR 兜底；MinerU 失败 → OCR；OCR 质量低 → GLM 复看
- **成本优化**：简单任务只用免费 GLM-4V-Flash；长文档走 MinerU；结果按"图片哈希 + prompt + 模型"缓存，命中直接复用
- **配置引导**：`setup.ps1` 一条命令完成通道注册、key 保存（用户级环境变量）、验证与移除
- **本地模型选型**：内置 llmfit 检测本机硬件（RAM/CPU/GPU），自动推荐可跑的视觉模型

## 目录结构

```
SKILL.md                  # 技能定义（触发描述、路由规则、输出规范、降级与成本策略）
agents/openai.yaml        # UI 元数据
references/channels.md    # 通道表：模型 ID、base URL、环境变量、注册入口
scripts/
  vlm-vision.ps1          # 通用视觉理解/推理（glm / glm-thinking / custom / local）
  baidu-ocr.ps1           # 百度 OCR（标准 / 高精度）
  windows-ocr.ps1         # Windows 离线 OCR
  mineru-extract.ps1      # MinerU 文档解析封装（Markdown 输出）
  preflight.ps1           # 通道可用性检查（只读）
  setup.ps1               # 配置引导（Status/Help/SetKey/RemoveKey/SetCustom/Verify）
  local-select.ps1        # llmfit 本地视觉模型选型
```

## 安装

```powershell
Copy-Item -Path ".\ds-vision-skill" -Destination "$env:USERPROFILE\.codex\skills\ds-vision-skill" -Recurse
```

安装后即可直接使用：向 Codex/DeepSeek 发一张图片或一个 PDF，问"看看这张图"、"识别图中文字"、"解析这个文档"即可自动路由。

## 快速开始

```powershell
# 1. 查看可用通道
scripts\setup.ps1 -Status

# 2. 简单识图（GLM-4V-Flash，免费）
scripts\vlm-vision.ps1 -ImagePath <图片路径> -Prompt "用中文描述这张图片" -Channel glm -Json

# 3. 复杂推理（图表、数学题、密集截图）
scripts\vlm-vision.ps1 -ImagePath <图片路径> -Prompt "分析这张图表的数据趋势" -Channel glm-thinking -Json

# 4. 纯文字提取（百度 OCR → Windows 离线 OCR 兜底）
scripts\baidu-ocr.ps1 -ImagePath <图片路径> -Json
scripts\windows-ocr.ps1 -ImagePath <图片路径> -Json

# 5. 文档/PDF 解析（MinerU → Markdown）
scripts\mineru-extract.ps1 -FilePath <文档路径> -Json
```

## 通道列表

| 通道 | 用途 | 环境变量 | 费用 |
|---|---|---|---|
| glm | 简单视觉理解（GLM-4V-Flash） | GLM_API_KEY | 免费 |
| glm-thinking | 复杂视觉推理（GLM-4.1V-Thinking-Flash） | GLM_API_KEY | 免费 |
| custom | 自定义 OpenAI 兼容中转 | VISION_CUSTOM_BASE_URL / API_KEY / MODEL | 视服务商 |
| baidu-ocr | 图片文字识别（标准/高精度） | BAIDU_API_KEY + BAIDU_SECRET_KEY | 免费额度 |
| windows-ocr | 离线文字提取（WinRT OCR） | 无 | 系统自带 |
| mineru | PDF/论文/表格/公式 → Markdown | MINERU_TOKEN（仅 extract 模式） | flash 免 token |
| local | 本地视觉模型（llmfit 选型） | VISION_LOCAL_MODEL | 离线免费 |

## 配置引导

```powershell
scripts\setup.ps1 -Help                                        # 查看注册入口与命令
scripts\setup.ps1 -SetKey -Channel glm -Key <key> -Verify      # 配置 GLM（默认先验证后保存）
scripts\setup.ps1 -SetKey -Channel baidu-ocr -Key <ak> -Secret <sk> -Verify
scripts\setup.ps1 -SetCustom -BaseUrl <url> -Key <key> -Model <model> -Verify
scripts\setup.ps1 -RemoveKey -Channel <name>                   # 移除配置
```

配置写入用户级环境变量（注册表），立即生效；脚本输出只显示 key 掩码，不打印明文。

## 输出规范

所有视觉工具结果统一为：

```json
{
  "task_type": "image_reasoning | document_parsing | ocr",
  "tool_used": "实际调用的模型或工具",
  "confidence": "high | medium | low",
  "result": "视觉分析内容",
  "metadata": { "额外信息" }
}
```

## 许可证

MIT
