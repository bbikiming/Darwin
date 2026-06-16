# DARwIn FPV — TEL2 인바운드 UDP 방화벽 규칙 (W1 유선 게이트 선행)
#
# 왜 필요한가:
#   전송(ally-link UdpControlTransport)은 임시(ephemeral) 포트로 bind 하고 그 포트를
#   /tmp/df-walklab-uplink 에 등록한다. 로봇은 그 포트로 TEL2 를 보낸다. ACK 는 우리가
#   DFCMD 를 보낸 robot:17374 에서 같은 임시 포트로 돌아오므로 Windows 의 UDP stateful
#   필터가 "solicited return" 으로 허용한다. 그러나 **TEL2 는 로봇의 다른 송신 포트**에서
#   오는 **unsolicited inbound** 라 기본 방화벽이 차단할 수 있다 → TEL2 침묵(= HUD stale).
#   따라서 수신 프로그램(exe)에 대한 **프로그램 범위 인바운드 UDP 허용** 규칙이 필요하다.
#   (포트 :17371 은 nominal 기본일 뿐 실제 수신은 임시 포트라 포트 범위 규칙은 빗나간다 —
#    04 §2 W1 체크리스트 "방화벽 TEL2 인바운드" 항목. 프로그램 범위가 정답.)
#
# 사용:
#   # 관리자 PowerShell 에서. 기본은 디버그 빌드의 ally-cli.exe(W1 게이트 러너).
#   .\firewall-tel2.ps1
#   # 릴리스 빌드나 W2 darwin-fpv.exe 를 가리키려면:
#   .\firewall-tel2.ps1 -ExePath C:\dev\Darwin\app\ally\target\release\ally-cli.exe
#   .\firewall-tel2.ps1 -ExePath C:\path\to\darwin-fpv.exe -RuleName "DARwIn FPV TEL2 (app)"
#
# 제거:
#   Remove-NetFirewallRule -DisplayName "DARwIn FPV TEL2*"

[CmdletBinding()]
param(
    [string]$ExePath = "",
    [string]$RuleName = "DARwIn FPV TEL2 (ally-cli)"
)

$ErrorActionPreference = "Stop"

# 기본 exe 경로 — 이 스크립트 기준 워크스페이스의 디버그 ally-cli.exe.
if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)  # app/ally
    $ExePath = Join-Path $PSScriptRoot "..\target\debug\ally-cli.exe"
    $ExePath = [System.IO.Path]::GetFullPath($ExePath)
}

if (-not (Test-Path $ExePath)) {
    Write-Warning "exe 미존재: $ExePath"
    Write-Warning "먼저 빌드하세요: cargo build --manifest-path app\ally\Cargo.toml -p ally-cli"
    Write-Warning "규칙은 exe 경로에 묶이므로(프로그램 범위) 경로가 정확해야 합니다."
    exit 1
}

# 관리자 권한 확인 — 방화벽 규칙 생성은 관리자 필요.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent() `
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "관리자 PowerShell 에서 실행하세요(방화벽 규칙 생성 권한 필요)."
    exit 1
}

# 멱등 — 같은 이름 규칙이 있으면 지우고 다시 만든다(exe 경로 갱신 반영).
$existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "기존 규칙 갱신: $RuleName"
    Remove-NetFirewallRule -DisplayName $RuleName
}

New-NetFirewallRule `
    -DisplayName $RuleName `
    -Direction Inbound `
    -Program $ExePath `
    -Action Allow `
    -Protocol UDP `
    -Profile Any `
    -Description "DARwIn FPV TEL2 30Hz 업링크 수신(unsolicited inbound) 허용 — 임시 포트라 프로그램 범위." | Out-Null

Write-Host "✓ 인바운드 UDP 허용 규칙 생성: '$RuleName'"
Write-Host "  프로그램: $ExePath"
Write-Host "  확인: Get-NetFirewallRule -DisplayName '$RuleName' | Get-NetFirewallApplicationFilter"
Write-Host ""
Write-Host "게이트 수신 확인: ally-cli accept 실행 시 'TEL2 수신율' 이 0 이 아니면 규칙 정상."
Write-Host "여전히 0 이면 ESET/3rd-party 방화벽 또는 AP 격리(client isolation)를 의심하세요."
