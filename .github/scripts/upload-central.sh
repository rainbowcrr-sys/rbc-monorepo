#!/usr/bin/env bash
# 把 deployment bundle 上传到 Maven Central Portal，并轮询到终态。
# 凭据只从环境变量读取，不写入任何文件、不回显。
# 失败时把 Portal 响应写成 check-run annotation，便于通过 API 读取诊断信息。
set -euo pipefail

: "${CENTRAL_USERNAME:?CENTRAL_USERNAME 未设置（Portal User Token username）}"
: "${CENTRAL_PASSWORD:?CENTRAL_PASSWORD 未设置（Portal User Token password）}"
BUNDLE="${1:?用法: upload-central.sh <bundle.zip> [AUTOMATIC|USER_MANAGED]}"
PUBLISHING_TYPE="${2:-${PUBLISHING_TYPE:-AUTOMATIC}}"

case "$PUBLISHING_TYPE" in
  AUTOMATIC|USER_MANAGED) ;;
  *) echo "publishingType 只能是 AUTOMATIC 或 USER_MANAGED，收到: $PUBLISHING_TYPE" >&2; exit 2 ;;
esac

API="${CENTRAL_API:-https://central.sonatype.com/api/v1/publisher}"
POLL_SECONDS="${POLL_SECONDS:-10}"
# Portal 的 PUBLISHING 阶段可能远超过 10 分钟，给足 30 分钟窗口
POLLS="${POLLS:-180}"
NAME="$(basename "$BUNDLE")"

if [ ! -f "$BUNDLE" ]; then
  echo "找不到 bundle: $BUNDLE" >&2
  exit 2
fi

# Bearer = base64(username:password)，仅放进请求头，不打印到日志
AUTH="$(printf '%s:%s' "$CENTRAL_USERNAME" "$CENTRAL_PASSWORD" | base64 | tr -d '\n')"
ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT

# body 写 stdout；非 2xx 时把错误写入 ERR_FILE 并返回 1
request() {
  local raw code body
  if ! raw="$(curl -sS --max-time 60 "$@" -H "Authorization: Bearer $AUTH" -w $'\n%{http_code}')"; then
    printf '%s' 'curl 请求失败（网络/超时）' > "$ERR_FILE"
    return 1
  fi
  code="${raw##*$'\n'}"
  body="${raw%$'\n'*}"
  if [[ ! "$code" =~ ^2 ]]; then
    printf 'HTTP %s: %s' "$code" "$body" > "$ERR_FILE"
    return 1
  fi
  printf '%s' "$body"
}

echo "上传 bundle: $NAME (publishingType=$PUBLISHING_TYPE)"
if ! RAW="$(request -X POST \
  -F "bundle=@${BUNDLE};type=application/octet-stream" \
  "${API}/upload?publishingType=${PUBLISHING_TYPE}&name=${NAME}")"; then
  MSG="$(cat "$ERR_FILE")"
  echo "::error title=Central Portal 上传失败::${MSG:0:1500}"
  echo "$MSG" >&2
  exit 1
fi

DEPLOYMENT="$(printf '%s' "$RAW" | tr -d '[:space:]')"
if [ -z "$DEPLOYMENT" ]; then
  echo "::error title=Central Portal 上传失败::上传未返回 deploymentId"
  echo "上传未返回 deploymentId" >&2
  exit 1
fi
echo "deploymentId: $DEPLOYMENT"
echo "::notice title=deploymentId::$DEPLOYMENT"

STATE=""
for i in $(seq 1 "$POLLS"); do
  if ! BODY="$(request -X POST "${API}/status?id=${DEPLOYMENT}")"; then
    MSG="$(cat "$ERR_FILE")"
    echo "::error title=Portal status 查询失败::${MSG:0:1500}"
    echo "$MSG" >&2
    exit 1
  fi
  STATE="$(printf '%s' "$BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("deploymentState",""))')"
  echo "状态 [$i/$POLLS]: ${STATE:-<空>}"

  case "$STATE" in
    PUBLISHED)
      echo "已发布到 Maven Central"
      printf '%s\n' "$BODY"
      exit 0
      ;;
    VALIDATED)
      if [ "$PUBLISHING_TYPE" = "AUTOMATIC" ]; then
        echo "AUTOMATIC 模式下 VALIDATED 后应自动进入 PUBLISHING，继续等待"
      else
        echo "校验通过（VALIDATED）。请到 https://central.sonatype.com/publishing/deployments 点 Publish"
        printf '%s\n' "$BODY"
        exit 0
      fi
      ;;
    FAILED)
      echo "::error title=Central Portal 校验失败::${BODY:0:1800}"
      echo "部署校验失败：" >&2
      printf '%s\n' "$BODY" >&2
      exit 1
      ;;
    PENDING|VALIDATING|PUBLISHING)
      ;;
    *)
      echo "::error title=Portal 状态无法识别::${BODY:0:1500}"
      echo "无法识别的状态，原始响应：" >&2
      printf '%s\n' "$BODY" >&2
      exit 1
      ;;
  esac
  sleep "$POLL_SECONDS"
done

# Portal 侧会继续完成发布，CI 轮询窗口耗尽不等于发布失败
case "$STATE" in
  PENDING|VALIDATING|VALIDATED|PUBLISHING)
    echo "::warning title=轮询窗口耗尽，Portal 仍在发布中::最后一次状态 $STATE，deploymentId=$DEPLOYMENT，可用 Check Central Deployment 工作流核对终态"
    echo "轮询窗口耗尽，Portal 仍在发布中（状态 $STATE），deploymentId=$DEPLOYMENT"
    exit 0
    ;;
esac
echo "::error title=等待超时::最后一次状态 ${STATE:-<空>}，deploymentId=$DEPLOYMENT"
echo "等待超时（最后一次状态: ${STATE:-<空>}），deploymentId=$DEPLOYMENT" >&2
exit 1
