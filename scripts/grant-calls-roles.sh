#!/usr/bin/env bash
set -euo pipefail
[[ -f .env ]] && source .env

: "${APP_ID:?set in .env}"
GRAPH_APPID="00000003-0000-0000-c000-000000000000"
APP_SP_ID="$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)"
GRAPH_SP_ID="$(az ad sp list --filter "appId eq '$GRAPH_APPID'" --query "[0].id" -o tsv)"
REQUIRED_VALUES='["Calls.AccessMedia.All","Calls.Initiate.All","Calls.InitiateGroupCall.All","Calls.JoinGroupCall.All","Calls.JoinGroupCallAsGuest.All"]'
GRAPH_ROLES="$(az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/${GRAPH_SP_ID}/appRoles")"
ROLE_MAP="$(jq --argjson want "$REQUIRED_VALUES" '.value|map(select(.value as $v|$want|index($v)!=null))|map({value,id})' <<<"$GRAPH_ROLES")"
EXISTING="$(az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/${APP_SP_ID}/appRoleAssignments")"
for row in $(jq -c '.[]' <<<"$ROLE_MAP"); do
  ROLE_VAL="$(jq -r '.value' <<<"$row")"; ROLE_ID="$(jq -r '.id' <<<"$row")"
  already="$(jq -r --arg rid "$GRAPH_SP_ID" --arg appRoleId "$ROLE_ID" '.value[]? | select(.resourceId==$rid and .appRoleId==$appRoleId)' <<<"$EXISTING" | wc -l | tr -d ' ')"
  [[ "$already" -gt 0 ]] && echo "SKIP $ROLE_VAL" || az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/${APP_SP_ID}/appRoleAssignments" --body "{\"principalId\":\"${APP_SP_ID}\",\"resourceId\":\"${GRAPH_SP_ID}\",\"appRoleId\":\"${ROLE_ID}\"}" -o none
done
echo "Done."
