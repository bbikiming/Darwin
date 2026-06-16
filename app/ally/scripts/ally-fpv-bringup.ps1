<#
DARwIn FPV — Ally 온디바이스 브링업 (빌드 → 검증 → 실행)

로봇 + Ally 가 연결됐을 때 한 줄로: git pull → cargo build → 헤드리스 검증 → 콕핏 실행.
플래그 없이 실행하면 안전 기본 묶음(-All: pull+build+selftest+probe+run)을 돈다.
대화형/로봇구동 단계(axis-dump, connect)는 명시 플래그로만.

사용 (Ally PowerShell):
  .\ally-fpv-bringup.ps1                  # = -All (pull+build+selftest+probe+run)
  .\ally-fpv-bringup.ps1 -AxisDump        # 게임패드 축/트리거 현장 보정(스틱 끝까지 움직이며)
  .\ally-fpv-bringup.ps1 -Connect -Seconds 10   # 실로봇 W1 게이트(eff_hz≥19·RTT) — 로봇에 명령 송출
  .\ally-fpv-bringup.ps1 -Build -Run -Wired     # 유선(192.168.123.1) 경로로 빌드+실행
  .\ally-fpv-bringup.ps1 -Release -All          # 릴리스 프로파일

전제: 로봇 walklab-active · Mac DarwinForge 앱 OFF(단일세션) · Ally 게임패드.
#>
param(
    [string]$RepoPath = "C:\dev\Darwin",
    [switch]$Release,    # 릴리스 프로파일(기본 debug)
    [switch]$Wired,      # 유선 123.1(기본 무선 0.33)
    [switch]$Pull,       # git pull --ff-only
    [switch]$Build,      # cargo build (darwin-fpv-native + ally-cli)
    [switch]$Selftest,   # ally-cli selftest (로봇 불요 — 제어경로·메트릭)
    [switch]$AxisDump,   # ally-cli axis-dump (게임패드 매핑 현장 확인 — 대화형)
    [switch]$Probe,      # ally-cli probe (로봇 TCP:22 도달성)
    [switch]$Connect,    # ally-cli connect (실로봇 W1 게이트 — 로봇에 명령 송출)
    [switch]$Run,        # darwin-fpv-native 콕핏 실행(+Edge)
    [switch]$All,        # pull+build+selftest+probe+run (안전 기본)
    [int]$Seconds = 8
)
$ErrorActionPreference = "Stop"
chcp 65001 > $null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ally       = Join-Path $RepoPath "app\ally"
$prefer     = if ($Wired) { "wired" } else { "wireless" }
$robotHost  = if ($Wired) { "192.168.123.1" } else { "192.168.0.33" }
$profileArg = if ($Release) { @("--release") } else { @() }
$profileDir = if ($Release) { "release" } else { "debug" }
$nativeExe  = Join-Path $ally "target\$profileDir\darwin-fpv-native.exe"
$cliExe     = Join-Path $ally "target\$profileDir\ally-cli.exe"
$identity   = Join-Path $env:USERPROFILE ".ssh\id_rsa_darwin"

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# 안전 기본 묶음. 플래그가 전혀 없으면 -All 로 간주.
$anyFlag = $Pull -or $Build -or $Selftest -or $AxisDump -or $Probe -or $Connect -or $Run
if ($All -or -not $anyFlag) { $Pull = $true; $Build = $true; $Selftest = $true; $Probe = $true; $Run = $true }

if (-not (Test-Path $ally)) { throw "리포 없음: $ally (RepoPath 확인)" }
Set-Location $ally

# 로봇 전제 점검(도달성 + walklab-active) — probe/connect/run 의미 확인용.
function Test-RobotReady {
    Step "로봇 점검 ($robotHost)"
    $tcp = Test-NetConnection $robotHost -Port 22 -WarningAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) { Write-Warning "로봇 SSH(:22) 도달 실패 — 전원/네트워크 확인"; return $false }
    $raw = & ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o HostKeyAlgorithms=+ssh-rsa `
        -o PubkeyAcceptedAlgorithms=+ssh-rsa -o ConnectTimeout=6 -i $identity "robotis@$robotHost" `
        "cat /tmp/df-pilot-progress 2>/dev/null" 2>$null
    $progress = "$raw".Trim()
    Write-Host "df-pilot-progress = '$progress'"
    if ($progress -ne "walklab-active") { Write-Warning "로봇이 walklab-active 아님 — 로봇에서 WalkLab 기동 후 재시도"; return $false }
    Write-Host "→ 로봇 walklab-active OK" -ForegroundColor Green
    return $true
}

if ($Pull) {
    Step "git pull (ff-only) — claude/ally-w1-core"
    git -C $RepoPath fetch origin claude/ally-w1-core
    git -C $RepoPath merge --ff-only origin/claude/ally-w1-core
    if ($LASTEXITCODE -ne 0) { Write-Warning "ff-only 머지 실패(분기/로컬변경) — 현재 코드로 진행. git status 확인." }
    Write-Host ("HEAD = " + (git -C $RepoPath rev-parse --short HEAD))
}

if ($Build) {
    Step "cargo build (darwin-fpv-native + ally-cli, $profileDir)"
    cargo build @profileArg -p darwin-fpv-native -p ally-cli
    if ($LASTEXITCODE -ne 0) { throw "빌드 실패 (cargo exit $LASTEXITCODE)" }
    Write-Host "→ $nativeExe" -ForegroundColor Green
}

if ($Selftest) {
    Step "ally-cli selftest (로봇 불요 — 루프백 제어경로·메트릭)"
    & $cliExe selftest
}

if ($Probe) {
    Step "ally-cli probe (--prefer $prefer)"
    & $cliExe probe --prefer $prefer
}

if ($AxisDump) {
    Step "ally-cli axis-dump ($Seconds s) — 모든 스틱/트리거/버튼을 끝까지 움직여라"
    & $cliExe axis-dump --seconds $Seconds
    Write-Host "→ 기대: 좌스틱 위=주행+ · 우스틱=머리 · LT/RT=턴 · A=ARM · B=E-STOP · Y=복구." -ForegroundColor Yellow
    Write-Host "  부호/축이 어긋나면(예: 좌우 반전) 보고 — 매핑 보정 필요." -ForegroundColor Yellow
}

if ($Connect) {
    Write-Warning "실로봇 연결 — 로봇에 20Hz 명령 송출. Mac DarwinForge 앱 OFF · 로봇 거치/안전 확인."
    if (Test-RobotReady) {
        Step "ally-cli connect (W1 게이트 — eff_hz≥19·RTT, ${Seconds}s)"
        & $cliExe connect --identity $identity --prefer $prefer --seconds $Seconds
    }
}

if ($Run) {
    Step "darwin-fpv-native 콕핏 실행 (+Edge)"
    if (-not (Test-Path $nativeExe)) { throw "exe 없음: $nativeExe — 먼저 -Build" }
    $runArgs = @("--port", "8765")
    if ($Wired) { $runArgs += "--wired" }
    Start-Process -FilePath $nativeExe -ArgumentList $runArgs -WorkingDirectory $ally
    Write-Host "→ 콕핏 + Edge 기동. 자동 연결 실패면 콕핏 '재연결' 버튼." -ForegroundColor Green
}

Write-Host @"

── W1 하드웨어 게이트 체크리스트 (실기 육안) ────────────────────────
  [ ] axis-dump : 좌스틱 위=주행+ · 우스틱=머리 · LT/RT=턴 (부호·축 일치)
  [ ] connect   : eff_hz >= 19 · RTT 안정
  [ ] 콕핏 연결 : 좌측 '전송 UDP' · 텔레메트리(배터리/IMU) 표시
                  (빈 화면이면 Windows 방화벽 프롬프트 '허용' 또는 bootstrap §2.5)
  [ ] ARM(A)    : 무장 후 스틱 -> 로봇 보행 / 미무장 시 정지
  [ ] E-STOP    : B/터치 <= 150ms 정지 · 복구(Y) 후 재개
  [ ] 패드 분리 : 즉시 정지(zero+disarm)
  전제: 로봇 walklab-active · Mac 앱 OFF · Ally 게임패드
─────────────────────────────────────────────────────────────────
"@ -ForegroundColor DarkGray
