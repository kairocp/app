# ssl.ps1 - Provision Let's Encrypt cert + bind to 443 + restart MediaBot

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =======================
# CONFIG - EDIT AS NEEDED
# =======================
$domain    = 'kairo-media.westus.cloudapp.azure.com'
$email     = 'root@difalabs.com'
$pfxPass   = 'changeit'                # choose a non-empty password
$taskName  = 'MediaBot'                # Scheduled Task that runs your .NET app
$appIdGuid = '{f543d99f-cf53-4349-9eff-97f3b788971d}'  # stable GUID for netsh binding

$wacsDir = 'C:\media-bot\wacs'
$pfxDir  = 'C:\media-bot\certs'        # directory to hold generated PFX files

Write-Host "== Setting up directories =="

# Clean/create dirs
Remove-Item $wacsDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $wacsDir | Out-Null
New-Item -ItemType Directory -Force -Path $pfxDir  | Out-Null

# Remove any old PFX so we don't accidentally import a stale one
Get-ChildItem -Path $pfxDir -Filter '*.pfx' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# ==========================
# Download & unpack WACS
# ==========================
Write-Host "== Downloading WACS ACME client =="

$zip = Join-Path $wacsDir 'wacs.zip'
Invoke-WebRequest -UseBasicParsing -Headers @{ 'User-Agent'='Mozilla/5.0' } `
  -Uri 'https://github.com/simple-acme/simple-acme/releases/download/v2.3.4.1/simple-acme.v2.3.4.2084.win-x64.pluggable.zip' `
  -OutFile $zip

Expand-Archive -Path $zip -DestinationPath $wacsDir -Force

$wacs = Get-ChildItem $wacsDir -Filter 'wacs.exe' -Recurse | Select-Object -First 1
if (-not $wacs) {
    Get-ChildItem $wacsDir -Recurse | Select-Object FullName
    throw 'wacs.exe not found'
}

# ==========================
# Run WACS to get LE cert
# ==========================
Write-Host "== Requesting Let's Encrypt certificate for $domain =="

Push-Location $wacsDir

$arguments = @(
  '--target',      'manual',
  '--host',        $domain,
  '--validation',  'selfhosting',
  '--store',       'pfxfile',
  '--pfxfilepath', $pfxDir,       # MUST be a directory, not a file path
  '--pfxpassword', $pfxPass,
  '--installation','none',
  '--accepttos',
  '--emailaddress',$email
)

& $wacs.FullName @arguments
Pop-Location

# ==========================
# Locate generated PFX
# ==========================
Write-Host "== Locating generated PFX in $pfxDir =="

$pfxFile = Get-ChildItem -Path $pfxDir -Filter '*.pfx' |
           Sort-Object LastWriteTime -Descending |
           Select-Object -First 1

if (-not $pfxFile) {
    throw "No PFX generated in $pfxDir"
}

$pfxImportPath = $pfxFile.FullName
Write-Host "Found PFX: $pfxImportPath"

# ==========================
# Import cert + bind via netsh
# ==========================
Write-Host "== Importing PFX into LocalMachine\My =="

$securePw = ConvertTo-SecureString $pfxPass -AsPlainText -Force
$cert = Import-PfxCertificate -FilePath $pfxImportPath -Password $securePw -CertStoreLocation Cert:\LocalMachine\My

$thumb = $cert.Thumbprint
Write-Host "Imported cert thumbprint: $thumb"

Write-Host "== Binding cert to http.sys on 0.0.0.0:443 =="

netsh http delete sslcert ipport=0.0.0.0:443 2>$null | Out-Null
netsh http add sslcert ipport=0.0.0.0:443 certhash=$thumb appid=$appIdGuid certstorename=MY

# ==========================
# Set ASP.NET Core env vars
# ==========================
Write-Host "== Setting ASP.NET Core Kestrel environment variables =="

[Environment]::SetEnvironmentVariable('ASPNETCORE_Kestrel__Certificates__Default__Path', $pfxImportPath, 'Machine')
[Environment]::SetEnvironmentVariable('ASPNETCORE_Kestrel__Certificates__Default__Password', $pfxPass, 'Machine')
[Environment]::SetEnvironmentVariable('ASPNETCORE_URLS','https://0.0.0.0:443','Machine')

# ==========================
# Restart MediaBot task
# ==========================
Write-Host "== Restarting scheduled task: $taskName =="

try {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
} catch {
    Write-Host "Warning: failed to stop task $taskName. $_"
}
Start-Sleep -Seconds 3

try {
    Start-ScheduledTask -TaskName $taskName
} catch {
    Write-Host "Error: failed to start task $taskName. $_"
}

try {
    Get-ScheduledTaskInfo -TaskName $taskName | Format-List *
} catch {
    Write-Host "Warning: could not read task info for $taskName"
}

# ==========================
# Debug info
# ==========================
Write-Host "== netsh SSL binding state =="
netsh http show sslcert ipport=0.0.0.0:443

Write-Host "== Testing 127.0.0.1:443 connectivity =="
Test-NetConnection -ComputerName 127.0.0.1 -Port 443
