<#
pack-and-upload-teams.ps1
Packages the Teams app (manifest + icons) and uploads it to the tenant catalog from the Windows VM.
Inputs are pulled from parameters or the .env alongside this script.
Requires: PowerShell 5+, MicrosoftTeams module. Azure CLI not required if you pass AppHost/MediaFqdn.

Examples:
  .\pack-and-upload-teams.ps1
  .\pack-and-upload-teams.ps1 -ManifestId (New-Guid)        # use new app id to avoid catalog collision
  .\pack-and-upload-teams.ps1 -Update -TargetAppId "<old>"  # update existing catalog app
#>
param(
  [string]$ManifestId,
  [string]$BotId,
  [string]$AppHost,
  [string]$MediaFqdn,
  [string]$ResourceId,
  [string]$EnvPath,
  [switch]$Update,
  [string]$TargetAppId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Load-DotEnv {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return @{} }
  $vars = @{}
  Get-Content $Path | ForEach-Object {
    if ($_ -match '^\s*#') { return }
    if ($_ -match '^\s*$') { return }
    if ($_ -match '^\s*([^=]+)=(.*)$') {
      $k = $matches[1].Trim()
      $v = $matches[2].Trim()
      $v = $v.Trim('"')
      $vars[$k] = $v
    }
  }
  return $vars
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir   = Split-Path -Parent $scriptDir
$envFile   = $EnvPath
if (-not $envFile) { $envFile = Join-Path $scriptDir ".env" }
if (-not (Test-Path $envFile)) { $envFile = Join-Path (Get-Location) ".env" }
$envVars = Load-DotEnv -Path $envFile

function Get-EnvOrDefault { param($name,$fallback) if ($PSBoundParameters.ContainsKey($name)) { return $PSBoundParameters[$name] } if ($envVars.ContainsKey($name)) { return $envVars[$name] } return $fallback }

$BotId     = Get-EnvOrDefault -name "BotId"     -fallback $BotId
$ManifestId= Get-EnvOrDefault -name "ManifestId"-fallback $ManifestId
$AppHost   = Get-EnvOrDefault -name "AppHost"   -fallback $AppHost
$MediaFqdn = Get-EnvOrDefault -name "MediaFqdn" -fallback $MediaFqdn
$ResourceId= Get-EnvOrDefault -name "ResourceId"-fallback $ResourceId

if (-not $BotId -and $envVars.ContainsKey("APP_ID")) { $BotId = $envVars["APP_ID"] }
if (-not $ManifestId -and $envVars.ContainsKey("MANIFEST_ID") -and $envVars["MANIFEST_ID"]) { $ManifestId = $envVars["MANIFEST_ID"] }
if (-not $ManifestId) { $ManifestId = $BotId }
if (-not $ResourceId) { $ResourceId = $BotId }

if (-not $BotId)     { throw "BotId/APP_ID not provided." }
if (-not $ManifestId){ throw "ManifestId not provided." }
if (-not $AppHost)   { throw "AppHost not provided (set APP_HOST in env or pass -AppHost)." }
if (-not $MediaFqdn) { throw "MediaFqdn not provided (set MEDIA_FQDN in env or pass -MediaFqdn)." }

$manifestDir = Join-Path $rootDir "media-bot/bot-calling-meeting/csharp/Source/CallingBotSample/AppManifest"
$outDir      = Join-Path $scriptDir "dist"
$outManifest = Join-Path $outDir "manifest.json"
$outZip      = Join-Path $outDir "teams-app.zip"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

if (-not (Test-Path "$manifestDir/manifest.json")) { throw "manifest.json not found at $manifestDir" }
if (-not (Test-Path "$manifestDir/color.png")) { throw "color.png not found at $manifestDir" }
if (-not (Test-Path "$manifestDir/outline.png")) { throw "outline.png not found at $manifestDir" }

$manifest = Get-Content "$manifestDir/manifest.json" -Raw | ConvertFrom-Json
$manifest.id = $ManifestId
$manifest.bots[0].botId = $BotId
$manifest.validDomains = @($AppHost, $MediaFqdn)
if ($manifest.webApplicationInfo) {
  $manifest.webApplicationInfo.id = $ResourceId
}
$manifest | ConvertTo-Json -Depth 50 | Set-Content -Encoding UTF8 $outManifest

Copy-Item "$manifestDir/color.png" $outDir -Force
Copy-Item "$manifestDir/outline.png" $outDir -Force
if (Test-Path $outZip) { Remove-Item $outZip -Force }
Compress-Archive -Path "$outDir/manifest.json","$outDir/color.png","$outDir/outline.png" -DestinationPath $outZip

Write-Host "ManifestId: $ManifestId"
Write-Host "BotId:      $BotId"
Write-Host "AppHost:    $AppHost"
Write-Host "MediaFqdn:  $MediaFqdn"
Write-Host "ZIP:        $outZip"

if (-not (Get-Module -ListAvailable -Name MicrosoftTeams)) {
  Write-Host "Installing MicrosoftTeams module..."
  Install-Module MicrosoftTeams -Scope CurrentUser -Force -AllowClobber
}

Import-Module MicrosoftTeams -ErrorAction Stop
Write-Host "Connecting to Microsoft Teams..."
Connect-MicrosoftTeams | Out-Null

if ($Update) {
  if (-not $TargetAppId) { $TargetAppId = $ManifestId }
  Write-Host "Updating existing Teams app $TargetAppId ..."
  Update-TeamsApp -AppId $TargetAppId -Path $outZip
} else {
  Write-Host "Creating new org app..."
  New-TeamsApp -DistributionMethod organization -Path $outZip
}

Write-Host "Done. Uploaded package: $outZip"
