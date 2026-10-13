<#
  JarPilot for IBM i — Windows launcher (jarpilot) v1.1.0
  Uploads a JAR to the IBM i IFS (optional) and runs jarpilot.sh over SSH.
  Requires Windows OpenSSH client (ssh/scp) — built into Windows 10/11.

  Examples:
    # Upload from PC + install
    .\jarpilot.ps1 -IbmiHost myibmi -User DEV -Jar C:\build\app.jar -Target /apps/lib

    # JAR already on IFS -> only install
    .\jarpilot.ps1 -IbmiHost myibmi -User DEV -IfsJar /home/dev/app.jar -Target /apps/lib

    # Rollback / status
    .\jarpilot.ps1 -IbmiHost myibmi -User DEV -Action rollback -Target /apps/lib -Name app.jar
    .\jarpilot.ps1 -IbmiHost myibmi -User DEV -Action status   -Target /apps/lib

    # Server setup from a server setup JAR: upload + guided Steps 3-9
    # (asks in the terminal, refuses a library / directory / instance / port already in use)
    .\jarpilot.ps1 -IbmiHost myibmi -User QSECOFR -Action server-setup -Jar C:\dl\setup-server.jar
    .\jarpilot.ps1 -IbmiHost myibmi -User QSECOFR -Action server-start -Lib MYLIB -Instance MYSRV -StartCmd "STRMYSVR INSTANCE(&INSTANCE)"
    .\jarpilot.ps1 -IbmiHost myibmi -User QSECOFR -Action server-check -HttpPort 5257

  A profile file (jarpilot.config.json next to this script) can hold defaults.
#>
[CmdletBinding()]
param(
  [string]$IbmiHost,
  [string]$User,
  [int]   $Port = 22,
  [string]$KeyFile,
  [ValidateSet('install','rollback','status','server-setup','server-start','server-check')][string]$Action = 'install',
  [string]$Jar,                 # local PC path (upload mode)
  [string]$IfsJar,              # JAR already on IFS (no upload)
  [string]$Target,
  [string]$Name,
  [string]$Owner,
  [string]$PublicAut = '*RX',
  [int]   $Keep = 5,
  [string]$Restart,
  [string]$Staging = '/tmp/jarpilot',
  [switch]$DryRun,
  # ---- server-setup / server-start / server-check (empty = asked on IBM i) ----
  [string]$InstallDir,
  [string]$Lib,
  [string]$Iasp,
  [string]$Instance,
  [int]   $HttpPort,
  [int]   $HttpsPort,
  [string]$JobUser,
  [string]$JobqLib,
  [string]$Jobq,
  [string]$StartCmd,            # CL that starts the server, &INSTANCE is replaced
  [switch]$Manual,              # you answer the vendor installer yourself
  [switch]$Yes,                 # no questions: use parameters/defaults, fail on conflict
  [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- load defaults from config ------------------------------------------------
$cfgFile = Join-Path $here 'jarpilot.config.json'
if (Test-Path $cfgFile) {
  $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
  foreach ($p in 'IbmiHost','User','Port','KeyFile','Target','Owner','PublicAut','Keep','Restart','Staging') {
    if (-not $PSBoundParameters.ContainsKey($p) -and $cfg.$p) { Set-Variable -Name $p -Value $cfg.$p }
  }
}
$isServer = $Action -like 'server-*'
if (-not $IbmiHost -or -not $User) { throw 'IbmiHost and User are required (parameter or jarpilot.config.json).' }
if (-not $isServer -and -not $Target) { throw 'Target is required (parameter or jarpilot.config.json).' }

$sshArgs = @('-p', $Port, '-o', 'BatchMode=no')
$scpArgs = @('-P', $Port)
if ($KeyFile) { $sshArgs += @('-i', $KeyFile); $scpArgs += @('-i', $KeyFile) }
$remote = "$User@$IbmiHost"

function Q([string]$s) { "'" + ($s -replace "'", "'\''") + "'" }   # quote for remote sh

Write-Host "== JarPilot -> $remote ($Action)" -ForegroundColor Cyan

# ---- 1. stage installer + JAR on IFS --------------------------------------------
& ssh @sshArgs $remote "mkdir -p $(Q $Staging)"
& scp @scpArgs (Join-Path $here 'jarpilot.sh') "${remote}:$Staging/jarpilot.sh"
if ($LASTEXITCODE) { throw 'Upload of jarpilot.sh failed' }

$remoteJar = $IfsJar
$sha = $null
if ($Action -in 'install','server-setup') {
  if ($Jar) {
    if (-not (Test-Path $Jar)) { throw "Local JAR not found: $Jar" }
    $sha = (Get-FileHash $Jar -Algorithm SHA256).Hash.ToLower()
    $remoteJar = "$Staging/" + (Split-Path $Jar -Leaf)
    Write-Host "Uploading $Jar ($sha)"
    & scp @scpArgs $Jar "${remote}:$remoteJar"
    if ($LASTEXITCODE) { throw 'JAR upload failed' }
  }
  if (-not $remoteJar) { throw 'Give -Jar (local file to upload) or -IfsJar (file already on IFS).' }
}

# ---- 2a. server actions (guided setup needs an interactive terminal: ssh -t) ------
if ($isServer) {
  $cmd = "/QOpenSys/usr/bin/sh $(Q "$Staging/jarpilot.sh") $Action --host $(Q $IbmiHost)"
  if ($remoteJar)  { $cmd += " --jar $(Q $remoteJar)" }
  if ($InstallDir) { $cmd += " --install-dir $(Q $InstallDir)" }
  if ($Lib)        { $cmd += " --lib $(Q $Lib)" }
  if ($Iasp)       { $cmd += " --iasp $(Q $Iasp)" }
  if ($Instance)   { $cmd += " --instance $(Q $Instance)" }
  if ($HttpPort)   { $cmd += " --http-port $HttpPort" }
  if ($HttpsPort)  { $cmd += " --https-port $HttpsPort" }
  if ($JobUser)    { $cmd += " --job-user $(Q $JobUser)" }
  if ($JobqLib)    { $cmd += " --jobq-lib $(Q $JobqLib)" }
  if ($Jobq)       { $cmd += " --jobq $(Q $Jobq)" }
  if ($StartCmd)   { $cmd += " --start-cmd $(Q $StartCmd)" }
  if ($Manual)     { $cmd += ' --manual' }
  if ($Yes)        { $cmd += ' --yes' }
  if ($NoStart)    { $cmd += ' --no-start' }
  if ($DryRun)     { $cmd += ' --dry-run' }
  & ssh -t @sshArgs $remote $cmd
  $rc = $LASTEXITCODE
  if ($rc) {
    $why = @{ 7 = 'conflict: library / directory / instance / port already used'; 8 = 'vendor installer failed'; 9 = 'server did not start' }[$rc]
    Write-Host "JarPilot $Action FAILED (rc=$rc) $why" -ForegroundColor Red; exit $rc
  }
  if (-not $DryRun -and -not $NoStart -and $Action -ne 'server-check') {
    $p = if ($HttpPort) { $HttpPort } else { 5257 }
    $url = "http://${IbmiHost}:$p/about"
    try { $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20; Write-Host "$url -> HTTP $($r.StatusCode)" -ForegroundColor Green }
    catch { Write-Host "Could not reach $url from this PC (firewall / port changed?). Check it in a browser." -ForegroundColor Yellow }
  }
  Write-Host "JarPilot $Action completed." -ForegroundColor Green
  exit 0
}

# ---- 2. run installer -----------------------------------------------------------
$cmd = "/QOpenSys/usr/bin/sh $(Q "$Staging/jarpilot.sh") $Action --target $(Q $Target)"
if ($remoteJar) { $cmd += " --jar $(Q $remoteJar)" }
if ($Name)      { $cmd += " --name $(Q $Name)" }
if ($Owner)     { $cmd += " --owner $(Q $Owner)" }
if ($Action -eq 'install') { $cmd += " --public-aut $(Q $PublicAut) --keep $Keep" }
if ($sha)       { $cmd += " --sha256 $sha" }
if ($Restart)   { $cmd += " --restart $(Q $Restart)" }
if ($DryRun)    { $cmd += ' --dry-run' }

& ssh @sshArgs $remote $cmd
$rc = $LASTEXITCODE
if ($Jar -and $Action -eq 'install' -and -not $DryRun) { & ssh @sshArgs $remote "rm -f $(Q $remoteJar)" | Out-Null }
if ($rc) { Write-Host "JarPilot FAILED (rc=$rc)" -ForegroundColor Red; exit $rc }
Write-Host 'JarPilot completed successfully.' -ForegroundColor Green
