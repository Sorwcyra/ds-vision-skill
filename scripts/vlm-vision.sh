#!/bin/bash
# ============================================================
# vlm-vision.sh - Generic OpenAI-compatible vision caller
# Linux/macOS port of ds-vision-skill's vlm-vision.ps1
# ASCII-only source. Pass Chinese text via --prompt.
# Exit codes: 0 success, 1 generic, 2 missing key/auth,
#             3 rate-limited, 4 network, 5 request rejected
#
# Usage:
#   vlm-vision.sh --image <path|url> [--prompt "text"] \
#       [--channel glm|glm-thinking|agnes-2.5-flash|agnes-2.0-flash|custom|custom-1|custom-2|custom-3|local] [--model M] \
#       [--base-url U] [--api-key K] [--json] [--timeout N]
# Env: GLM_API_KEY, AGNES_API_KEY, AGNES_BASE_URL,
#      VISION_CUSTOM_API_KEY, VISION_CUSTOM_BASE_URL, VISION_CUSTOM_MODEL,
#      VISION_CUSTOM_1_API_KEY, VISION_CUSTOM_1_BASE_URL, VISION_CUSTOM_1_MODEL,
#      VISION_CUSTOM_2_API_KEY, VISION_CUSTOM_2_BASE_URL, VISION_CUSTOM_2_MODEL,
#      VISION_CUSTOM_3_API_KEY, VISION_CUSTOM_3_BASE_URL, VISION_CUSTOM_3_MODEL,
#      VISION_LOCAL_MODEL
# ============================================================

set -u

# ---- defaults ----
CHANNEL="glm"
PROMPT="Describe this image in detail."
TIMEOUT=90
JSON_OUT=0
IMAGE=""
MODEL=""
BASE_URL=""
API_KEY=""
NO_CACHE=0

# ---- parse args (GNU style) ----
while [ $# -gt 0 ]; do
    case "$1" in
        --image|-i)      IMAGE="$2"; shift 2 ;;
        --prompt|-p)     PROMPT="$2"; shift 2 ;;
        --channel|-c)    CHANNEL="$2"; shift 2 ;;
        --model)         MODEL="$2"; shift 2 ;;
        --base-url)      BASE_URL="$2"; shift 2 ;;
        --api-key)       API_KEY="$2"; shift 2 ;;
        --json)          JSON_OUT=1; shift ;;
        --no-cache)      NO_CACHE=1; shift ;;
        --timeout)       TIMEOUT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: vlm-vision.sh --image <path|url> [--prompt text] [--channel glm|glm-thinking|agnes-2.5-flash|agnes-2.0-flash|custom|custom-1|custom-2|custom-3|local] [--model M] [--base-url U] [--api-key K] [--json] [--timeout N]"
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$IMAGE" ]; then
    echo "ERROR: --image is required" >&2
    exit 1
fi

# ---- resolve channel defaults ----
case "$CHANNEL" in
    glm)
        [ -z "$BASE_URL" ] && BASE_URL="https://open.bigmodel.cn/api/paas/v4/chat/completions"
        [ -z "$MODEL" ]    && MODEL="glm-4v-flash"
        [ -z "$API_KEY" ]  && API_KEY="${GLM_API_KEY:-}"
        ;;
    glm-thinking)
        [ -z "$BASE_URL" ] && BASE_URL="https://open.bigmodel.cn/api/paas/v4/chat/completions"
        [ -z "$MODEL" ]    && MODEL="glm-4.1v-thinking-flash"
        [ -z "$API_KEY" ]  && API_KEY="${GLM_API_KEY:-}"
        ;;
    agnes-2.5-flash)
        [ -z "$BASE_URL" ] && BASE_URL="${AGNES_BASE_URL:-https://api.agnes-ai.cn/v1/chat/completions}"
        [ -z "$MODEL" ]    && MODEL="agnes-2.5-flash"
        [ -z "$API_KEY" ]  && API_KEY="${AGNES_API_KEY:-}"
        ;;
    agnes-2.0-flash)
        [ -z "$BASE_URL" ] && BASE_URL="${AGNES_BASE_URL:-https://api.agnes-ai.cn/v1/chat/completions}"
        [ -z "$MODEL" ]    && MODEL="agnes-2.0-flash"
        [ -z "$API_KEY" ]  && API_KEY="${AGNES_API_KEY:-}"
        ;;
    custom)
        [ -z "$BASE_URL" ] && BASE_URL="${VISION_CUSTOM_BASE_URL:-}"
        [ -z "$MODEL" ]    && MODEL="${VISION_CUSTOM_MODEL:-}"
        [ -z "$API_KEY" ]  && API_KEY="${VISION_CUSTOM_API_KEY:-}"
        ;;
    custom-1)
        [ -z "$BASE_URL" ] && BASE_URL="${VISION_CUSTOM_1_BASE_URL:-}"
        [ -z "$MODEL" ]    && MODEL="${VISION_CUSTOM_1_MODEL:-}"
        [ -z "$API_KEY" ]  && API_KEY="${VISION_CUSTOM_1_API_KEY:-}"
        ;;
    custom-2)
        [ -z "$BASE_URL" ] && BASE_URL="${VISION_CUSTOM_2_BASE_URL:-}"
        [ -z "$MODEL" ]    && MODEL="${VISION_CUSTOM_2_MODEL:-}"
        [ -z "$API_KEY" ]  && API_KEY="${VISION_CUSTOM_2_API_KEY:-}"
        ;;
    custom-3)
        [ -z "$BASE_URL" ] && BASE_URL="${VISION_CUSTOM_3_BASE_URL:-}"
        [ -z "$MODEL" ]    && MODEL="${VISION_CUSTOM_3_MODEL:-}"
        [ -z "$API_KEY" ]  && API_KEY="${VISION_CUSTOM_3_API_KEY:-}"
        ;;
    local)
        [ -z "$BASE_URL" ] && BASE_URL="${LOCAL_VLM_URL:-http://localhost:11434/v1/chat/completions}"
        [ -z "$MODEL" ]    && MODEL="${VISION_LOCAL_MODEL:-${LOCAL_VLM_MODEL:-qwen2.5-vl:3b}}"
        ;;
    *) echo "ERROR: unknown channel: $CHANNEL" >&2; exit 1 ;;
esac

if [ -z "$API_KEY" ] && [ "$CHANNEL" != "local" ]; then
    echo "ERROR: missing API key for channel '$CHANNEL' (set env or --api-key)" >&2
    exit 2
fi
if [ -z "$BASE_URL" ]; then
    echo "ERROR: missing base URL for channel '$CHANNEL'" >&2
    exit 2
fi
BASE_URL="${BASE_URL%/}"
case "$BASE_URL" in
    */chat/completions) : ;;
    *) BASE_URL="$BASE_URL/chat/completions" ;;
esac

# ---- image -> data URL ----
if [[ "$IMAGE" =~ ^https?:// ]]; then
    IMG_URL="$IMAGE"
elif [ -f "$IMAGE" ]; then
    MIME=$(file --mime-type -b "$IMAGE" 2>/dev/null || echo "image/jpeg")
    B64=$(base64 -w0 "$IMAGE" 2>/dev/null || base64 "$IMAGE" | tr -d '\n')
    IMG_URL="data:${MIME};base64,${B64}"
else
    echo "ERROR: image not found: $IMAGE" >&2
    exit 1
fi

# ---- build JSON payload ----
PAYLOAD=$(python3 - "$IMG_URL" "$PROMPT" "$MODEL" <<'PYEOF'
import json, sys
img_url, prompt, model = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {
    "model": model,
    "messages": [{
        "role": "user",
        "content": [
            {"type": "image_url", "image_url": {"url": img_url}},
            {"type": "text", "text": prompt}
        ]
    }]
}
print(json.dumps(payload))
PYEOF
)

# ---- call API ----
AUTH_HEADER=()
if [ "$CHANNEL" != "local" ] || [ -n "${API_KEY:-}" ]; then
    AUTH_HEADER=(-H "Authorization: Bearer $API_KEY")
fi

RESP=$(curl -s -m "$TIMEOUT" -w "\n%{http_code}" "$BASE_URL" \
    -H "Content-Type: application/json" \
    "${AUTH_HEADER[@]}" \
    -d "$PAYLOAD" 2>/dev/null)
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

# ---- classify errors ----
if [ "$HTTP_CODE" = "000" ]; then
    echo "ERROR: network failure" >&2
    exit 4
fi
if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    echo "ERROR: auth failed (HTTP $HTTP_CODE)" >&2
    exit 2
fi
if [ "$HTTP_CODE" = "429" ]; then
    echo "ERROR: rate limited (HTTP 429)" >&2
    exit 3
fi
if [ "$HTTP_CODE" != "200" ]; then
    echo "ERROR: request rejected (HTTP $HTTP_CODE): $(echo "$BODY" | head -c 300)" >&2
    exit 5
fi

# ---- output ----
if [ "$JSON_OUT" = "1" ]; then
    echo "$BODY" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    out = {'content': d['choices'][0]['message']['content']}
    if 'usage' in d: out['usage'] = d['usage']
    print(json.dumps(out, ensure_ascii=False))
except Exception as e:
    print(json.dumps({'error': str(e)}, ensure_ascii=False))
"
else
    echo "$BODY" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(d['choices'][0]['message']['content'])
"
fi
exit 0
