# ssl.ps1 - Provision Let's Encrypt cert + bind to 443 + restart MediaBot

param(
  [string]$Domain,
  [string]$Email,
  [string]$PfxPass,
  [string]$AppId,
  [string]$TaskName = "MediaBot"
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$wacsDir = 'C:\media-bot\wacs'
$pfxDir  = 'C:\media-bot\certs'        # directory to hold generated PFX files

Write-Host "Domain: $Domain"
Write-Host "Email:  $Email"
Write-Host "Task:   $TaskName"

Remove-Item $wacsDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $wacsDir | Out-Null
New-Item -ItemType Directory -Force -Path $pfxDir  | Out-Null
Get-ChildItem -Path $pfxDir -Filter '*.pfx' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "== Downloading WACS ACME client =="
$zip = Join-Path $wacsDir 'wacs.zip'
Invoke-WebRequest -UseBasicParsing -Headers @{ 'User-Agent'='Mozilla/5.0' } `
  -Uri 'https://github.com/simple-acme/simple-acme/releases/download/v2.3.4.1/simple-acme.v2.3.4.2084.win-x64.pluggable.zip' `
  -OutFile $zip

Expand-Archive -Path $zip -DestinationPath $wacsDir -Force
$wacs = Get-ChildItem $wacsDir -Filter 'wacs.exe' -Recurse | Select-Object -First 1
if (-not $wacs) { throw 'wacs.exe not found' }

Write-Host "== Requesting Let's Encrypt certificate for $Domain =="
Push-Location $wacsDir
$arguments = @(
  '--target','manual',
  '--host',$Domain,
  '--validation','selfhosting',
  '--store','pfxfile',
  '--pfxfilepath',$pfxDir,
  '--pfxpassword',$PfxPass,
  '--installation','none',
  '--accepttos',
  '--emailaddress',$Email
)
& $wacs.FullName @arguments
Pop-Location

$pfxFile = Get-ChildItem -Path $pfxDir -Filter '*.pfx' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $pfxFile) { throw "No PFX generated in $pfxDir" }

$securePw = ConvertTo-SecureString $PfxPass -AsPlainText -Force
$cert = Import-PfxCertificate -FilePath $pfxFile.FullName -Password $securePw -CertStoreLocation Cert:\LocalMachine\My
$thumb = $cert.Thumbprint

Write-Host "Binding thumbprint $thumb to 0.0.0.0:443"
if ($AppId -notmatch '^{.*}$') { $AppId = "{${AppId}}"}
netsh http delete sslcert ipport=0.0.0.0:443 2>$null | Out-Null
netsh http add sslcert ipport=0.0.0.0:443 certhash=$thumb appid=$AppId certstorename=MY

[Environment]::SetEnvironmentVariable('ASPNETCORE_Kestrel__Certificates__Default__Path', $pfxFile.FullName, 'Machine')
[Environment]::SetEnvironmentVariable('ASPNETCORE_Kestrel__Certificates__Default__Password', $PfxPass, 'Machine')
[Environment]::SetEnvironmentVariable('ASPNETCORE_URLS','https://0.0.0.0:443','Machine')

try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Seconds 3
Start-ScheduledTask -TaskName $TaskName

netsh http show sslcert ipport=0.0.0.0:443
Test-NetConnection -ComputerName 127.0.0.1 -Port 443
