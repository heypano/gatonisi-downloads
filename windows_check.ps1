# The Windows check of Gatonisi's desktop build (docs/windows-check.md): run on a real Windows PC, it gets the exe
# (from the download page's link, or the one given), checks it against the published manifest, and runs the exe's own
# self-check headless (pano-game-kit's godot/pano_self_check.gd: the boot loader, a fake update served from a local
# server inside the exe, the download, a damaged one refused, the download page for a new exe, a second process booting
# into the update, the restart the game's button does, the saves untouched), then the game's own check of its backups
# (--backup-self-check: the folder in Documents, a backup written, read back and restored, a damaged one refused, all in
# a scratch folder). It prints PASS or FAIL per step and exits 0 when every step passed. Nothing of the player's is touched (the self-check works in its own folder under the
# game's user data and removes it), and nothing is installed.
#   powershell -ExecutionPolicy Bypass -File tools\windows_check.ps1
#   powershell -ExecutionPolicy Bypass -File tools\windows_check.ps1 -Exe C:\Users\me\Downloads\Gatonisi.exe
param(
	[string]$Exe = "",
	[string]$Url = "https://github.com/heypano/gatonisi-downloads/releases/latest/download/Gatonisi.exe",
	[string]$Manifest = "https://gatonisi-web.vercel.app/updates/desktop.json",
	[int]$TimeoutSeconds = 240
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest is much faster without its progress bar
# Windows PowerShell 5.1 may offer only old TLS versions by default; GitHub and Vercel need TLS 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$results = New-Object System.Collections.Generic.List[string]
$failed = $false

function Step([string]$name, [bool]$ok, [string]$why = "") {
	if ($ok) {
		$line = "PASS $name"
	} else {
		$line = "FAIL ${name}: $why"
		$script:failed = $true
	}
	$script:results.Add($line)
	Write-Host $line
}

$work = Join-Path $env:TEMP "gatonisi-windows-check"
New-Item -ItemType Directory -Force -Path $work | Out-Null

# 1. The exe: downloaded from the page's link, or the one given.
$downloaded = ($Exe -eq "")
if ($Exe -eq "") {
	$Exe = Join-Path $work "Gatonisi.exe"
	try {
		Invoke-WebRequest -Uri $Url -OutFile $Exe -UseBasicParsing
		Step "download" (Test-Path $Exe) "nothing at $Exe"
	} catch {
		Step "download" $false "$Url : $($_.Exception.Message)"
	}
} else {
	Step "exe given" (Test-Path $Exe) "no file at $Exe"
}
if (-not (Test-Path $Exe)) {
	Write-Host "RESULT FAIL"
	exit 1
}
$Exe = (Resolve-Path $Exe).Path
$size = (Get-Item $Exe).Length
$hash = (Get-FileHash -Algorithm SHA256 $Exe).Hash.ToLower()
Write-Host "INFO $Exe, $size bytes, sha256 $hash"
Step "one big exe" ($size -gt 50MB) "only $size bytes: not the game with its pack inside"

# 2. The published manifest names this exe (the download page hands out the exe the updates are for). The manifest
# file is {"signed": <the manifest's JSON text>, "signature": ...}; the exe itself checks the signature (the self-check's
# "live" step), here only what it says is read.
$named = $false
try {
	$outer = Invoke-RestMethod -Uri $Manifest -UseBasicParsing
	$m = $outer.signed | ConvertFrom-Json
	$w = $m.windows
	Write-Host "INFO manifest: pack $($w.serial) version $($w.version) ($($w.build)), runtime $($w.runtime), exe $($w.exe.serial)"
	if ($null -eq $w.exe) {
		Step "manifest" $false "the manifest names no exe yet"
	} else {
		$named = ($w.exe.sha256 -eq $hash)
		Step "manifest" $named "the manifest's exe is $($w.exe.sha256), this one $hash (an older download, or the release not uploaded yet)"
	}
} catch {
	Step "manifest" $false "$Manifest : $($_.Exception.Message)"
}

# 3. Windows' mark on a downloaded file (SmartScreen asks about it once, when the exe is opened from Explorer).
$zone = Get-Item -Path $Exe -Stream Zone.Identifier -ErrorAction SilentlyContinue
if ($null -ne $zone) {
	Write-Host "INFO the exe carries the internet's mark: opened from Explorer, SmartScreen asks once (More info, then Run anyway)"
} else {
	Write-Host "INFO the exe carries no internet mark"
}

# An exe downloaded here runs only when the published manifest names it (an exe given with -Exe is the owner's choice).
if ($downloaded -and -not $named) {
	Write-Host "RESULT FAIL (the downloaded exe was not run: the manifest does not name it)"
	exit 1
}

# 4. The exe's own self-check, headless.
$report = Join-Path $work "self-check.txt"
Remove-Item -Force -ErrorAction SilentlyContinue $report
$p = Start-Process -FilePath $Exe -ArgumentList @("--headless", "--", "--pano-self-check", "`"$report`"") -PassThru
$null = $p.Handle   # cached now, or ExitCode comes back empty once the process has ended
if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
	Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
	Step "self-check" $false "still running after $TimeoutSeconds s"
} else {
	if (Test-Path $report) {
		foreach ($line in Get-Content $report) {
			Write-Host "    $line"
		}
		$text = Get-Content -Raw $report
		Step "self-check" (($p.ExitCode -eq 0) -and ($text -match "RESULT PASS")) "exit $($p.ExitCode); see the lines above"
	} else {
		Step "self-check" $false "exit $($p.ExitCode) and no report at $report (an old exe without the self-check?)"
	}
}

# 5. The backups' own check, headless (scripts/backups.gd, Backups.self_check): the folder the backups go in (Documents,
# or the game's own folder when Documents cannot be written), a backup of a sample life written, read back, listed and
# restored, a damaged one refused, all in a scratch folder it removes; the player's backups and life untouched.
$breport = Join-Path $work "backup-check.txt"
Remove-Item -Force -ErrorAction SilentlyContinue $breport
$b = Start-Process -FilePath $Exe -ArgumentList @("--headless", "--", "--backup-self-check", "`"$breport`"") -PassThru
$null = $b.Handle   # cached now, or ExitCode comes back empty once the process has ended
if (-not $b.WaitForExit($TimeoutSeconds * 1000)) {
	Stop-Process -Id $b.Id -Force -ErrorAction SilentlyContinue
	Step "backups" $false "still running after $TimeoutSeconds s"
} else {
	if (Test-Path $breport) {
		foreach ($line in Get-Content $breport) {
			Write-Host "    $line"
		}
		$text = Get-Content -Raw $breport
		Step "backups" (($b.ExitCode -eq 0) -and ($text -match "BACKUP SELF-CHECK: PASS")) "exit $($b.ExitCode); see the lines above"
		if ($text -match "\(fallback\)") {
			Write-Host "INFO the backups are not in Documents: Windows would not let the game write there (Controlled folder access?)"
		}
	} else {
		Step "backups" $false "exit $($b.ExitCode) and no report at $breport (an exe from before the backups?)"
	}
}

# 6. The game's own files (the saves and the updates), for the report.
$data = Join-Path $env:APPDATA "Godot\app_userdata\GATONISI"
if (Test-Path $data) {
	Write-Host "INFO the game's data: $data"
	Get-ChildItem -Recurse -File $data | Where-Object { $_.FullName -notmatch "\\logs\\" } | ForEach-Object {
		Write-Host ("    {0}  {1} bytes" -f $_.FullName.Substring($data.Length + 1), $_.Length)
	}
} else {
	Write-Host "INFO no game data yet ($data): the game has not been played on this PC"
}

if ($failed) {
	Write-Host "RESULT FAIL"
	exit 1
}
Write-Host "RESULT PASS"
exit 0
