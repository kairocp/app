param(
  [string]$RepoUrl,
  [string]$Branch,
  [string]$ProjectPath,
  [string]$InstallDir = "C:\media-bot"
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
[System.Environment]::SetEnvironmentVariable("REASON_URL", "https://kairo-copilot-web.azurewebsites.net", "Machine")
[System.Environment]::SetEnvironmentVariable("INTERNAL_TOKEN", "dev-internal-token", "Machine")
[System.Environment]::SetEnvironmentVariable("ORG_DEFAULT", "default-org", "Machine")
[System.Environment]::SetEnvironmentVariable("AzureAd__Instance", "https://login.microsoftonline.com/", "Machine")
[System.Environment]::SetEnvironmentVariable("AzureAd__TenantId", "ab7f0af8-50f7-4c55-96ca-f21101e9d438", "Machine")
[System.Environment]::SetEnvironmentVariable("AzureAd__ClientId", "f543d99f-cf53-4349-9eff-97f3b788971d", "Machine")
[System.Environment]::SetEnvironmentVariable("AzureAd__ClientSecret", "CUK8Q~eAhwMIUiOmPqBeo4QypPq9dtVE0NkYBa8n", "Machine")
[System.Environment]::SetEnvironmentVariable("SPEECH_KEY", "7ey6rUCAiIT9Mu8RsVfeB0yaoOvRQa5Ogc0xkIthsOn3f53KBcg9JQQJ99BKAC4f1cMXJ3w3AAAYACOGGFrl", "Machine")
[System.Environment]::SetEnvironmentVariable("SPEECH_REGION", "westus", "Machine")
[System.Environment]::SetEnvironmentVariable("MicrosoftAppId", "f543d99f-cf53-4349-9eff-97f3b788971d", "Machine")
[System.Environment]::SetEnvironmentVariable("MicrosoftAppPassword", "CUK8Q~eAhwMIUiOmPqBeo4QypPq9dtVE0NkYBa8n", "Machine")
[System.Environment]::SetEnvironmentVariable("TENANT_ID", "ab7f0af8-50f7-4c55-96ca-f21101e9d438", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__AppId", "f543d99f-cf53-4349-9eff-97f3b788971d", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__AppSecret", "CUK8Q~eAhwMIUiOmPqBeo4QypPq9dtVE0NkYBa8n", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__BotBaseUrl", "https://kairo-media.westus.cloudapp.azure.com", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__PlaceCallEndpointUrl", "https://graph.microsoft.com/v1.0", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__GraphApiResourceUrl", "https://graph.microsoft.com", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__MicrosoftLoginUrl", "https://login.microsoftonline.com/", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__RecordingDownloadDirectory", "temp", "Machine")
[System.Environment]::SetEnvironmentVariable("Bot__CatalogAppId", "f543d99f-cf53-4349-9eff-97f3b788971d", "Machine")
[System.Environment]::SetEnvironmentVariable("CognitiveServices__Enabled", "true", "Machine")
[System.Environment]::SetEnvironmentVariable("CognitiveServices__SpeechKey", "7ey6rUCAiIT9Mu8RsVfeB0yaoOvRQa5Ogc0xkIthsOn3f53KBcg9JQQJ99BKAC4f1cMXJ3w3AAAYACOGGFrl", "Machine")
[System.Environment]::SetEnvironmentVariable("CognitiveServices__SpeechRegion", "westus", "Machine")
[System.Environment]::SetEnvironmentVariable("CognitiveServices__SpeechRecognitionLanguage", "en-US", "Machine")
[System.Environment]::SetEnvironmentVariable("Users__UserIdWithAssignedOnlineMeetingPolicy", "", "Machine")
[System.Environment]::SetEnvironmentVariable("MEDIA_PORT_START", "50000", "Machine")
[System.Environment]::SetEnvironmentVariable("MEDIA_PORT_END", "50019", "Machine")
[System.Environment]::SetEnvironmentVariable("MEDIA_SIG_PORT", "8445", "Machine")
[System.Environment]::SetEnvironmentVariable("ACS_CONNECTION_STRING", "", "Machine")
[System.Environment]::SetEnvironmentVariable("ACS_CALLBACK_URL", "https://kairo-media.westus.cloudapp.azure.com/api/calling", "Machine")

# Start bot as scheduled task
$exeName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
$exe = Join-Path $publishDir ($exeName + ".exe")
Write-Host "Registering MediaBot scheduled task..."
$action  = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $publishDir
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "MediaBot" -Action $action -Trigger $trigger -RunLevel Highest -User "SYSTEM" -Force | Out-Null

Write-Host "Starting MediaBot process..."
Start-Process $exe -WorkingDirectory $publishDir
