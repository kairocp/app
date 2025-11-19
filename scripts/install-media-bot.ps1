param(
  [string]$RepoUrl,
  [string]$Branch,
  [string]$ProjectPath,
  [string]$InstallDir = "C:\media-bot",
  [string]$AppHost,
  [string]$InternalToken,
  [string]$OrgDefault,
  [string]$TenantId,
  [string]$AppId,
  [string]$AppSecret,
  [string]$SpeechKey,
  [string]$SpeechRegion,
  [string]$MediaFqdn,
  [string]$MediaPortStart,
  [string]$MediaPortEnd,
  [string]$MediaSigPort,
  [string]$AcsConnectionString = ""
)

Write-Host "Installing media bot from repo $RepoUrl (branch $Branch) into $InstallDir"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$env:Path += ";C:\Program Files\Git\bin;C:\Program Files\dotnet"
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# Install .NET 8 SDK via dotnet-install (portable, avoids download flakiness)
$dotnetDir = "$InstallDir\dotnet"
if (-not (Test-Path "$dotnetDir\dotnet.exe")) {
  Write-Host "Installing .NET 8 SDK via dotnet-install..."
  $dotnetInstaller = "$InstallDir\dotnet-install.ps1"
  Invoke-WebRequest -UseBasicParsing -Headers @{"User-Agent"="Mozilla/5.0"} -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile $dotnetInstaller
  if (-not (Test-Path $dotnetInstaller)) { throw "dotnet-install.ps1 download failed" }
  & powershell -ExecutionPolicy Bypass -File $dotnetInstaller -Version 8.0.403 -InstallDir $dotnetDir
}
$env:DOTNET_ROOT = $dotnetDir
$env:Path = "$dotnetDir;" + $env:Path

# Install Git via Chocolatey if not present (refresh PATH for this session)
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
  Write-Host "Installing Chocolatey + Git..."
  Set-ExecutionPolicy Bypass -Scope Process -Force
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
  iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  choco install git -y
  $env:Path += ";C:\Program Files\Git\bin"
}
$git = "C:\Program Files\Git\bin\git.exe"
if (-not (Test-Path $git)) { throw "git not found at $git" }

# Ensure .NET SDK available for publish
$dotnet = "$dotnetDir\dotnet.exe"
if (-not (Test-Path $dotnet)) { throw ".NET SDK not found at $dotnet" }

# Clone or update repo
$repoDir = "$InstallDir\src"
if (-not (Test-Path $repoDir)) {
  & $git clone $RepoUrl $repoDir
} else {
  & $git -C $repoDir fetch origin
}
& $git -C $repoDir checkout $Branch
& $git -C $repoDir pull origin $Branch
$projectPathResolved = Join-Path $repoDir $ProjectPath
if (-not (Test-Path $projectPathResolved)) { throw "Project file not found at $projectPathResolved" }

# Publish the media bot
$publishDir = "$InstallDir\publish"
Write-Host "Publishing media bot project $ProjectPath to $publishDir"
& $dotnet publish $projectPathResolved -c Release -o $publishDir

# Env vars for the bot
[System.Environment]::SetEnvironmentVariable("REASON_URL", "https://$AppHost", "Machine")
[System.Environment]::SetEnvironmentVariable("INTERNAL_TOKEN", $InternalToken, "Machine")
[System.Environment]::SetEnvironmentVariable("ORG_DEFAULT", $OrgDefault, "Machine")
[System.Environment]::SetEnvironmentVariable("AzureAd__Instance", "https://login.microsoftonline.com/", "Machine")
[System.Environment]::SetEnvironmentVariable("AzureAd__TenantId", $TenantId, "Machine")
[System.Environment]::SetEnvironmentVariable("AzureAd__ClientId", $AppId, "Machine")
[System.Environment]::SetEnvironmentVariable("AzureAd__ClientSecret", $AppSecret, "Machine")
[System.Environment]::SetEnvironmentVariable("SPEECH_KEY", $SpeechKey, "Machine")
[System.Environment]::SetEnvironmentVariable("SPEECH_REGION", $SpeechRegion, "Machine")
[System.Environment]::SetEnvironmentVariable("MicrosoftAppId", $AppId, "Machine")
[System.Environment]::SetEnvironmentVariable("MicrosoftAppPassword", $AppSecret, "Machine")
[System.Environment]::SetEnvironmentVariable("TENANT_ID", $TenantId, "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__AppId", $AppId, "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__AppSecret", $AppSecret, "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__BotBaseUrl", "https://$MediaFqdn", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__PlaceCallEndpointUrl", "https://graph.microsoft.com/v1.0", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__GraphApiResourceUrl", "https://graph.microsoft.com", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__MicrosoftLoginUrl", "https://login.microsoftonline.com/", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__RecordingDownloadDirectory", "temp", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__CatalogAppId", $AppId, "Machine")
[System.Environment]::SetEnvironmentVariable("CognitiveServices__Enabled", "true", "Machine")
[System.Environment]::SetEnvironmentVariable("CognitiveServices__SpeechKey", $SpeechKey, "Machine")
[System.Environment]::SetEnvironmentVariable("CognitiveServices__SpeechRegion", $SpeechRegion, "Machine")
[System.Environment]::SetEnvironmentVariable("CognitiveServices__SpeechRecognitionLanguage", "en-US", "Machine")
[System.Environment]::SetEnvironmentVariable("Users__UserIdWithAssignedOnlineMeetingPolicy", "", "Machine")
[System.Environment]::SetEnvironmentVariable("MEDIA_PORT_START", $MediaPortStart, "Machine")
[System.Environment]::SetEnvironmentVariable("MEDIA_PORT_END", $MediaPortEnd, "Machine")
[System.Environment]::SetEnvironmentVariable("MEDIA_SIG_PORT", $MediaSigPort, "Machine")
[System.Environment]::SetEnvironmentVariable("ACS_CONNECTION_STRING", $AcsConnectionString, "Machine")
[System.Environment]::SetEnvironmentVariable("ACS_CALLBACK_URL", "https://$MediaFqdn/api/calling", "Machine")

# Start bot as scheduled task
$exeName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
$exe = Join-Path $publishDir ($exeName + ".exe")
Write-Host "Registering MediaBot scheduled task..."
$action  = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $publishDir
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "MediaBot" -Action $action -Trigger $trigger -RunLevel Highest -User "SYSTEM" -Force | Out-Null

Write-Host "Starting MediaBot process..."
Start-Process $exe -WorkingDirectory $publishDir
