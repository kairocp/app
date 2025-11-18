#!/usr/bin/env bash
# validate.sh — hybrid validation with robust calling route checks
set -euo pipefail
# Always source .env next to this script (fallback to caller cwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  source "${SCRIPT_DIR}/.env"
elif [[ -f .env ]]; then
  source .env
fi

REQ_VARS=(SUB_NAME RG LOC PLAN APP MEDIA_VM BOT_NAME APP_ID APP_SECRET TENANT_ID AOAI_NAME AOAI_DEPLOY_NAME SPEECH_NAME PG_NAME PG_ADMIN PG_ADMIN_PW PG_DB)
for V in "${REQ_VARS[@]}"; do [[ -n "${!V:-}" ]] || { echo "❌ Missing $V in .env"; exit 1; }; done

az account set --subscription "$SUB_NAME"
SUB_ID="$(az account show --query id -o tsv)"

APP_HOST="$(az webapp show -g "$RG" -n "$APP" --query defaultHostName -o tsv)"
MEDIA_FQDN="${MEDIA_FQDN:-$(az network public-ip show -g "$RG" -n "${MEDIA_VM}-pip" --query dnsSettings.fqdn -o tsv)}"
if [[ -z "$MEDIA_FQDN" ]]; then
  echo "❌ Could not resolve media VM public FQDN from ${MEDIA_VM}-pip"
  exit 1
fi
MSG_ENDPOINT_RAW="https://${APP_HOST}/api/messages"
CALL_ENDPOINT_RAW="https://${MEDIA_FQDN}/callback"

normalize_url_py () {
python3 - "$@" <<'PY'
import sys, urllib.parse
u=sys.argv[1].strip()
while u.endswith('/'): u=u[:-1]
p=urllib.parse.urlparse(u)
print(f"{p.scheme.lower()}://{p.netloc.lower()}{p.path}")
PY
}
MSG_ENDPOINT="$(normalize_url_py "$MSG_ENDPOINT_RAW")"
CALL_ENDPOINT="$(normalize_url_py "$CALL_ENDPOINT_RAW")"

BOT_URI="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.BotService/botServices/${BOT_NAME}?api-version=2022-09-15"
CHAN_URI="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.BotService/botServices/${BOT_NAME}/channels/MsTeamsChannel?api-version=2022-09-15"

echo "== Hosts =="
echo "APP:   https://${APP_HOST}/"
echo "MEDIA: https://${MEDIA_FQDN}/"
echo "MSG:   $MSG_ENDPOINT"
echo "CALL:  $CALL_ENDPOINT"
echo

echo "[1] Bot Registration:"
az rest --method GET --uri "$BOT_URI" \
  --query "{name:name,kind:kind,location:location,endpoint:properties.endpoint}" -o json

echo "[2] Teams channel (both fields):"
az rest --method GET --uri "$CHAN_URI" \
  --query "{isEnabled:properties.properties.isEnabled,enableCalling:properties.properties.enableCalling,incomingCallRoute:properties.properties.incomingCallRoute,callingWebhook:properties.properties.callingWebhook}" -o json
echo

echo "[AUTO-FIX CHECK]"
REAL_MSG_RAW=$(az rest --method GET --uri "$BOT_URI" --query "properties.endpoint" -o tsv)
REAL_CALL1_RAW=$(az rest --method GET --uri "$CHAN_URI" --query "properties.properties.incomingCallRoute" -o tsv)
REAL_CALL2_RAW=$(az rest --method GET --uri "$CHAN_URI" --query "properties.properties.callingWebhook" -o tsv)
REAL_MSG="$(normalize_url_py "${REAL_MSG_RAW:-}")"
REAL_CALL="$(normalize_url_py "${REAL_CALL1_RAW:-${REAL_CALL2_RAW:-}}")"
echo "Expected MSG: $MSG_ENDPOINT"
echo "Actual   MSG: $REAL_MSG"
echo "Expected CALL: $CALL_ENDPOINT"
echo "Actual   CALL: $REAL_CALL"

fix=0
if [[ "$REAL_MSG" != "$MSG_ENDPOINT" ]]; then
  echo "→ Fix messaging endpoint"
  az rest --method PATCH --uri "$BOT_URI" --body "{\"properties\":{\"endpoint\":\"${MSG_ENDPOINT_RAW}\"}}" >/dev/null
  fix=1
fi
if [[ "$REAL_CALL" != "$CALL_ENDPOINT" || -z "$REAL_CALL" ]]; then
  echo "→ Fix calling route (set both fields)"
  az rest --method PUT --uri "$CHAN_URI" --body "{
    \"location\":\"global\",
    \"properties\":{\"channelName\":\"MsTeamsChannel\",\"properties\":{\"isEnabled\":true,\"enableCalling\":true,\"incomingCallRoute\":\"${CALL_ENDPOINT_RAW}\",\"callingWebhook\":\"${CALL_ENDPOINT_RAW}\"}}
  }" >/dev/null
  fix=1
fi
if [[ "$fix" -eq 1 ]]; then
  for i in {1..10}; do
    sleep 2
    REAL_MSG_RAW=$(az rest --method GET --uri "$BOT_URI" --query "properties.endpoint" -o tsv)
    REAL_CALL1_RAW=$(az rest --method GET --uri "$CHAN_URI" --query "properties.properties.incomingCallRoute" -o tsv)
    REAL_CALL2_RAW=$(az rest --method GET --uri "$CHAN_URI" --query "properties.properties.callingWebhook" -o tsv)
    REAL_MSG="$(normalize_url_py "${REAL_MSG_RAW:-}")"
    REAL_CALL="$(normalize_url_py "${REAL_CALL1_RAW:-${REAL_CALL2_RAW:-}}")"
    [[ "$REAL_MSG" == "$MSG_ENDPOINT" && "$REAL_CALL" == "$CALL_ENDPOINT" ]] && { echo "✅ Rebind confirmed."; break; }
    [[ $i -eq 10 ]] && echo "⚠️ Still mismatched after retries."
  done
fi

echo
echo "[3] Reachability (GET status codes only)"
CALL_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' -X GET "$CALL_ENDPOINT_RAW")"
MSG_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' -X GET "$MSG_ENDPOINT_RAW")"
echo "CALL GET $CALL_ENDPOINT_RAW => $CALL_STATUS"
echo "MSG  GET $MSG_ENDPOINT_RAW => $MSG_STATUS"

echo
echo "[4] App settings (key values)"
az webapp config appsettings list -g "$RG" -n "$APP" \
  --query "[?name=='AOAI_ENDPOINT' || name=='AOAI_KEY' || name=='AOAI_DEPLOYMENT' || name=='AOAI_EMBED' || name=='PG_CONN' || name=='INTERNAL_TOKEN'].[name,value]" -o table

echo
echo "================ VALIDATION COMPLETE ================"
echo "Expect incomingCallRoute or callingWebhook to equal: $CALL_ENDPOINT_RAW"
