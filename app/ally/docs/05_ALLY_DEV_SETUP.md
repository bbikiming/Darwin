# DARwIn FPV — ROG Ally 개발 환경 세팅 · 파일 전달 가이드

- 작성일: 2026-06-13
- 대상: ROG Ally(Windows 11)에 Darwin 리포를 옮기고, Ally 에서 Claude Code 로
  W1+ 를 개발하면서 Mac 에서 원격으로 점검하는 운용 체계
- 자동화: [`scripts/ally-bootstrap.ps1`](../scripts/ally-bootstrap.ps1) (Ally),
  [`scripts/make-sd-bundle.sh`](../scripts/make-sd-bundle.sh) (Mac)

---

## 0. 결론 (TL;DR)

**전달 = git 으로, 개발 = Ally 로컬 Claude Code, 점검 = Mac 에서 SSH.**

1. **주 경로 — GitHub clone**: 리포에 리모트가 이미 있다
   (`https://github.com/bbikiming/Darwin.git`). Ally 에서 clone 하면 끝.
   git pack 은 **~128MB** 라 무선으로도 1~2분.
2. **오프라인 폴백 — microSD + git bundle**: 인터넷 없는 현장용.
   `make-sd-bundle.sh` 가 만든 단일 `.bundle` 파일(≈130MB)을 SD 로 옮겨 clone.
3. **금지 — 작업 폴더 통째 복사**: 현재 작업 트리는 빌드 산출물 포함 **17GB** 다.
   추적되는 콘텐츠는 128MB 뿐이므로 폴더 복사는 130 배 낭비이고, `.build/`,
   `target/` 등 macOS 산출물이 Windows 빌드를 오염시킨다.

개발 루프는 사용자가 제안한 구도 그대로가 정답이다:
**Ally 에서 Claude Code 로컬 실행**(W1+ 는 XInput·방화벽·ssh2 등 Windows
실기에서만 검증 가능) + **Mac 에서 SSH 원격 체크**(리뷰·로그·테스트 확인)
+ **git push/pull 로 양방향 동기화**.

---

## 1. 전달 방식 비교

| 방식 | 초기 전달 | 반복 동기화 | 판정 |
|---|---|---|---|
| **GitHub clone/pull** | ◎ ~128MB, 1~2분 | ◎ `git pull` 한 줄, 히스토리·브랜치 보존 | **주 경로** |
| **microSD + git bundle** | ○ 단일 파일, 오프라인 OK | △ bundle 재생성·재복사 필요 | **오프라인 폴백** |
| Mac→Ally SSH(rsync/scp) | △ 작업트리 기준이라 제외 규칙 관리 필요 | ○ 가능하나 git 와 중복 | 비권장 (git 가 상위호환) |
| 작업 폴더 통째 복사 | ✗ 17GB, 산출물 오염 | ✗ | **금지** |

> microSD 를 쓰더라도 **raw 폴더가 아니라 git bundle** 을 담는다 — 히스토리가
> 보존되므로 Ally 도착 즉시 정상 git 작업 트리가 되고, 이후 리모트만 GitHub 로
> 바꾸면 네트워크 동기화로 전환된다.

---

## 2. 권장 개발 루프

```
┌─ ROG Ally (Windows 11) ──────────────┐      ┌─ Mac (DarwinForge 작업장) ─────┐
│ Claude Code 로컬 세션                 │      │ 원격 점검:                      │
│  · W1 ally-link/ally-input 구현       │ git  │  ssh ally "..." (로그·테스트)    │
│  · cargo test / ally-cli 실기 게이트   │◀────▶│  git fetch → diff/리뷰          │
│  · 커밋·푸시 (claude/ally-* 브랜치)    │ push │  필요 시 Mac 쪽 수정 → push     │
└──────────────┬───────────────────────┘      └────────────────────────────────┘
               │ USB-C LAN (W1 유선 게이트) 또는 무선 192.168.0.33
               ▼
           DARwIn-OP2 (로봇 접근은 한 번에 한 세션 — §6)
```

- **Ally = 실기 작업대**: Windows 전용 검증(XInput 패드, 방화벽 TEL2 인바운드,
  ssh2↔OpenSSH 5.9, Tauri/WebView2)은 Ally 에서만 가능하므로 Claude Code 를
  Ally 에서 직접 돌리는 것이 왕복이 가장 짧다.
- **Mac = 리뷰·병행 작업대**: Swift 앱·로봇 펌웨어·문서는 계속 Mac. Ally 작업
  브랜치를 fetch 해 리뷰하고, 코드 리뷰 코멘트는 커밋/PR 로 주고받는다.
- 브랜치 규칙: Ally 작업은 `claude/ally-w1-*` 처럼 웨이브 단위로. 자주 커밋하고
  세션 종료 전 반드시 push (Ally 는 게임기 — 언제든 밀릴 수 있다고 가정).

---

## 3. Ally 부트스트랩 (1회)

### 3.1 자동 — ally-bootstrap.ps1

관리자 PowerShell 에서:

```powershell
# (clone 전이라면 스크립트만 먼저 받아 실행)
irm https://raw.githubusercontent.com/bbikiming/Darwin/<브랜치>/app/ally/scripts/ally-bootstrap.ps1 -OutFile bootstrap.ps1
Set-ExecutionPolicy -Scope Process Bypass
.\bootstrap.ps1 -MacPubKey "ssh-ed25519 AAAA... mac"   # Mac 공개키 주입(원격 체크용)
```

스크립트가 하는 일: ① winget 으로 도구 설치(Git·rustup·Python·Node·VS Build
Tools C++ 워크로드) ② rustup stable-msvc + clippy/rustfmt ③ Claude Code 설치
④ OpenSSH **Server** 활성화(+관리자 키 경로 함정 처리, §3.3) ⑤ 전원/절전 설정
⑥ git autocrlf=input ⑦ 리포 존재 시 W0 스모크 테스트.

### 3.2 수동 절차 (스크립트 실패 시 대조표)

| 단계 | 명령 |
|---|---|
| 도구 설치 | `winget install -e --id Git.Git Rustlang.Rustup Python.Python.3.12 OpenJS.NodeJS.LTS` |
| MSVC 툴체인 | `winget install -e --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"` |
| Rust | `rustup default stable-msvc && rustup component add clippy rustfmt` |
| Claude Code | `irm https://claude.ai/install.ps1 \| iex` (실패 시 `npm install -g @anthropic-ai/claude-code`) → `claude` 첫 실행에서 브라우저 로그인 |
| clone | `git clone https://github.com/bbikiming/Darwin.git C:\dev\Darwin` → `git checkout <작업 브랜치>` |

### 3.3 OpenSSH Server (Mac 원격 체크용) — 함정 1개

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic; Start-Service sshd
```

**함정**: 관리자 계정의 공개키는 `~\.ssh\authorized_keys` 가 아니라
**`C:\ProgramData\ssh\administrators_authorized_keys`** 에 넣어야 하고, ACL 이
Administrators+SYSTEM 으로 제한돼야 sshd 가 받아준다 (bootstrap 이 처리):

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r `
  /grant "Administrators:F" /grant "SYSTEM:F"
```

### 3.4 microSD 폴백 (오프라인 초기 전달)

```sh
# Mac — bundle 생성 (~130MB 단일 파일) + SD 복사
bash app/ally/scripts/make-sd-bundle.sh /Volumes/<SD이름>
```

```powershell
# Ally — SD(D: 가정)에서 clone 후 리모트를 GitHub 로 전환
git clone D:\darwin-<날짜>.bundle C:\dev\Darwin
cd C:\dev\Darwin
git checkout <작업 브랜치>
git remote set-url origin https://github.com/bbikiming/Darwin.git   # 이후 pull/push 는 네트워크
```

---

## 4. Mac 측 세팅 (원격 체크)

`~/.ssh/config` 에 추가 (Ally IP 는 `ipconfig` 로 확인 — 공유기에서 DHCP 고정 권장):

```
Host ally
    HostName 192.168.0.<Ally-IP>
    User <Ally 계정명>
```

원격 체크 명령 모음:

```sh
ssh ally "cd C:/dev/Darwin; git log --oneline -5"                       # 진행 확인
ssh ally "cd C:/dev/Darwin/app/ally; cargo test 2>&1 | Select-String 'test result'"  # 테스트
ssh ally "cd C:/dev/Darwin/app/ally; cargo clippy --all-targets -- -D warnings"      # 린트
git fetch origin claude/ally-w1-core && git diff origin/claude/ally-w1-core          # 코드 리뷰 (Mac 로컬)
```

> 기본 셸은 PowerShell 이므로 따옴표 안 명령은 PowerShell 문법이다.
> 코드 리뷰는 SSH 보다 **git fetch 후 Mac 에서 diff** 가 편하다 — SSH 는
> "지금 뭐 하고 있나" 라이브 확인용.

(선택) Mac↔Ally 가 다른 네트워크에 있을 일이 생기면 Tailscale 을 양쪽에 설치
하면 위 구성이 그대로 유지된다 — 로봇 AP 안에서만 쓸 거면 불필요.

---

## 5. 도착 직후 W0 스모크 (Ally 에서 — Windows 첫 패리티 확인)

```powershell
cd C:\dev\Darwin\app\ally
python3 scripts\gen-golden-vectors.py        # 픽스처 재생성(결정적 — diff 0 이어야 정상)
cargo test                                   # 기대: 21 passed (unit 14 + parity 7)
cargo clippy --all-targets -- -D warnings    # 기대: 경고 0
git diff --stat                              # 기대: 변경 없음 (생성기 결정성 검증)
```

이 4줄이 전부 그린이면 **와이어 계약 계층이 Windows 에서도 Python 원본과
바이트 동일**함이 증명된 것 — W1 착수 조건 충족. 하나라도 어긋나면 W1 시작
전에 보고(특히 `git diff` 가 잡히면 CRLF/파이썬 버전 문제).

---

## 6. 네트워크 토폴로지 · 로봇 경합 규칙

```
공유기(로봇 AP) ── Mac (DarwinForge)
      ├────────── ROG Ally (192.168.0.x, DHCP 고정 권장)
      └────────── DARwIn-OP2 (무선 192.168.0.33)
Ally ──USB-C LAN 어댑터──▶ 로봇 192.168.123.1 (W1 유선 게이트 — ~166배 빠름)
```

- **로봇 접근은 한 번에 한 세션** (리포 불변 규칙): Ally 가 W1 실기 게이트를
  돌리는 동안 Mac DarwinForge 앱은 **종료** (G01 브링업 §6 운용 노트와 동일 —
  Mac 앱 폴러가 핸드셰이크를 회전시키면 Ally 의 UDP 채널이 즉사한다,
  04_ACCEPTANCE_ROADMAP.md §4.4).
- Ally 의 SSH 키(로봇용): Mac 의 `~/.ssh/id_rsa_darwin` 을 복사하거나 Ally 에서
  새 RSA 키를 만들어 로봇에 등록 (로봇은 OpenSSH 5.9 — **RSA only**).

---

## 7. 운용 노트 (Windows 가 끼어드는 것들)

| 항목 | 조치 | 시점 |
|---|---|---|
| **TEL2 텔레메트리 안 옴** (배터리/IMU/낙상/3D 포즈 빈 화면, 조종은 됨) | 인바운드 UDP 허용 필요 — Ally→robot:17374 의 ACK 는 stateful 통과하나 TEL2(robot:17371→Ally)는 다른 소스포트라 기본 차단. **`ally-bootstrap.ps1` §2.5 가 프로그램 규칙 등록**(release/debug). 또는 `darwin-fpv-native` 첫 실행 시 방화벽 프롬프트 **"허용"**. exe 가 비관리자면 startup best-effort netsh 는 무해 실패 → bootstrap/프롬프트가 주 경로 | 1회 |
| 절전/화면 꺼짐 | bootstrap 이 AC 전원 기준 해제 (`powercfg`) | 1회 |
| Windows Update | 설정 → 활성 시간 지정 (테스트 중 재부팅 차단) | 1회 |
| Game Bar | Win+G → 캡처/녹화 끔 (입력 가로채기·오버레이 회피) | 1회 |
| WiFi 어댑터 절전 | 장치 관리자 → WiFi → 전원 관리 → 절전 해제 (RTT 스파이크 방지) | 1회 |
| Armoury Crate | 개발 중 운영 모드 무관, W4 패키징 게이트에서 게임 등록 검증 | W4 |
| 백신/Defender | cargo target 폴더 실시간 검사 제외(선택 — 빌드 속도) | 선택 |
