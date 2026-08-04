# 通道配置表

这个文件记录 ds-vision-skill 当前支持的视觉、OCR、文档解析和本地通道。更新模型 ID、注册入口或环境变量时，优先改这里；`SKILL.md` 只保留稳定的路由结论。

## 云端视觉通道

| 通道 | 类别 | Base URL | 默认模型 | 环境变量 | 备注 |
|---|---|---|---|---|---|
| `glm` | 简单视觉理解 | `https://open.bigmodel.cn/api/paas/v4/chat/completions` | `glm-4v-flash` | `GLM_API_KEY` | 快路径 |
| `glm-thinking` | 复杂视觉推理 | `https://open.bigmodel.cn/api/paas/v4/chat/completions` | `glm-4.1v-thinking-flash` | `GLM_API_KEY` | 图表、数学、复杂 UI |
| `custom` | OpenAI 兼容中转 | `VISION_CUSTOM_BASE_URL` | `VISION_CUSTOM_MODEL` | `VISION_CUSTOM_API_KEY` | 私有或第三方服务 |

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

```powershell
scripts\setup.ps1 -Status
scripts\setup.ps1 -Help
scripts\setup.ps1 -SetKey -Channel glm -Key <key> -Verify
scripts\setup.ps1 -SetKey -Channel baidu-ocr -Key <ak> -Secret <sk> -Verify
scripts\setup.ps1 -SetCustom -BaseUrl <url> -Key <key> -Model <model> -Verify
scripts\setup.ps1 -RemoveKey -Channel <name|custom>
```

## 验证标准

每个云端视觉通道可用一张小测试图验证：

```powershell
scripts\vlm-vision.ps1 -ImagePath <test.png> -Prompt "describe this image in one sentence" -Channel <glm|glm-thinking|custom>
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

- 图片理解：`glm -> glm-thinking -> custom -> local`
- 复杂视觉推理：`glm-thinking -> custom -> local`
- 文档解析：`mineru flash -> mineru extract`
- OCR：`baidu-ocr -> windows-ocr -> vision reasoning`
