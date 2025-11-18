#!/usr/bin/env bash
# deploy.sh — CISO Copilot (hybrid: Python Reasoning + .NET Media/Calling)
set -euo pipefail
# Always source .env next to this script (fallback to caller cwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  source "${SCRIPT_DIR}/.env"
elif [[ -f .env ]]; then
  source .env
fi

# ===== required vars =====
req_vars=(SUB_NAME RG LOC PLAN APP APP_NAME BOT_NAME BOT_DISPLAY APP_ID APP_SECRET TENANT_ID AOAI_NAME AOAI_SKU AOAI_DEPLOY_NAME AOAI_MODEL AOAI_VERSION SPEECH_NAME PG_NAME PG_ADMIN PG_ADMIN_PW PG_TIER PG_SKU PG_VER PG_STORAGE PG_DB INTERNAL_TOKEN ORG_DEFAULT MEDIA_VM MEDIA_ADMIN MEDIA_ADMIN_PW MEDIA_PORT_START MEDIA_PORT_END MEDIA_SIG_PORT MEDIA_VM_SIZE REPO_URL REPO_BRANCH MEDIA_BOT_PROJ)
for v in "${req_vars[@]}"; do [[ -n "${!v:-}" ]] || { echo "❌ Missing $v in .env"; exit 1; }; done

echo "== Login & context =="
if ! az account show >/dev/null 2>&1; then
  az login --use-device-code >/dev/null
fi
az account set --subscription "$SUB_NAME"
SUB_ID="$(az account show --query id -o tsv)"
TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"

echo "== Providers =="
for ns in Microsoft.BotService Microsoft.CognitiveServices Microsoft.DBforPostgreSQL Microsoft.Web; do az provider register --namespace "$ns" >/dev/null || true; done
while :; do s=$(az provider show --namespace Microsoft.Web --query registrationState -o tsv); [[ "$s" == "Registered" ]] && break; sleep 2; done

echo "== RG =="
EXIST_LOWER="$(az group show -n "$RG" --query location -o tsv 2>/dev/null || true)"
if [[ -n "$EXIST_LOWER" ]]; then
  echo "Using existing resource group $RG in $EXIST_LOWER"
  echo "Resources will deploy to LOC=${LOC:-$EXIST_LOWER} (set LOC/MEDIA_LOC to override default resource regions)"
else
  az group create -n "$RG" -l "$LOC" >/dev/null
fi
MEDIA_LOC="${MEDIA_LOC:-$LOC}"
MEDIA_ZONE="${MEDIA_ZONE:-}"
AOAI_LOC="${AOAI_LOC:-$LOC}"

echo "== Confirm App Registration exists =="
az ad app show --id "$APP_ID" >/dev/null || { echo "App $APP_ID not found"; exit 1; }
az ad sp show --id "$APP_ID" >/dev/null 2>&1 || az ad sp create --id "$APP_ID" >/dev/null
# Ensure portal redirect exists for admin consent ease
if ! az ad app show --id "$APP_ID" --query "web.redirectUris[?contains(@, 'https://portal.azure.com/')]" -o tsv | grep -q portal.azure.com; then
  az ad app update --id "$APP_ID" --web-redirect-uris https://portal.azure.com/ >/dev/null
fi

echo "== Bot Registration (sdk, global) =="
cat > botreg.json <<'EOF'
{
  "$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion":"1.0.0.0",
  "parameters":{
    "botId":{"type":"string"},
    "displayName":{"type":"string"},
    "endpoint":{"type":"string"},
    "appId":{"type":"string"},
    "tenantId":{"type":"string"},
    "sku":{"type":"string","defaultValue":"F0","allowedValues":["F0","S1"]},
    "location":{"type":"string","defaultValue":"global"}
  },
  "resources":[
    {"type":"Microsoft.BotService/botServices","apiVersion":"2022-09-15",
     "name":"[parameters('botId')]","location":"[parameters('location')]",
     "sku":{"name":"[parameters('sku')]"},"kind":"sdk",
     "properties":{
       "displayName":"[parameters('displayName')]",
       "endpoint":"[parameters('endpoint')]",
       "msaAppId":"[parameters('appId')]",
       "msaAppType":"SingleTenant",
       "msaAppTenantId":"[parameters('tenantId')]",
       "iconUrl":"https://docs.botframework.com/static/devportal/client/images/bot-framework-default.png",
       "luisAppIds":[],
       "isCmekEnabled":false
     }
    }
  ]
}
EOF

# Temporary endpoint (we'll patch to APP messages URL later)
az deployment group create -g "$RG" --template-file botreg.json \
  --parameters botId="$BOT_NAME" displayName="$BOT_DISPLAY" endpoint="https://example.com/api/messages" appId="$APP_ID" tenantId="$TENANT_ID" sku="F0" location="global" >/dev/null || true

echo "== App Service plan & apps =="
PLAN_LOC="$(az appservice plan list -g "$RG" --query "[?name=='$PLAN'].location | [0]" -o tsv 2>/dev/null || true)"
if [[ -n "$PLAN_LOC" ]]; then
  echo "Using existing plan $PLAN in $PLAN_LOC"
  LOC="$PLAN_LOC"
else
  az appservice plan create -g "$RG" -n "$PLAN" --sku P1v3 --is-linux --location "$LOC" >/dev/null || true
fi
az webapp create -g "$RG" -p "$PLAN" -n "$APP" --runtime "PYTHON:3.12" >/dev/null || true
APP_HOST="$(az webapp show -g "$RG" -n "$APP" --query defaultHostName -o tsv)"
MSG_ENDPOINT="https://${APP_HOST}/api/messages"

echo "== Media VM (Windows, Graph media bot hosting) =="
az network vnet create -g "$RG" -l "$MEDIA_LOC" -n "${MEDIA_VM}-vnet" --subnet-name default >/dev/null || true
az network nsg create -g "$RG" -l "$MEDIA_LOC" -n "${MEDIA_VM}-nsg" >/dev/null || true

# Allow HTTPS, signaling, and media UDP range
az network nsg rule create -g "$RG" --nsg-name "${MEDIA_VM}-nsg" -n allow-https --priority 100 --access Allow --direction Inbound --protocol Tcp --source-address-prefixes Internet --source-port-ranges '*' --destination-port-ranges 443 >/dev/null || true
az network nsg rule create -g "$RG" --nsg-name "${MEDIA_VM}-nsg" -n allow-sig --priority 110 --access Allow --direction Inbound --protocol Tcp --source-address-prefixes Internet --source-port-ranges '*' --destination-port-ranges "$MEDIA_SIG_PORT" >/dev/null || true
az network nsg rule create -g "$RG" --nsg-name "${MEDIA_VM}-nsg" -n allow-media --priority 120 --access Allow --direction Inbound --protocol Udp --source-address-prefixes Internet --source-port-ranges '*' --destination-port-ranges "${MEDIA_PORT_START}-${MEDIA_PORT_END}" >/dev/null || true

if [[ -n "$MEDIA_ZONE" ]]; then
  az network public-ip create -g "$RG" -l "$MEDIA_LOC" -n "${MEDIA_VM}-pip" --sku Standard --allocation-method Static --dns-name "${MEDIA_VM}" --zone "$MEDIA_ZONE" >/dev/null || true
else
  az network public-ip create -g "$RG" -l "$MEDIA_LOC" -n "${MEDIA_VM}-pip" --sku Standard --allocation-method Static --dns-name "${MEDIA_VM}" >/dev/null || true
fi
az network nic create -g "$RG" -l "$MEDIA_LOC" -n "${MEDIA_VM}-nic" --vnet-name "${MEDIA_VM}-vnet" --subnet default --network-security-group "${MEDIA_VM}-nsg" --public-ip-address "${MEDIA_VM}-pip" >/dev/null || true

if ! az vm show -g "$RG" -n "$MEDIA_VM" >/dev/null 2>&1; then
  echo "Creating media VM (will try fallbacks if SKU unavailable)..."
  # Order favors configured size, then small DC SKUs (available in eastus),
  # then general purpose fallbacks.
  sizes=("$MEDIA_VM_SIZE" "Standard_DC1s_v3" "Standard_DC1ds_v3" "Standard_D2s_v3" "Standard_D2s_v5" "Standard_DS2_v2" "Standard_B2s" "Standard_B2ms")
  created=0
  for sz in "${sizes[@]}"; do
    [[ -z "$sz" ]] && continue
    echo "Attempting size: $sz"
    zone_args=()
    if [[ -n "${MEDIA_ZONE:-}" ]]; then
      zone_args+=(--zone "$MEDIA_ZONE")
    fi
    if az vm create -g "$RG" -l "$MEDIA_LOC" -n "$MEDIA_VM" --image Win2022Datacenter --size "$sz" --admin-username "$MEDIA_ADMIN" --admin-password "$MEDIA_ADMIN_PW" --nics "${MEDIA_VM}-nic" ${zone_args[@]+"${zone_args[@]}"} >/dev/null 2>&1; then
      created=1
      MEDIA_VM_SIZE="$sz"
      break
    else
      echo "Size $sz failed (likely capacity). Trying next..."
    fi
  done
  if [[ "$created" -ne 1 ]]; then
    echo "❌ Could not create media VM with any fallback sizes."
    exit 1
  fi
else
  echo "Media VM $MEDIA_VM already exists, skipping create."
fi

MEDIA_FQDN="$(az network public-ip show -g "$RG" -n "${MEDIA_VM}-pip" --query dnsSettings.fqdn -o tsv)"
# The sample listens on /callback (CallingCallbackController). Keep Graph calling route aligned.
CALL_ENDPOINT="https://${MEDIA_FQDN}/callback"

echo "== Speech =="
SPEECH_LOC="$(az cognitiveservices account list -g "$RG" --query "[?name=='$SPEECH_NAME'].location | [0]" -o tsv 2>/dev/null || true)"
if [[ -n "$SPEECH_LOC" ]]; then
  echo "Using existing speech account $SPEECH_NAME in $SPEECH_LOC"
else
  az cognitiveservices account create -n "$SPEECH_NAME" -g "$RG" -l "$LOC" --kind SpeechServices --sku S0 --yes >/dev/null || true
fi
SPEECH_KEY="$(az cognitiveservices account keys list -n "$SPEECH_NAME" -g "$RG" --query key1 -o tsv)"
SPEECH_REGION="${SPEECH_LOC:-$LOC}"

echo "== Build & run media bot on Windows VM =="
cat > install-media-bot.ps1 <<EOF
param(
  [string]\$RepoUrl,
  [string]\$Branch,
  [string]\$ProjectPath,
  [string]\$InstallDir = "C:\\media-bot"
)

Write-Host "Installing media bot from repo \$RepoUrl (branch \$Branch) into \$InstallDir"

New-Item -ItemType Directory -Force -Path \$InstallDir | Out-Null
\$env:Path += ";C:\\Program Files\\Git\\bin;C:\\Program Files\\dotnet"
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# Install .NET 8 SDK via dotnet-install (portable, avoids download flakiness)
\$dotnetDir = "\$InstallDir\\dotnet"
if (-not (Test-Path "\$dotnetDir\\dotnet.exe")) {
  Write-Host "Installing .NET 8 SDK via dotnet-install..."
  \$dotnetInstaller = "\$InstallDir\\dotnet-install.ps1"
  Invoke-WebRequest -UseBasicParsing -Headers @{"User-Agent"="Mozilla/5.0"} -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile \$dotnetInstaller
  if (-not (Test-Path \$dotnetInstaller)) { throw "dotnet-install.ps1 download failed" }
  & powershell -ExecutionPolicy Bypass -File \$dotnetInstaller -Version 8.0.403 -InstallDir \$dotnetDir
}
\$env:DOTNET_ROOT = \$dotnetDir
\$env:Path = "\$dotnetDir;" + \$env:Path

# Install Git via Chocolatey if not present (refresh PATH for this session)
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
  Write-Host "Installing Chocolatey + Git..."
  Set-ExecutionPolicy Bypass -Scope Process -Force
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
  iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  choco install git -y
  \$env:Path += ";C:\\Program Files\\Git\\bin"
}
\$git = "C:\\Program Files\\Git\\bin\\git.exe"
if (-not (Test-Path \$git)) { throw "git not found at \$git" }

# Ensure .NET SDK available for publish
\$dotnet = "\$dotnetDir\\dotnet.exe"
if (-not (Test-Path \$dotnet)) { throw ".NET SDK not found at \$dotnet" }

# Clone or update repo
\$repoDir = "\$InstallDir\\src"
if (-not (Test-Path \$repoDir)) {
  & \$git clone \$RepoUrl \$repoDir
} else {
  & \$git -C \$repoDir fetch origin
}
& \$git -C \$repoDir checkout \$Branch
& \$git -C \$repoDir pull origin \$Branch
\$projectPathResolved = Join-Path \$repoDir \$ProjectPath
if (-not (Test-Path \$projectPathResolved)) { throw "Project file not found at \$projectPathResolved" }

# Publish the media bot
\$publishDir = "\$InstallDir\\publish"
Write-Host "Publishing media bot project \$ProjectPath to \$publishDir"
& \$dotnet publish \$projectPathResolved -c Release -o \$publishDir

# Env vars for the bot
[System.Environment]::SetEnvironmentVariable("REASON_URL", "https://${APP_HOST}", "Machine")
[System.Environment]::SetEnvironmentVariable("INTERNAL_TOKEN", "${INTERNAL_TOKEN}", "Machine")
[System.Environment]::SetEnvironmentVariable("ORG_DEFAULT", "${ORG_DEFAULT}", "Machine")
[System.Environment]::SetEnvironmentVariable("AzureAd__Instance", "https://login.microsoftonline.com/", "Machine")
[System.Environment]::SetEnvironmentVariable("AzureAd__TenantId", "${TENANT_ID}", "Machine")
[System.Environment]::SetEnvironmentVariable("AzureAd__ClientId", "${APP_ID}", "Machine")
[System.Environment]::SetEnvironmentVariable("AzureAd__ClientSecret", "${APP_SECRET}", "Machine")
[System.Environment]::SetEnvironmentVariable("SPEECH_KEY", "${SPEECH_KEY}", "Machine")
[System.Environment]::SetEnvironmentVariable("SPEECH_REGION", "${SPEECH_REGION}", "Machine")
[System.Environment]::SetEnvironmentVariable("MicrosoftAppId", "${APP_ID}", "Machine")
[System.Environment]::SetEnvironmentVariable("MicrosoftAppPassword", "${APP_SECRET}", "Machine")
[System.Environment]::SetEnvironmentVariable("TENANT_ID", "${TENANT_ID}", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__AppId", "${APP_ID}", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__AppSecret", "${APP_SECRET}", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__BotBaseUrl", "https://${MEDIA_FQDN}", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__PlaceCallEndpointUrl", "https://graph.microsoft.com/v1.0", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__GraphApiResourceUrl", "https://graph.microsoft.com", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__MicrosoftLoginUrl", "https://login.microsoftonline.com/", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__RecordingDownloadDirectory", "temp", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__CatalogAppId", "${APP_ID}", "Machine")
[System.Environment]::SetEnvironmentVariable("CognitiveServices__Enabled", "true", "Machine")
[System.Environment]::SetEnvironmentVariable("CognitiveServices__SpeechKey", "${SPEECH_KEY}", "Machine")
[System.Environment]::SetEnvironmentVariable("CognitiveServices__SpeechRegion", "${SPEECH_REGION}", "Machine")
[System.Environment]::SetEnvironmentVariable("CognitiveServices__SpeechRecognitionLanguage", "en-US", "Machine")
[System.Environment]::SetEnvironmentVariable("Users__UserIdWithAssignedOnlineMeetingPolicy", "", "Machine")
[System.Environment]::SetEnvironmentVariable("MEDIA_PORT_START", "${MEDIA_PORT_START}", "Machine")
[System.Environment]::SetEnvironmentVariable("MEDIA_PORT_END", "${MEDIA_PORT_END}", "Machine")
[System.Environment]::SetEnvironmentVariable("MEDIA_SIG_PORT", "${MEDIA_SIG_PORT}", "Machine")
[System.Environment]::SetEnvironmentVariable("ACS_CONNECTION_STRING", "${ACS_CONNECTION_STRING}", "Machine")
[System.Environment]::SetEnvironmentVariable("ACS_CALLBACK_URL", "https://${MEDIA_FQDN}/api/calling", "Machine")

# Start bot as scheduled task
\$exeName = [System.IO.Path]::GetFileNameWithoutExtension(\$ProjectPath)
\$exe = Join-Path \$publishDir (\$exeName + ".exe")
Write-Host "Registering MediaBot scheduled task..."
\$action  = New-ScheduledTaskAction -Execute \$exe -WorkingDirectory \$publishDir
\$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "MediaBot" -Action \$action -Trigger \$trigger -RunLevel Highest -User "SYSTEM" -Force | Out-Null

Write-Host "Starting MediaBot process..."
Start-Process \$exe -WorkingDirectory \$publishDir
EOF

az vm run-command invoke -g "$RG" -n "$MEDIA_VM" \
  --command-id RunPowerShellScript \
  --scripts @"install-media-bot.ps1" \
  --parameters "RepoUrl=$REPO_URL" "Branch=$REPO_BRANCH" "ProjectPath=$MEDIA_BOT_PROJ"

echo "== Enable Teams + set calling route (both fields) =="
BOT_URI="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.BotService/botServices/${BOT_NAME}?api-version=2022-09-15"
CHAN_URI="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.BotService/botServices/${BOT_NAME}/channels/MsTeamsChannel?api-version=2022-09-15"

# Enable Teams
az rest --method PUT --uri "$CHAN_URI" --body '{"location":"global","properties":{"channelName":"MsTeamsChannel","properties":{"isEnabled":true}}}' >/dev/null
# Then enable calling + set both incomingCallRoute & callingWebhook
az rest --method PUT --uri "$CHAN_URI" --body "{
  \"location\":\"global\",
  \"properties\":{\"channelName\":\"MsTeamsChannel\",\"properties\":{\"isEnabled\":true,\"enableCalling\":true,\"incomingCallRoute\":\"${CALL_ENDPOINT}\",\"callingWebhook\":\"${CALL_ENDPOINT}\"}}
}" >/dev/null

# Rebind bot messaging endpoint to APP /api/messages
az rest --method PATCH --uri "$BOT_URI" --body "{\"properties\":{\"endpoint\":\"${MSG_ENDPOINT}\"}}" >/dev/null

echo "== Graph Calls.* app roles (Application) =="
GRAPH_APPID="00000003-0000-0000-c000-000000000000"
APP_SP_ID="$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)"
GRAPH_SP_ID="$(az ad sp list --filter "appId eq '$GRAPH_APPID'" --query "[0].id" -o tsv)"
WANT='["Calls.AccessMedia.All","Calls.Initiate.All","Calls.InitiateGroupCall.All","Calls.JoinGroupCall.All","Calls.JoinGroupCallAsGuest.All"]'
ROLES="$(az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/${GRAPH_SP_ID}/appRoles")"
MAP="$(jq --argjson want "$WANT" '.value|map(select(.value as $v|$want|index($v)!=null))|map({value,id})' <<<"$ROLES")"
EXIST="$(az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/${APP_SP_ID}/appRoleAssignments")"
for row in $(jq -c '.[]' <<<"$MAP"); do
  val="$(jq -r '.value' <<<"$row")"; id="$(jq -r '.id' <<<"$row")"
  have="$(jq -r --arg rid "$GRAPH_SP_ID" --arg appRoleId "$id" '.value[]? | select(.resourceId==$rid and .appRoleId==$appRoleId)' <<<"$EXIST" | wc -l | tr -d ' ')"
  [[ "$have" -gt 0 ]] && echo "  SKIP $val" || az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/${APP_SP_ID}/appRoleAssignments" --body "{\"principalId\":\"${APP_SP_ID}\",\"resourceId\":\"${GRAPH_SP_ID}\",\"appRoleId\":\"${id}\"}" -o none
done

echo "== Azure OpenAI =="
CUR_AOAI_LOC="$(az cognitiveservices account show -g "$RG" -n "$AOAI_NAME" --query location -o tsv 2>/dev/null || true)"
if [[ -n "$CUR_AOAI_LOC" ]]; then
  echo "Using existing AOAI account $AOAI_NAME in $CUR_AOAI_LOC"
  AOAI_ENDPOINT="$(az cognitiveservices account show -n "$AOAI_NAME" -g "$RG" --query properties.endpoint -o tsv)"
  AOAI_KEY="$(az cognitiveservices account keys list -n "$AOAI_NAME" -g "$RG" --query key1 -o tsv)"
else
  echo "AOAI account $AOAI_NAME not found; attempting create in $AOAI_LOC..."
  for i in {1..3}; do
    if az cognitiveservices account create -n "$AOAI_NAME" -g "$RG" -l "$AOAI_LOC" --kind OpenAI --sku "$AOAI_SKU" --custom-domain "$AOAI_NAME" --yes >/dev/null 2>/dev/null; then
      break
    fi
    echo "AOAI create attempt $i failed; sleeping 10s and retrying..."
    sleep 10
  done
  CUR_AOAI_LOC="$(az cognitiveservices account show -g "$RG" -n "$AOAI_NAME" --query location -o tsv 2>/dev/null || true)"
  if [[ -n "$CUR_AOAI_LOC" ]]; then
    DEPLOY_EXISTS="$(az cognitiveservices account deployment list -g "$RG" -n "$AOAI_NAME" --query "[?name=='$AOAI_DEPLOY_NAME'] | length(@)" -o tsv 2>/dev/null || echo 0)"
    if [[ "$DEPLOY_EXISTS" -eq 0 ]]; then
      az cognitiveservices account deployment create -g "$RG" -n "$AOAI_NAME" --deployment-name "$AOAI_DEPLOY_NAME" --model-name "$AOAI_MODEL" --model-version "$AOAI_VERSION" --model-format OpenAI --sku-name "$AOAI_SKU" >/dev/null || true
    fi
    AOAI_ENDPOINT="$(az cognitiveservices account show -n "$AOAI_NAME" -g "$RG" --query properties.endpoint -o tsv)"
    AOAI_KEY="$(az cognitiveservices account keys list -n "$AOAI_NAME" -g "$RG" --query key1 -o tsv)"
  else
    echo "⚠️ AOAI $AOAI_NAME still unavailable (quota/soft-delete). Skipping AOAI endpoint/key; set manually if needed."
    AOAI_ENDPOINT=""
    AOAI_KEY=""
  fi
fi
AOAI_EMBED="${AOAI_EMBED_NAME:-text-embedding-3-large}"

echo "== Postgres (pgvector allow-list) =="
PG_CUR_LOC="$(az postgres flexible-server list -g "$RG" --query "[?name=='$PG_NAME'].location | [0]" -o tsv 2>/dev/null || true)"
if [[ -n "$PG_CUR_LOC" ]]; then
  echo "Using existing Postgres $PG_NAME in $PG_CUR_LOC"
else
  az postgres flexible-server create \
    --name "$PG_NAME" --resource-group "$RG" --location "${PG_LOC:-$LOC}" \
    --admin-user "$PG_ADMIN" --admin-password "$PG_ADMIN_PW" \
    --tier "$PG_TIER" --sku-name "$PG_SKU" --storage-size "$PG_STORAGE" --version "$PG_VER" --yes >/dev/null || true
fi
MYIP="$(curl -s https://ipv4.icanhazip.com)"; az postgres flexible-server firewall-rule create -g "$RG" -n "$PG_NAME" --rule-name allow-my-ip --start-ip-address "$MYIP" --end-ip-address "$MYIP" >/dev/null || true
CUR_EXT="$(az postgres flexible-server parameter show -g "$RG" -s "$PG_NAME" -n azure.extensions --query value -o tsv || true)"
NEW_EXT="$(python3 - <<PY
cur="${CUR_EXT}".strip()
items=[x.strip() for x in cur.split(",") if x.strip()] if cur else []
if "vector" not in items: items.append("vector")
print(",".join(items))
PY
)"
if [[ "$NEW_EXT" != "$CUR_EXT" && -n "$NEW_EXT" ]]; then
  az postgres flexible-server parameter set -g "$RG" -s "$PG_NAME" -n azure.extensions --value "$NEW_EXT" >/dev/null
  az postgres flexible-server restart -g "$RG" -n "$PG_NAME" >/dev/null
fi
az postgres flexible-server db create -g "$RG" -s "$PG_NAME" -d "$PG_DB" >/dev/null || true

echo "== App settings =="
PG_HOST="${PG_NAME}.postgres.database.azure.com"
PG_CONN="postgres://${PG_ADMIN}:${PG_ADMIN_PW}@${PG_HOST}:5432/${PG_DB}?sslmode=require"
az webapp config appsettings set -g "$RG" -n "$APP" --settings \
  MicrosoftAppId="$APP_ID" MicrosoftAppPassword="$APP_SECRET" \
  AOAI_ENDPOINT="$AOAI_ENDPOINT" AOAI_KEY="$AOAI_KEY" AOAI_DEPLOYMENT="$AOAI_DEPLOY_NAME" AOAI_EMBED="$AOAI_EMBED" \
  PG_CONN="$PG_CONN" ORG_DEFAULT="$ORG_DEFAULT" INTERNAL_TOKEN="$INTERNAL_TOKEN" >/dev/null

echo
echo "==== DEPLOY COMPLETE ===="
echo "Reasoning Core:     https://${APP_HOST}/"
echo "Media/Calling VM:   https://${MEDIA_FQDN}/"
echo "Messaging endpoint: ${MSG_ENDPOINT}"
echo "Calling route:      ${CALL_ENDPOINT}"
echo "AOAI endpoint:      ${AOAI_ENDPOINT}"
echo "Speech region:      ${LOC}"
echo "PG host/db:         ${PG_HOST} / ${PG_DB}"
echo "Admin consent (if needed): https://login.microsoftonline.com/${TENANT_ID}/v2.0/adminconsent?client_id=${APP_ID}&redirect_uri=https%3A%2F%2Fportal.azure.com%2F"
