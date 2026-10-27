<# : batch launcher - keep this block first, the PowerShell script follows below
@echo off
setlocal
set "CLEANUP_HOME=%~dp0"
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo %* | findstr /i "DryRun Report" >nul
    if errorlevel 1 (
        echo Requesting administrator rights...
        if "%~1"=="" (
            powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
        ) else (
            powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
        )
        exit /b
    )
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create([IO.File]::ReadAllText('%~f0'))) %*"
echo.
pause
exit /b
---- end of batch launcher ---- #>

<#
  Cleanup-Windows.bat  -  generic Windows disk cleanup, no machine-specific paths.

  Everything is detected at run time: user profiles, staged driver packages, vendor
  update caches, browser / app / dev caches, stale logs, crash dumps. Items that do
  not exist on this machine are silently skipped. Nothing is deleted in -DryRun mode.

  Usage (double-click or from cmd):
    Cleanup-Windows.bat                     standard cleanup (tiers A + B), asks for admin
    Cleanup-Windows.bat -DryRun             preview only, no admin needed
    Cleanup-Windows.bat -Report             write space-report.txt (largest folders/files), no cleanup
    Cleanup-Windows.bat -IncludeOptional    also tier C (VS package cache, OEM driver extracts, ...)
    Cleanup-Windows.bat -SkipDevCaches      keep uv/pip/npm/gradle/etc. caches
    Cleanup-Windows.bat -SkipBrowsers       keep browser and Electron-app caches
    Cleanup-Windows.bat -ResetBase          deeper WinSxS cleanup (updates become non-removable)
    Cleanup-Windows.bat -LimitShadowStorageGB 5
    Cleanup-Windows.bat -DisableHibernation deletes hiberfil.sys (several GB)
    Cleanup-Windows.bat -StaleLogDays 30    age threshold for large *.log deletion (default 30)

  Tiers
    A  always   : stale driver packages (newest of each INF kept, in-use packages are
                  refused by Windows), Windows temp/update/dump/report leftovers,
                  vendor installer caches (NVIDIA, AMD, Lenovo, Dell, Adobe, Chocolatey),
                  superseded NVIDIA Broadcast models, crash dumps, shader caches,
                  rotated/stale large logs, Squirrel/Zoom/Playwright/Claude/Codex
                  superseded versions, Recycle Bin, Delivery Optimization, DISM, Disk Cleanup.
    B  default  : package-manager caches (uv, pip, npm, yarn, pnpm, NuGet, Gradle, Cargo,
                  Go, Composer, electron, Cypress, node-gyp) and browser / Electron-app
                  caches when the app is closed.
    C  optional : Visual Studio package cache, Windows Installer $PatchCache$, OEM driver
                  extraction folders (C:\DRIVERS, C:\Dell, C:\swsetup, C:\SWTOOLS),
                  unused nvm Node versions, Claude Desktop warm VM image, OnVUE.

  Never touched: Program Files, user documents, Docker/WSL disks, HuggingFace models,
  Ollama models, Windows Installer database, antivirus/MDM agents.
#>
param(
    [switch]$DryRun,
    [switch]$Report,
    [switch]$SkipDevCaches,
    [switch]$SkipBrowsers,
    [switch]$IncludeOptional,
    [switch]$ResetBase,
    [switch]$DisableHibernation,
    [int]$LimitShadowStorageGB = 0,
    [int]$StaleLogDays = 30
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$PSDefaultParameterValues = @{ 'Test-Path:ErrorAction' = 'SilentlyContinue'; 'Get-Item:ErrorAction' = 'SilentlyContinue' }

# ------------------------------------------------------------------ setup
$Sys  = $env:SystemDrive                     # e.g. C:
$Win  = $env:SystemRoot                      # e.g. C:\Windows
$PD   = $env:ProgramData
$Home0 = $env:CLEANUP_HOME
if (-not $Home0 -or -not (Test-Path $Home0)) { $Home0 = Join-Path $env:PUBLIC 'Documents' }
$Home0 = $Home0.TrimEnd('\')
$State = @{ Reclaimed = [int64]0; Planned = [int64]0 }
$LogFile = Join-Path $Home0 ('cleanup-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Log {
    param([string]$Msg, [string]$Color = 'Gray')
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Msg
    Write-Host $line -ForegroundColor $Color
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}
function Section { param([string]$T) Log ''; Log ('==== {0} ====' -f $T) 'Cyan' }
function GB { param([int64]$b) return ('{0:N2} GB' -f ($b / 1GB)) }
function Mode { param([string]$Live, [string]$Dry) if ($DryRun) { return $Dry } else { return $Live } }

function Get-Size {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return [int64]0 }
    if (-not $item.PSIsContainer) { return [int64]$item.Length }
    $r = robocopy $Path "$Sys\__nonexistent_dst__" /L /S /NJH /BYTES /NFL /NDL /XJ /R:0 /W:0 2>$null
    $line = ($r | Select-String '^\s*Bytes :').Line
    if ($line) { return [int64](($line -split '\s+' | Where-Object { $_ -match '^\d+$' })[0]) }
    return [int64]0
}

function Remove-Dir {
    # long-path and huge-tree safe delete (mirror an empty dir over it, then remove)
    param([string]$Path)
    $empty = Join-Path $Home0 ('.empty_{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    robocopy $empty $Path /MIR /NFL /NDL /NJH /NJS /R:0 /W:0 | Out-Null
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $empty -Force -ErrorAction SilentlyContinue
}

function Remove-Target {
    param([Parameter(Mandatory)][string]$Path, [string]$Why = '', [switch]$ContentsOnly, [int64]$MinBytes = 1MB)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $size = Get-Size $Path
    if ($size -lt $MinBytes) { return }
    Log ('   {0,-12} {1,11}  {2}  {3}' -f (Mode 'removing' 'WOULD REMOVE'), (GB $size), $Path, $Why) 'White'
    $State.Planned += $size
    if ($DryRun) { return }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer) {
            if ($ContentsOnly) {
                Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.PSIsContainer) { Remove-Dir $_.FullName } else { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                }
            } else { Remove-Dir $Path }
        } else { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        $after = Get-Size $Path
        $State.Reclaimed += ($size - $after)
        if ($after -gt 1MB) { Log ('      partial: {0} still present (in use)' -f (GB $after)) 'Yellow' }
    } catch { Log ('      FAILED: {0}' -f $_.Exception.Message) 'Red' }
}

function Invoke-Tool {
    param([string]$Exe, [string[]]$Arguments, [string]$Why, [switch]$Wait)
    Log ('   {0,-12} {1} {2}   {3}' -f (Mode 'running' 'WOULD RUN'), $Exe, ($Arguments -join ' '), $Why) 'White'
    if ($DryRun) { return }
    try {
        if ($Wait) { Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -WindowStyle Normal }
        else { $out = & $Exe @Arguments 2>&1; $out | Select-Object -Last 4 | ForEach-Object { Log ('      | {0}' -f $_) 'DarkGray' } }
    } catch { Log ('      FAILED: {0}' -f $_.Exception.Message) 'Red' }
}

function Test-Running { param([string[]]$Names) foreach ($n in $Names) { if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true } }; return $false }
function Free-GB { return [math]::Round((Get-PSDrive $Sys.TrimEnd(':')).Free / 1GB, 2) }

function Keep-Newest {
    # Remove all but the newest entry (by version-like name, else by LastWriteTime) in a folder.
    param([string]$Folder, [string]$Pattern = '*', [string]$Why, [switch]$Files)
    if (-not (Test-Path -LiteralPath $Folder)) { return }
    $items = Get-ChildItem -LiteralPath $Folder -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $Pattern }
    if ($Files) { $items = $items | Where-Object { -not $_.PSIsContainer -and $_.Length -gt 0 } } else { $items = $items | Where-Object { $_.PSIsContainer } }
    if (-not $items -or @($items).Count -lt 2) { return }
    $sorted = $items | Sort-Object -Property @{ e = {
        $n = $_.Name -replace '^[^\d]*', '' -replace '[^\d.].*$', ''
        try { [version]($n.Trim('.')) } catch { [version]'0.0' } } }, LastWriteTime -Descending
    $sorted | Select-Object -Skip 1 | ForEach-Object { Remove-Target $_.FullName -Why $Why }
}

function Remove-ElectronCache {
    param([string]$Root, [string[]]$Procs, [string]$Label)
    if (-not (Test-Path -LiteralPath $Root)) { return }
    if ($Procs -and (Test-Running $Procs)) { Log ('   {0} is running - its caches were skipped' -f $Label) 'Yellow'; return }
    foreach ($c in 'Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'GrShaderCache', 'ShaderCache', 'CachedData', 'CachedExtensionVSIXs', 'Service Worker\CacheStorage', 'logs', 'tmp') {
        Remove-Target (Join-Path $Root $c) -ContentsOnly -Why ('{0} cache' -f $Label)
    }
}

# ------------------------------------------------------------------ discovery
$Profiles = Get-ChildItem (Join-Path $Sys 'Users') -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin 'Public', 'Default', 'Default User', 'All Users' -and (Test-Path (Join-Path $_.FullName 'NTUSER.DAT')) }

$freeBefore = Free-GB
Log ('Cleanup-Windows started on {0}  mode={1}  admin={2}' -f $env:COMPUTERNAME, (Mode 'LIVE' 'DRY RUN'), $IsAdmin) 'Cyan'
Log ('System drive {0}: free {1} GB.  Profiles: {2}.  Log: {3}' -f $Sys, $freeBefore, (($Profiles | ForEach-Object Name) -join ', '), $LogFile) 'Cyan'
if (-not $IsAdmin -and -not $DryRun -and -not $Report) { Log 'Not elevated - system-level steps will fail. Run via the .bat so it can elevate.' 'Red' }

# ------------------------------------------------------------------ REPORT mode
if ($Report) {
    $rpt = Join-Path $Home0 'space-report.txt'
    Log ('Writing space report to {0} (this scans the whole drive, be patient)' -f $rpt) 'Cyan'
    $lines = New-Object System.Collections.Generic.List[string]
    function SizeChildren { param([string]$Root, [int]$Top = 25)
        $rows = foreach ($d in (Get-ChildItem $Root -Force -Directory -ErrorAction SilentlyContinue)) { [pscustomobject]@{ GB = [math]::Round((Get-Size $d.FullName) / 1GB, 2); Folder = $d.FullName } }
        $rows | Sort-Object GB -Descending | Select-Object -First $Top | ForEach-Object { '{0,9:N2} GB  {1}' -f $_.GB, $_.Folder }
    }
    $lines.Add(('Space report {0}  {1}  free {2} GB' -f (Get-Date), $env:COMPUTERNAME, $freeBefore)); $lines.Add('')
    foreach ($root in @("$Sys\", $PD, "$Sys\Program Files", "$Sys\Program Files (x86)", $Win)) {
        $lines.Add('--- ' + $root); SizeChildren $root | ForEach-Object { $lines.Add($_) }; $lines.Add('')
    }
    foreach ($p in $Profiles) {
        foreach ($sub in '', 'AppData\Local', 'AppData\Roaming') {
            $root = Join-Path $p.FullName $sub; $lines.Add('--- ' + $root); SizeChildren $root 30 | ForEach-Object { $lines.Add($_) }; $lines.Add('')
        }
    }
    $lines.Add('--- largest 50 files on ' + $Sys)
    Get-ChildItem "$Sys\" -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 50 |
        ForEach-Object { $lines.Add(('{0,9:N2} GB  {1}  {2}' -f ($_.Length / 1GB), $_.LastWriteTime.ToString('yyyy-MM-dd'), $_.FullName)) }
    foreach ($f in 'pagefile.sys', 'hiberfil.sys', 'swapfile.sys') { $fi = Get-Item "$Sys\$f" -Force -ErrorAction SilentlyContinue; if ($fi) { $lines.Add(('{0,9:N2} GB  {1}' -f ($fi.Length / 1GB), $fi.FullName)) } }
    $lines | Out-File $rpt -Encoding UTF8
    $lines | Select-Object -First 60 | ForEach-Object { Log $_ }
    Log ('Full report: {0}' -f $rpt) 'Green'
    return
}

# ================================================================== TIER A
Section 'A1  Stale driver packages (keeps newest version of each INF)'
$raw = pnputil /enum-drivers 2>$null
if ($raw) {
    $blocks = ($raw -join "`n") -split "`n(?=Published Name)"
    $drivers = foreach ($b in $blocks) {
        if ($b -notmatch 'Published Name:\s*(\S+)') { continue }
        $pub = $Matches[1]
        $orig = ''; if ($b -match 'Original Name:\s*(\S+)') { $orig = $Matches[1] }
        $verText = ''; if ($b -match 'Driver Version:\s*(.+)') { $verText = $Matches[1].Trim() }
        $date = [datetime]::MinValue; $ver = [version]'0.0'
        if ($verText -match '^(\d{2}/\d{2}/\d{4})\s+(\S+)') {
            try { $date = [datetime]::ParseExact($Matches[1], 'MM/dd/yyyy', [cultureinfo]::InvariantCulture) } catch {}
            try { $ver = [version]$Matches[2] } catch {}
        }
        [pscustomobject]@{ Pub = $pub; Orig = $orig; Ver = $ver; Date = $date; Text = $verText }
    }
    $repo = Join-Path $Win 'System32\DriverStore\FileRepository'
    $est = [int64]0; $n = 0
    foreach ($g in ($drivers | Where-Object Orig | Group-Object Orig | Where-Object Count -gt 1)) {
        $sorted = $g.Group | Sort-Object Ver, Date -Descending
        $keep = $sorted[0]
        foreach ($old in ($sorted | Select-Object -Skip 1)) {
            $sz = [int64]0
            $pubInf = Join-Path $Win ('INF\' + $old.Pub)
            if (Test-Path $pubInf) {
                $h = (Get-FileHash -LiteralPath $pubInf -Algorithm MD5).Hash
                $folder = Get-ChildItem $repo -Directory -Filter ($g.Name + '_*') -ErrorAction SilentlyContinue | Where-Object {
                    $inf = Join-Path $_.FullName $g.Name
                    (Test-Path $inf) -and ((Get-FileHash -LiteralPath $inf -Algorithm MD5).Hash -eq $h) } | Select-Object -First 1
                if ($folder) { $sz = Get-Size $folder.FullName }
            }
            $est += $sz; $n++
            Log ('   {0,-12} {1,11}  {2} ({3} {4})  keep {5} {6}' -f (Mode 'deleting' 'WOULD DELETE'), (GB $sz), $old.Pub, $g.Name, $old.Text, $keep.Pub, $keep.Text) 'White'
            if (-not $DryRun) {
                $out = pnputil /delete-driver $old.Pub 2>&1
                if (($out | Out-String) -match 'successfully') { $State.Reclaimed += $sz } else { Log ('      refused (in use): {0}' -f $old.Pub) 'Yellow' }
            }
        }
    }
    $State.Planned += $est
    Log ('   {0} superseded packages, about {1}' -f $n, (GB $est)) 'Cyan'
} else { Log '   pnputil not available' 'DarkGray' }

Section 'A2  Windows leftovers'
Remove-Target (Join-Path $Win 'Temp') -ContentsOnly -Why 'Windows temp'
if (-not $DryRun -and $IsAdmin) { Stop-Service wuauserv -Force -ErrorAction SilentlyContinue; Stop-Service bits -Force -ErrorAction SilentlyContinue }
Remove-Target (Join-Path $Win 'SoftwareDistribution\Download') -ContentsOnly -Why 'downloaded Windows Update payloads'
if (-not $DryRun -and $IsAdmin) { Start-Service bits -ErrorAction SilentlyContinue; Start-Service wuauserv -ErrorAction SilentlyContinue }
Remove-Target (Join-Path $Win 'MEMORY.DMP') -Why 'kernel memory dump'
Remove-Target (Join-Path $Win 'Minidump') -ContentsOnly -Why 'minidumps'
Remove-Target (Join-Path $Win 'LiveKernelReports') -ContentsOnly -Why 'live kernel reports'
Get-ChildItem (Join-Path $Win 'Logs\CBS') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^CbsPersist.*\.(cab|log)$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | ForEach-Object { Remove-Target $_.FullName -Why 'archived CBS log' }
Remove-Target (Join-Path $PD 'Microsoft\Windows\WER\ReportQueue') -ContentsOnly -Why 'queued error reports'
Remove-Target (Join-Path $PD 'Microsoft\Windows\WER\ReportArchive') -ContentsOnly -Why 'archived error reports'
Remove-Target (Join-Path $PD 'Microsoft\Windows\WER\Temp') -ContentsOnly -Why 'WER temp'
Remove-Target (Join-Path $Sys '\$WINDOWS.~WS') -Why 'Windows setup work files'
Remove-Target (Join-Path $Sys 'ESD') -Why 'downloaded Windows setup media'

Section 'A3  Vendor installer / update caches (only those present)'
$vendor = @(
    @{ P = "$PD\NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts"; W = 'NVIDIA App downloaded installers' },
    @{ P = "$PD\NVIDIA Corporation\Downloader";                                 W = 'GeForce Experience downloads' },
    @{ P = "$PD\NVIDIA Corporation\NV_Cache";                                   W = 'NVIDIA shader cache' },
    @{ P = "$Sys\NVIDIA";                                                       W = 'extracted NVIDIA driver installers' },
    @{ P = "$Sys\AMD";                                                          W = 'extracted AMD driver installers' },
    @{ P = "$PD\Lenovo\Vantage\AddinData\LenovoSystemUpdateAddin\session\Repository"; W = 'Lenovo Vantage update downloads' },
    @{ P = "$PD\Lenovo\SystemUpdate\sessionSE";                                 W = 'Lenovo System Update downloads' },
    @{ P = "$PD\Lenovo\Vantage\Downloads";                                      W = 'Lenovo Vantage downloads' },
    @{ P = "$PD\Dell\UpdateService\Temp";                                       W = 'Dell Update temp' },
    @{ P = "$PD\Dell\SARemediation\SystemRepair\Snapshots";                     W = 'Dell SupportAssist snapshots' },
    @{ P = "$PD\Dell\CommandUpdate\Downloads";                                  W = 'Dell Command Update downloads' },
    @{ P = "$PD\HP\HP Support Framework\Downloads";                             W = 'HP Support downloads' },
    @{ P = "$PD\Adobe\ARM";                                                     W = 'Adobe updater downloads' },
    @{ P = "$PD\ChocolateyHttpCache";                                           W = 'Chocolatey HTTP cache' },
    @{ P = "$PD\chocolatey\logs";                                               W = 'Chocolatey logs' },
    @{ P = "$PD\Microsoft\Windows Defender\Scans\History\Results";              W = 'Defender scan history' },
    @{ P = "$PD\Microsoft\Diagnosis\ETLLogs";                                   W = 'telemetry ETL logs' },
    @{ P = "$PD\USOShared\Logs";                                                W = 'Update Orchestrator logs' }
)
foreach ($v in $vendor) { Remove-Target $v.P -ContentsOnly -Why $v.W }
# NVIDIA Broadcast / NGX models: drop the monolithic set and all but the newest v0_N of each family
$ngx = Join-Path $PD 'NVIDIA\NGX\models'
if (Test-Path $ngx) {
    $fam = Get-ChildItem $ngx -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(nvbcast_.+)_v(\d+)_(\d+)$' } |
        ForEach-Object { [pscustomobject]@{ F = $Matches[1]; V = [version]('{0}.{1}' -f $Matches[2], $Matches[3]); D = $_ } }
    if ($fam) {
        Remove-Target (Join-Path $ngx 'nvbcast') -Why 'legacy Broadcast model set (per-feature sets present)'
        $fam | Group-Object F | ForEach-Object { $_.Group | Sort-Object V -Descending | Select-Object -Skip 1 | ForEach-Object { Remove-Target $_.D.FullName -Why 'superseded Broadcast model' } }
    }
}

Section ('A4  Large stale logs (> 100 MB, untouched for {0} days)' -f $StaleLogDays)
$cut = (Get-Date).AddDays(-$StaleLogDays)
$logRoots = @($PD) + ($Profiles | ForEach-Object { Join-Path $_.FullName 'AppData' })
foreach ($root in $logRoots) {
    Get-ChildItem $root -Recurse -File -Force -Include '*.log', '*.log.*', '*.etl', '*.trace' -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 100MB -and $_.LastWriteTime -lt $cut -and $_.FullName -notmatch '\\winevt\\|\\System32\\' } |
        ForEach-Object { Remove-Target $_.FullName -Why 'stale log' }
}

# ---- per-profile ----
foreach ($p in $Profiles) {
    $U = $p.FullName; $L = Join-Path $U 'AppData\Local'; $R = Join-Path $U 'AppData\Roaming'; $LL = Join-Path $U 'AppData\LocalLow'
    Section ('A5  Profile ' + $p.Name + ': temp, dumps, caches, superseded versions')
    Remove-Target (Join-Path $L 'Temp') -ContentsOnly -Why 'user temp'
    Remove-Target (Join-Path $L 'CrashDumps') -ContentsOnly -Why 'crash dumps'
    Remove-Target (Join-Path $L 'Microsoft\Windows\WER') -ContentsOnly -Why 'user error reports'
    Remove-Target (Join-Path $L 'Microsoft\Windows\INetCache') -ContentsOnly -Why 'IE/WebView cache'
    Remove-Target (Join-Path $L 'Microsoft\Terminal Server Client\Cache') -ContentsOnly -Why 'RDP bitmap cache'
    Remove-Target (Join-Path $L 'D3DSCache') -ContentsOnly -Why 'Direct3D shader cache'
    Remove-Target (Join-Path $L 'NVIDIA\DXCache') -ContentsOnly -Why 'NVIDIA DX shader cache'
    Remove-Target (Join-Path $L 'NVIDIA\GLCache') -ContentsOnly -Why 'NVIDIA GL shader cache'
    Remove-Target (Join-Path $L 'AMD\DxCache') -ContentsOnly -Why 'AMD shader cache'
    Remove-Target (Join-Path $LL 'Intel\ShaderCache') -ContentsOnly -Why 'Intel shader cache'
    Remove-Target (Join-Path $LL 'NVIDIA\PerDriverVersion\DXCache') -ContentsOnly -Why 'NVIDIA per-driver shader cache'
    Remove-Target (Join-Path $L 'SquirrelTemp') -ContentsOnly -Why 'Squirrel installer temp'
    Get-ChildItem $L -Directory -Filter '*-updater' -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem $_.FullName -File -Include '*.exe', '*.nupkg', '*.msi' -Recurse -ErrorAction SilentlyContinue | ForEach-Object { Remove-Target $_.FullName -Why 'already-applied updater payload' } }
    # Squirrel apps (GitHub Desktop, Discord, Teams classic...): keep newest package
    Get-ChildItem $L -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'packages\RELEASES') } | ForEach-Object { Keep-Newest (Join-Path $_.FullName 'packages') '*.nupkg' ('old ' + $_.Name + ' package') -Files }
    # Zoom: version folders that do not match the installed Zoom.exe, plus downloads
    $zexe = Join-Path $R 'Zoom\bin\Zoom.exe'
    if (Test-Path $zexe) {
        $zv = (Get-Item $zexe).VersionInfo.FileVersion -replace '[^\d.]', '' -replace ',', '.'
        Get-ChildItem (Join-Path $R 'Zoom') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+(\.\d+){2,3}$' -and $_.Name -ne $zv -and -not $zv.StartsWith($_.Name) } |
            ForEach-Object { Remove-Target $_.FullName -Why ('old Zoom version (installed ' + $zv + ')') }
    }
    Remove-Target (Join-Path $R 'Zoom\ZoomDownload') -ContentsOnly -Why 'Zoom update downloads'
    # Playwright: keep highest build per family
    $pw = Join-Path $L 'ms-playwright'
    if (Test-Path $pw) {
        Get-ChildItem $pw -Directory | Where-Object { $_.Name -match '^(.+)-(\d+)$' } | ForEach-Object { [pscustomobject]@{ F = $Matches[1]; N = [int]$Matches[2]; D = $_ } } |
            Group-Object F | ForEach-Object { $_.Group | Sort-Object N -Descending | Select-Object -Skip 1 | ForEach-Object { Remove-Target $_.D.FullName -Why ('superseded Playwright ' + $_.F) } }
    }
    # Claude Code / Codex CLI leftovers
    Remove-Target (Join-Path $U '.claude\downloads') -ContentsOnly -Why 'old Claude Code installers'
    Keep-Newest (Join-Path $U '.local\share\claude\versions') '*' 'older Claude Code build' -Files
    Keep-Newest (Join-Path $L 'OpenAI\Codex\bin') '*' 'older Codex build'
    Remove-Target (Join-Path $U '.codex\.tmp') -ContentsOnly -Why 'Codex temp'
    Get-ChildItem (Join-Path $U '.codex\plugins') -Force -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.staging-*' } | ForEach-Object { Remove-Target $_.FullName -Why 'abandoned plugin staging dir' }
    Get-ChildItem (Join-Path $U '.kiro\crew\scratch') -Recurse -File -Filter '*-staged.msi' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Target $_.FullName -Why 'staged installer' }
    Remove-Target (Join-Path $L 'Microsoft\Teams\tmp') -ContentsOnly -Why 'Teams temp'
    Remove-Target (Join-Path $L 'Packages\MSTeams_8wekyb3d8bbwe\TempState') -ContentsOnly -Why 'Teams temp state'

    if (-not $SkipDevCaches) {
        Section ('B1  Profile ' + $p.Name + ': package-manager caches')
        $uv = Join-Path $U '.local\bin\uv.exe'; $uvc = Join-Path $L 'uv\cache'
        if ((Test-Path $uv) -and (Test-Path $uvc) -and -not $DryRun) {
            $sz = Get-Size $uvc; Log ('   {0,-12} {1,11}  {2}  via uv cache clean' -f 'cleaning', (GB $sz), $uvc) 'White'
            $env:UV_CACHE_DIR = $uvc; & $uv cache clean 2>&1 | Out-Null; $State.Reclaimed += ($sz - (Get-Size $uvc)); $State.Planned += $sz
        } else { Remove-Target $uvc -ContentsOnly -Why 'uv cache' }
        $dev = @(
            @{ P = "$L\pip\cache";               W = 'pip cache' },
            @{ P = "$L\npm-cache\_cacache";      W = 'npm cache' },
            @{ P = "$L\npm-cache\_npx";          W = 'npx cache' },
            @{ P = "$L\Yarn\Cache";              W = 'yarn cache' },
            @{ P = "$L\pnpm-cache";              W = 'pnpm metadata cache' },
            @{ P = "$L\electron\Cache";          W = 'electron download cache' },
            @{ P = "$L\electron-builder\Cache";  W = 'electron-builder cache' },
            @{ P = "$L\Cypress\cache";           W = 'Cypress binaries' },
            @{ P = "$L\node-gyp\Cache";          W = 'node-gyp headers' },
            @{ P = "$L\go-build";                W = 'Go build cache' },
            @{ P = "$L\NuGet\v3-cache";          W = 'NuGet HTTP cache' },
            @{ P = "$L\NuGet\http-cache";        W = 'NuGet HTTP cache' },
            @{ P = "$L\Composer\cache";          W = 'Composer cache' },
            @{ P = "$L\Temp\chocolatey";         W = 'Chocolatey temp' },
            @{ P = "$U\.gradle\caches";          W = 'Gradle cache' },
            @{ P = "$U\.cargo\registry\cache";   W = 'Cargo registry cache' },
            @{ P = "$U\go\pkg\mod\cache\download"; W = 'Go module download cache' },
            @{ P = "$U\.nuget\packages\.tools";  W = 'NuGet tool cache' },
            @{ P = "$U\.codex\plugins\cache";    W = 'Codex plugin cache' },
            @{ P = "$U\.kiro\crew\security_events.d"; W = 'Kiro event logs' },
            @{ P = "$U\.cache\pip";              W = 'pip cache' },
            @{ P = "$U\.cache\pre-commit";       W = 'pre-commit cache' },
            @{ P = "$U\.cache\puppeteer";        W = 'puppeteer browsers' },
            @{ P = "$L\pypoetry\Cache";          W = 'Poetry cache' },
            @{ P = "$L\conda\conda\pkgs";        W = 'conda package cache' },
            @{ P = "$U\.conda\pkgs";             W = 'conda package cache' },
            @{ P = "$U\anaconda3\pkgs";          W = 'conda package cache' },
            @{ P = "$U\miniconda3\pkgs";         W = 'conda package cache' }
        )
        foreach ($d in $dev) { Remove-Target $d.P -ContentsOnly -Why $d.W }
    }

    if (-not $SkipBrowsers) {
        Section ('B2  Profile ' + $p.Name + ': browser and app caches (closed apps only)')
        $browsers = @(
            @{ Root = "$L\Google\Chrome\User Data";          Proc = 'chrome';   Label = 'Chrome' },
            @{ Root = "$L\Microsoft\Edge\User Data";         Proc = 'msedge';   Label = 'Edge' },
            @{ Root = "$L\BraveSoftware\Brave-Browser\User Data"; Proc = 'brave'; Label = 'Brave' },
            @{ Root = "$L\Chromium\User Data";               Proc = 'chromium'; Label = 'Chromium' },
            @{ Root = "$L\Vivaldi\User Data";                Proc = 'vivaldi';  Label = 'Vivaldi' },
            @{ Root = "$R\Opera Software\Opera Stable";      Proc = 'opera';    Label = 'Opera' }
        )
        foreach ($b in $browsers) {
            if (-not (Test-Path $b.Root)) { continue }
            if (Test-Running $b.Proc) { Log ('   {0} is running - skipped. Close it and re-run to reclaim its caches.' -f $b.Label) 'Yellow'; continue }
            Get-ChildItem $b.Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -eq 'Guest Profile' } | ForEach-Object {
                foreach ($c in 'Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'GrShaderCache', 'ShaderCache', 'Service Worker\CacheStorage', 'Service Worker\ScriptCache') { Remove-Target (Join-Path $_.FullName $c) -ContentsOnly -Why ($b.Label + ' ' + $_.Name) }
            }
            foreach ($c in 'Snapshots', 'component_crx_cache', 'GrShaderCache', 'ShaderCache', 'GraphiteDawnCache') { Remove-Target (Join-Path $b.Root $c) -ContentsOnly -Why ($b.Label + ' shared cache') }
        }
        $ff = Join-Path $L 'Mozilla\Firefox\Profiles'
        if (Test-Path $ff) { if (Test-Running 'firefox') { Log '   Firefox is running - skipped' 'Yellow' } else { Get-ChildItem $ff -Directory | ForEach-Object { Remove-Target (Join-Path $_.FullName 'cache2') -ContentsOnly -Why 'Firefox cache' } } }
        Remove-ElectronCache "$R\Code"             @('Code')        'VS Code'
        Remove-ElectronCache "$R\Code - Insiders"  @('Code - Insiders') 'VS Code Insiders'
        Remove-ElectronCache "$R\Cursor"           @('Cursor')      'Cursor'
        Remove-ElectronCache "$R\Windsurf"         @('Windsurf')    'Windsurf'
        Remove-ElectronCache "$R\Slack"            @('slack')       'Slack'
        Remove-ElectronCache "$R\discord"          @('Discord')     'Discord'
        Remove-ElectronCache "$R\Postman"          @('Postman')     'Postman'
        Remove-ElectronCache "$R\obsidian"         @('Obsidian')    'Obsidian'
        Remove-ElectronCache "$R\Notion"           @('Notion')      'Notion'
        Remove-ElectronCache "$R\Figma"            @('Figma')       'Figma'
        Remove-ElectronCache "$R\Microsoft\Teams"  @('Teams')       'Teams classic'
        Remove-ElectronCache "$L\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw" @('ms-teams') 'Teams'
        if (-not (Test-Running 'Spotify')) { Remove-Target "$L\Spotify\Storage" -ContentsOnly -Why 'Spotify cache'; Remove-Target "$L\Spotify\Data" -ContentsOnly -Why 'Spotify offline cache' }
    }

    if ($IncludeOptional) {
        Section ('C   Profile ' + $p.Name + ': optional')
        Remove-Target (Join-Path $R 'Claude\vm_bundles\warm') -ContentsOnly -Why 'Claude Desktop warm VM image'
        Remove-Target (Join-Path $R 'OnVUE') -Why 'Pearson VUE exam browser'
        Remove-Target (Join-Path $L 'Microsoft\Office\16.0\OfficeFileCache') -ContentsOnly -Why 'Office upload cache (only when no pending uploads)'
    }
}

Section 'A6  Windows housekeeping'
if ($DryRun) { Log '   WOULD EMPTY   Recycle Bin (all drives)' 'White' } else { try { Clear-RecycleBin -Force -ErrorAction Stop; Log '   emptied Recycle Bin' 'White' } catch {} }
if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
    Log ('   {0,-12} Delivery Optimization cache' -f (Mode 'clearing' 'WOULD CLEAR')) 'White'
    if (-not $DryRun) { try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch {} }
}
$dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup'); if ($ResetBase) { $dismArgs += '/ResetBase' }
Invoke-Tool 'dism.exe' $dismArgs 'component store cleanup (10-20 min)'
$vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
if (-not $DryRun -and $IsAdmin) { Get-ChildItem $vc -ErrorAction SilentlyContinue | ForEach-Object { New-ItemProperty -Path $_.PSPath -Name 'StateFlags0099' -Value 2 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null } }
Invoke-Tool 'cleanmgr.exe' @('/sagerun:99') 'Disk Cleanup, all categories incl. Windows.old and update cleanup' -Wait

# ================================================================== TIER C (system)
if ($IncludeOptional) {
    Section 'C   Optional system items'
    Remove-Target (Join-Path $PD 'Microsoft\VisualStudio\Packages') -ContentsOnly -Why 'VS Installer package cache (re-downloaded on Modify/Repair)'
    Remove-Target (Join-Path $Win 'Installer\$PatchCache$') -ContentsOnly -Why 'MSI baseline patch cache'
    foreach ($d in 'DRIVERS', 'Drivers', 'Dell', 'swsetup', 'SWTOOLS', 'Intel\Logs') { Remove-Target (Join-Path $Sys $d) -ContentsOnly -Why 'OEM driver extraction folder' }
    foreach ($nvmRoot in @("$Sys\nvm", "$env:APPDATA\nvm", $env:NVM_HOME) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique) {
        $current = ''
        try { $t = (Get-Item "$env:ProgramFiles\nodejs" -ErrorAction Stop).Target; if ($t) { $current = Split-Path ($t | Select-Object -First 1) -Leaf } } catch {}
        if (-not $current) { try { $current = (& nvm.exe current 2>$null | Select-Object -First 1).Trim() } catch {} }
        if (-not $current) { try { $current = (& node.exe -v 2>$null | Select-Object -First 1).Trim() } catch {} }
        if ($current -and $current -notmatch '^v\d') { $current = '' }
        if ($current) { Get-ChildItem $nvmRoot -Directory | Where-Object { $_.Name -like 'v*' -and $_.Name -ne $current } | ForEach-Object { Remove-Target $_.FullName -Why ('unused Node (active ' + $current + ')') } }
        else { Log ('   active Node version unknown - {0} left alone' -f $nvmRoot) 'Yellow' }
    }
} else { Section 'C   Optional items skipped (add -IncludeOptional)' }

# ================================================================== system files
Section 'Hibernation / page file / shadow copies'
foreach ($f in 'hiberfil.sys', 'pagefile.sys', 'swapfile.sys') { $fi = Get-Item "$Sys\$f" -Force -ErrorAction SilentlyContinue; if ($fi) { Log ('   {0,11}  {1}' -f (GB $fi.Length), $fi.FullName) 'DarkGray' } }
if ($DisableHibernation) { Invoke-Tool 'powercfg.exe' @('/hibernate', 'off') 'disable hibernation (removes hiberfil.sys)' }
$ss = vssadmin list shadowstorage 2>&1 | Out-String
if ($ss -match 'Used Shadow Copy Storage space:\s*(.+)') { Log ('   shadow copies used: {0}' -f $Matches[1].Trim()) 'DarkGray' }
if ($LimitShadowStorageGB -gt 0) { Invoke-Tool 'vssadmin.exe' @('resize', 'shadowstorage', "/for=$Sys", "/on=$Sys", ('/maxsize={0}GB' -f $LimitShadowStorageGB)) 'cap shadow storage' }

Section 'Reported only (managed software, not touched)'
foreach ($p in "${env:ProgramFiles(x86)}\ManageEngine\UEMS_Agent\patches", "$Sys\AI_RecycleBin", "$PD\McAfee", "$PD\Package Cache", "$PD\Docker", "$L\Docker\wsl") {
    if ($p -and (Test-Path $p)) { Log ('   {0,11}  {1}' -f (GB (Get-Size $p)), $p) 'DarkGray' }
}

# ================================================================== summary
Section 'Summary'
if ($DryRun) { Log ('Would remove about {0} (plus DISM / Disk Cleanup / Recycle Bin).' -f (GB $State.Planned)) 'Green' }
else {
    Log ('Removed about {0}.  Free space {1} GB -> {2} GB' -f (GB $State.Reclaimed), $freeBefore, (Free-GB)) 'Green'
    Log 'DriverStore and WinSxS space is fully released after a reboot.' 'Yellow'
}
Log ('Log: {0}' -f $LogFile) 'Cyan'
