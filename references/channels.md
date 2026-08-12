# 通道配置表

这个文件记录 ds-vision-skill 当前支持的视觉、OCR、文档解析和本地通道。更新模型 ID、注册入口或环境变量时，优先改这里；`SKILL.md` 只保留稳定的路由结论。

## 云端视觉通道

| 通道 | 类别 | Base URL | 默认模型 | 环境变量 | 备注 |
|---|---|---|---|---|---|
| `glm` | 简单视觉理解 | `https://open.bigmodel.cn/api/paas/v4/chat/completions` | `glm-4v-flash` | `GLM_API_KEY` | 快路径，可用 `GLM_BASE_URL` 覆盖 |
| `glm-thinking` | 复杂视觉推理 | `https://open.bigmodel.cn/api/paas/v4/chat/completions` | `glm-4.1v-thinking-flash` | `GLM_API_KEY` | 图表、数学、复杂 UI，可用 `GLM_BASE_URL` 覆盖 |
| `agnes-2.5-flash` | 快速视觉理解 | `https://api.agnes-ai.cn/v1/chat/completions` | `agnes-2.5-flash` | `AGNES_API_KEY` | OpenAI 兼容接口，可用 `AGNES_BASE_URL` 覆盖 |
| `agnes-2.0-flash` | 备用快速视觉理解 | `https://api.agnes-ai.cn/v1/chat/completions` | `agnes-2.0-flash` | `AGNES_API_KEY` | OpenAI 兼容接口，可用 `AGNES_BASE_URL` 覆盖 |
| `custom-1` | 第三方视觉模型槽 1 | `VISION_CUSTOM_1_BASE_URL` | `VISION_CUSTOM_1_MODEL` | `VISION_CUSTOM_1_API_KEY` | OpenAI 兼容接口 |
| `custom-2` | 第三方视觉模型槽 2 | `VISION_CUSTOM_2_BASE_URL` | `VISION_CUSTOM_2_MODEL` | `VISION_CUSTOM_2_API_KEY` | OpenAI 兼容接口 |
| `custom-3` | 第三方视觉模型槽 3 | `VISION_CUSTOM_3_BASE_URL` | `VISION_CUSTOM_3_MODEL` | `VISION_CUSTOM_3_API_KEY` | OpenAI 兼容接口 |

## OCR 通道

| 通道 | 端点/运行时 | 参数 | 环境变量 | 备注 |
|---|---|---|---|---|
| `baidu-ocr` | 百度 OCR `general_basic` / `accurate_basic` | `language_type=CHN_ENG` | `BAIDU_API_KEY` + `BAIDU_SECRET_KEY` | access token 会缓存 |
| `windows-ocr` | Windows WinRT OCR | 离线 | 无 | 隐私优先、本地兜底 |
| `mineru` | `mineru-open-api flash-extract` / `extract` | Markdown 输出 | `MINERU_TOKEN` 可选 | PDF/文档优先 |

## 本地通道

| 运行时 | 默认端口 | 说明 |
|---|---:|---|
| Ollama | `11434` | 推荐本地运行时 |
| LM Studio | `1234` | OpenAI 兼容服务 |
| llama.cpp | `8080` | `llama-server` 兼容服务 |

本地选型：

```powershell
scripts\local-select.ps1 -Force
```

建议模型：

- VRAM >= 8GB：`qwen2.5-vl:7b`、`llama3.2-vision:11b`、`qwen2.5-vl:3b`
- VRAM >= 4GB：`qwen2.5-vl:3b`、`minicpm-v`、`moondream`
- 无 GPU：`moondream`、`smolvlm`

## 配置命令

这些命令可以在 PowerShell 或默认 `cmd.exe` 的 harness 中运行。`cmd.exe` 会把 `<KEY>` 当成重定向符号，因此可复制示例使用带引号的占位值。

```cmd
scripts\setup.cmd -Status
scripts\setup.cmd -Help
scripts\setup.cmd -SetKey -Channel glm -Key "YOUR_GLM_API_KEY" -Verify
scripts\setup.cmd -SetKey -Channel agnes-2.5-flash -Key "YOUR_AGNES_API_KEY" -Verify
scripts\setup.cmd -SetKey -Channel baidu-ocr -Key "YOUR_BAIDU_API_KEY" -Secret "YOUR_BAIDU_SECRET_KEY" -Verify
scripts\setup.cmd -SetCustom -Slot 1 -BaseUrl "https://example.com/v1/chat/completions" -Key "YOUR_API_KEY" -Model "YOUR_MODEL" -Verify
scripts\setup.cmd -SetCustom -Slot 2 -BaseUrl "https://example.com/v1/chat/completions" -Key "YOUR_API_KEY" -Model "YOUR_MODEL" -Verify
scripts\setup.cmd -SetCustom -Slot 3 -BaseUrl "https://example.com/v1/chat/completions" -Key "YOUR_API_KEY" -Model "YOUR_MODEL" -Verify
scripts\setup.cmd -RemoveKey -Channel glm
```

## 验证标准

每个云端视觉通道可用一张小测试图验证：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\vlm-vision.ps1 -ImagePath "test.png" -Prompt "describe this image in one sentence" -Channel glm
```

常见退出码：

| 退出码 | 含义 |
|---:|---|
| `0` | 成功 |
| `1` | 本地输入或通用错误 |
| `2` | 缺 key 或认证失败 |
| `3` | 限流 |
| `4` | 网络或服务端错误 |
| `5` | 请求被拒、模型 ID 无效或参数错误 |

## 路由优先级

- `auto` 模式下，图片默认进入视觉理解免费竞速池；需要纯 OCR 时显式使用 `-Intent ocr`，或使用 `-AccurateOcr`。
- 图片理解：`race(agnes-2.5-flash, agnes-2.0-flash, glm, glm-thinking) -> custom-1 -> custom-2 -> custom-3 -> local`
- 复杂视觉推理：`race(agnes-2.5-flash, agnes-2.0-flash, glm, glm-thinking) -> custom-1 -> custom-2 -> custom-3 -> local`
- 文档解析：`mineru flash -> mineru extract`
- OCR：`baidu-ocr -> windows-ocr -> vision reasoning`
