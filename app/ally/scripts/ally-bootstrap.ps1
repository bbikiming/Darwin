# DARwIn FPV — ROG Ally 개발 환경 부트스트랩 (Windows 11, 관리자 PowerShell)
#
# 사용법:
#   Set-ExecutionPolicy -Scope Process Bypass
#   .\ally-bootstrap.ps1 [-MacPubKey "ssh-ed25519 AAAA... mac"] [-RepoPath C:\dev\Darwin]
#                        [-SkipInstall] [-SkipSsh] [-SkipPower]
#
# 하는 일 (전부 멱등 — 재실행 안전):
#   1) winget: Git / rustup / Python / Node / VS Build Tools(C++ 워크로드)
#   2) rustup stable-msvc + clippy + rustfmt
#   3) Claude Code (네이티브 인스톨러, 실패 시 npm 폴백)
#   4) OpenSSH Server 활성화 + 관리자 키 경로(administrators_authorized_keys) 처리
#   5) 전원: AC 기준 절전·화면 꺼짐 해제
#   6) git: autocrlf=input (리포는 LF 기준 — macOS 에서 생성된 골든 픽스처 보호)
#   7) 리포가 있으면 W0 스모크 테스트 (cargo test — 기대 21 passed)
#
# 상세·함정 설명: app/ally/docs/05_ALLY_DEV_SETUP.md

#Requires -RunAsAdministrator
param(
    [string]$MacPubKey = "",
    [string]$RepoPath = "C:\dev\Darwin",
    [switch]$SkipInstall,
    [switch]$SkipSsh,
    [switch]$SkipPower
)
$ErrorActionPreference = "Stop"

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# --- 1) 도구 설치 -----------------------------------------------------------
if (-not $SkipInstall) {
    Step "winget 도구 설치"
    $packages = @("Git.Git", "Rustlang.Rustup", "Python.Python.3.12", "OpenJS.NodeJS.LTS")
    foreach ($id in $packages) {
        winget install -e --id $id --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { Write-Warning "$id 설치 실패 또는 이미 설치됨 (winget exit $LASTEXITCODE)" }
    }

    Step "VS Build Tools (MSVC C++ 워크로드) — 수 분 소요"
    winget install -e --id Microsoft.VisualStudio.2022.BuildTools `
        --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" `
        --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { Write-Warning "BuildTools winget exit $LASTEXITCODE (이미 설치된 경우 정상)" }

    Step "rustup 툴체인"
    $rustup = Join-Path $env:USERPROFILE ".cargo\bin\rustup.exe"
    if (-not (Test-Path $rustup)) { $rustup = "rustup" }  # PATH 에 이미 있는 경우
    & $rustup default stable-msvc
    & $rustup component add clippy rustfmt

    Step "Claude Code"
    try {
        Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
    } catch {
        Write-Warning "네이티브 인스톨러 실패 — npm 폴백 시도"
        npm install -g "@anthropic-ai/claude-code"
    }
    Write-Host "→ 첫 'claude' 실행 시 브라우저 로그인 필요 (수동 1회)"
}

# --- 2) OpenSSH Server (Mac 원격 체크) --------------------------------------
if (-not $SkipSsh) {
    Step "OpenSSH Server 활성화"
    $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Select-Object -First 1
    if ($cap.State -ne "Installed") { Add-WindowsCapability -Online -Name $cap.Name }
    Set-Service sshd -StartupType Automatic
    Start-Service sshd

    # 방화벽 규칙 (기능 설치가 만들었으면 활성만 확인)
    if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }

    # 기본 셸 = PowerShell (Mac 에서 ssh ally "..." 의 문법 기준을 고정)
    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
        -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -PropertyType String -Force | Out-Null

    # 함정: 관리자 계정 공개키는 ~\.ssh 가 아니라 ProgramData 경로 + 제한 ACL
    if ($MacPubKey -ne "") {
        $authKeys = "C:\ProgramData\ssh\administrators_authorized_keys"
        if (-not (Test-Path $authKeys) -or -not (Select-String -Path $authKeys -SimpleMatch $MacPubKey -Quiet)) {
            Add-Content -Path $authKeys -Value $MacPubKey
        }
        icacls $authKeys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null
        Write-Host "→ Mac 공개키 등록 완료: $authKeys"
    } else {
        Write-Warning "-MacPubKey 미지정 — Mac 원격 체크를 쓰려면 키 등록 필요 (docs/05 §3.3)"
    }
    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -like "192.168.*" } | Select-Object -First 1).IPAddress
    Write-Host "→ Ally IP: $ip — Mac ~/.ssh/config 의 'Host ally' HostName 으로 사용"
}

# --- 3) 전원 (테스트 중 절전 금지 — AC 기준) --------------------------------
if (-not $SkipPower) {
    Step "전원 설정 (AC: 절전 끔·화면 15분)"
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /change monitor-timeout-ac 15
    Write-Host "→ 배터리(DC) 기본값 유지 — 실기 게이트는 전원 연결 상태로 진행"
}

# --- 4) git 줄바꿈 (LF 리포 보호) --------------------------------------------
Step "git core.autocrlf=input"
git config --global core.autocrlf input

# --- 5) W0 스모크 (리포가 이미 있으면) ---------------------------------------
$allyManifest = Join-Path $RepoPath "app\ally\Cargo.toml"
if (Test-Path $allyManifest) {
    Step "W0 스모크: cargo test (기대 21 passed — docs/05 §5)"
    cargo test --manifest-path $allyManifest
} else {
    Step "다음 단계"
    Write-Host @"
리포가 아직 없다. 둘 중 하나로 가져온 뒤 docs/05 §5 스모크를 돌려라:
  git clone https://github.com/bbikiming/Darwin.git $RepoPath        # 주 경로
  git clone D:\darwin-<날짜>.bundle $RepoPath                         # microSD 폴백
"@
}

Write-Host "`n부트스트랩 완료." -ForegroundColor Green
