#!/usr/bin/env bash
# remote-test.sh — push env, validate, deploy reasoning, restart, and smoke /reason
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

set -a
[[ -f scripts/.env ]] && source scripts/.env
set +a

AOAI_ENDPOINT="https://${AOAI_NAME}.openai.azure.com/"
AOAI_KEY="$(az cognitiveservices account keys list -n "$AOAI_NAME" -g "$RG" --query key1 -o tsv)"
PG_HOST="${PG_NAME}.postgres.database.azure.com"
PG_CONN="postgres://${PG_ADMIN}:${PG_ADMIN_PW}@${PG_HOST}:5432/${PG_DB}?sslmode=require"
AOAI_EMBED="${AOAI_EMBED_NAME:-text-embedding-3-large}"

echo "== Apply app settings =="
az webapp config appsettings set -g "$RG" -n "$APP" --settings \
  MicrosoftAppId="$APP_ID" MicrosoftAppPassword="$APP_SECRET" \
  AOAI_ENDPOINT="$AOAI_ENDPOINT" AOAI_KEY="$AOAI_KEY" \
  AOAI_DEPLOYMENT="$AOAI_DEPLOY_NAME" AOAI_EMBED="$AOAI_EMBED" \
  PG_CONN="$PG_CONN" ORG_DEFAULT="$ORG_DEFAULT" INTERNAL_TOKEN="$INTERNAL_TOKEN" >/dev/null

echo "== Validate wiring =="
bash scripts/validate.sh

echo "== Package reasoning =="
cd "$ROOT/reasoning"
zip -r ../reasoning.zip . >/dev/null

echo "== Deploy =="
az webapp deploy -g "$RG" -n "$APP" --src-path ../reasoning.zip --type zip >/dev/null

echo "== Restart =="
az webapp restart -g "$RG" -n "$APP" >/dev/null

echo "== Smoke call /reason =="
export TOKEN="$INTERNAL_TOKEN"
export BODY='{"org":"default","channel":"text","session_id":"demo","events":[{"type":"user_text","text":"Hi"}]}'
SIG=$(python - <<'PY'
import hmac, hashlib, os
print(hmac.new(os.environ["TOKEN"].encode(), os.environ["BODY"].encode(), hashlib.sha256).hexdigest())
PY
)
curl -sS -D - -o - "https://${APP}.azurewebsites.net/reason" \
  -H "Content-Type: application/json" \
  -H "x-signature: $SIG" \
  -d "$BODY"
echo
