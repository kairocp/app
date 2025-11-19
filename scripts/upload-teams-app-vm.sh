#!/usr/bin/env bash
# upload-teams-app-vm.sh — run pack-and-upload-teams.ps1 on the media VM via az vm run-command
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source .env next to this script
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  source "${SCRIPT_DIR}/.env"
elif [[ -f .env ]]; then
  source .env
fi

REQ=(SUB_NAME RG APP MEDIA_VM APP_ID)
for v in "${REQ[@]}"; do [[ -n "${!v:-}" ]] || { echo "❌ Missing $v in .env"; exit 1; }; done

MANIFEST_ID="${MANIFEST_ID:-$APP_ID}"

az account set --subscription "$SUB_NAME"

APP_HOST="$(az webapp show -g "$RG" -n "$APP" --query defaultHostName -o tsv)"
MEDIA_FQDN="${MEDIA_FQDN:-$(az network public-ip show -g "$RG" -n "${MEDIA_VM}-pip" --query dnsSettings.fqdn -o tsv)}"

if [[ -z "$APP_HOST" || -z "$MEDIA_FQDN" ]]; then
  echo "❌ Unable to resolve APP_HOST or MEDIA_FQDN"
  exit 1
fi

echo "APP_HOST:    $APP_HOST"
echo "MEDIA_FQDN:  $MEDIA_FQDN"
echo "MANIFEST_ID: $MANIFEST_ID"
echo "BOT_ID:      $APP_ID"

PW_DIR='C:\media-bot\src\kairo\teams\scripts'
ALT_PW_DIR='C:\media-bot\src\app\kairo\teams\scripts'
tmpfile="$(mktemp)"
cat >"$tmpfile" <<EOF
\$dirs = @("$PW_DIR","$ALT_PW_DIR")
\$found = @(); foreach(\$d in \$dirs){ if(Test-Path \$d){ \$found += \$d } }
if(-not \$found){ \$probe = Get-ChildItem -Path "C:\media-bot" -Recurse -Filter "pack-and-upload-teams.ps1" -ErrorAction SilentlyContinue | Select-Object -First 1; if(\$probe){ \$found = @(\$probe.DirectoryName) }}
if(-not \$found){ throw "pack-and-upload-teams.ps1 not found on VM" }
\$dir = \$found[0]
cd \$dir
Write-Host ("Using script dir: " + \$dir)
.\pack-and-upload-teams.ps1 -ManifestId "$MANIFEST_ID" -BotId "$APP_ID" -AppHost "$APP_HOST" -MediaFqdn "$MEDIA_FQDN" -ResourceId "$APP_ID"
EOF

az vm run-command invoke -g "$RG" -n "$MEDIA_VM" --command-id RunPowerShellScript --scripts @"$tmpfile"
rm -f "$tmpfile"

echo "✅ Triggered pack-and-upload on VM $MEDIA_VM"
