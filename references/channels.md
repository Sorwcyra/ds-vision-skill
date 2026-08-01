# 通道配置表

> 修改通道、模型 ID、base URL、免费额度只改本文件，不改 SKILL.md 与脚本。SKILL.md 只引用本表的"类别 → 通道"结论。

## 云端通道

| 通道 | 类别 | Base URL（chat/completions） | 默认模型 | 环境变量 | 免费情况 |
|---|---|---|---|---|---|
| glm | 通用 | https://open.bigmodel.cn/api/paas/v4/chat/completions | glm-4v-flash | GLM_API_KEY | 永久免费（官方） |
| glm-thinking | 复杂推理 | https://open.bigmodel.cn/api/paas/v4/chat/completions | glm-4.1v-thinking-flash | GLM_API_KEY | 免费（官方） |
| custom | 中转/私有 | VISION_CUSTOM_BASE_URL | VISION_CUSTOM_MODEL | VISION_CUSTOM_API_KEY | 视服务商 |

## OCR 通道

| 通道 | 端点 | 参数 | 环境变量 | 免费情况 |
|---|---|---|---|---|
| baidu-ocr | https://aip.baidubce.com/rest/2.0/ocr/v1/general_basic（-Accurate 用 accurate_basic） | language_type=CHN_ENG | BAIDU_API_KEY + BAIDU_SECRET_KEY | 免费额度（以百度云控制台为准） |
| windows-ocr | 本地 WinRT OcrEngine | 离线 | 无 | 系统自带 |
| mineru | `mineru-open-api flash-extract` | 表格/版式 | MINERU_TOKEN（仅 extract） | flash 免 token |

## 注册与启用

| 通道 | 注册入口 | 环境变量 |
|---|---|---|
| glm | https://open.bigmodel.cn/ | GLM_API_KEY |
| glm-thinking | https://open.bigmodel.cn/（与 glm 同 key） | GLM_API_KEY |
| baidu-ocr | https://console.bce.baidu.com/ai/#/ai/ocr/app/list | BAIDU_API_KEY + BAIDU_SECRET_KEY |
| custom | 你的中转服务商 | VISION_CUSTOM_API_KEY / VISION_CUSTOM_BASE_URL / VISION_CUSTOM_MODEL |

启用命令（写入用户级环境变量，立即生效；默认先验证后保存，`-Force` 强制保存）：

```powershell
scripts\setup.ps1 -SetKey -Channel glm -Key <key> -Verify
scripts\setup.ps1 -SetKey -Channel baidu-ocr -Key <ak> -Secret <sk> -Verify
scripts\setup.ps1 -SetCustom -BaseUrl <url> -Key <key> -Model <model> -Verify
scripts\setup.ps1 -Status    # 查看配置状态
scripts\setup.ps1 -Help      # 查看注册指引
scripts\setup.ps1 -RemoveKey -Channel <name|custom>
```

## 本地通道

| 运行时 | 端口 | 说明 |
|---|---|---|
| Ollama | 11434 | 首选；`ollama pull qwen2.5-vl:3b` 后即可用 |
| LM Studio | 1234 | 启动本地服务（OpenAI 兼容） |
| llama.cpp | 8080 | `llama-server -m model.gguf --port 8080` |

选型：`scripts/local-select.ps1` 用 llmfit（`uv tool install llmfit` 或 `scoop install llmfit`）检测硬件并过滤视觉模型；llmfit 缺失或结果为空时按显存兜底：

- VRAM ≥ 8GB：qwen2.5-vl:7b / llama3.2-vision:11b / qwen2.5-vl:3b / minicpm-v / moondream
- VRAM ≥ 4GB：qwen2.5-vl:3b / minicpm-v / moondream / smolvlm
- 无 GPU：moondream / smolvlm（CPU 可跑，较慢）

选型结果缓存：`%USERPROFILE%\.ds-vision\local-profile.json`。

## 验证步骤

每个云端通道用一张小测试图执行：

```powershell
scripts\vlm-vision.ps1 -ImagePath <test.png> -Prompt "describe this image in one sentence" -Channel <name>
```

通过标准：返回内容且非 401/404/429。模型 ID 失效（404）时更新本表；401/403 说明 key 无效；429 说明限流（换通道）。

## 已知状态（2026-08-01 复核）

- GLM-4V-Flash：免费，本机已验证可用（`GLM_API_KEY` 已配置）。
- GLM-4.1V-Thinking-Flash（`glm-4.1v-thinking-flash`）：2026-08-01 实测可用，与 GLM-4V-Flash 共用 `GLM_API_KEY`。
- 百度 OCR：未配置（缺 `BAIDU_API_KEY`/`BAIDU_SECRET_KEY`）；注册见上表，配置后 `setup.ps1 -SetKey -Channel baidu-ocr -Key <ak> -Secret <sk> -Verify`。
- MinerU：`mineru-open-api` v0.5.9 已安装；flash-extract 无需 token（10MB/20 页），extract 需要 `MINERU_TOKEN`。
- AIDAWAN_API_KEY / API_KEY（ergouapi）：端点分别为 `https://www.aidawan.fun/v1` 与 `https://ergouapi.com/v1`；2026-08-01 实测两个 `/v1/models` 均返回 401，未验证通过；验证通过前走 custom 通道（设置 `VISION_CUSTOM_BASE_URL`/`VISION_CUSTOM_API_KEY`/`VISION_CUSTOM_MODEL`）。
- llmfit：本机已安装（`llmfit fit --json` 实测可用）；在 RTX 3050/4GB 上首选 `Qwen/Qwen2.5-VL-3B-Instruct-AWQ`，`deepseek-ai/DeepSeek-OCR-2` 也在候选中（纯 OCR 场景可考虑）。Ollama 部署用 `ollama pull qwen2.5-vl:3b`（对应 tag 由 local-select 输出 OLLAMA_TAG）。

## 错误码（vlm-vision.ps1）

| 退出码 | 含义 |
|---|---|
| 0 | 成功，stdout 为内容 |
| 1 | 通用失败（文件不存在、空响应等） |
| 2 | 缺 key / 认证失败 |
| 3 | 限流（429） |
| 4 | 网络/服务器错误 |
| 5 | 请求被拒（404/400，通常是模型 ID 失效） |
