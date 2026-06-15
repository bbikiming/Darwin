# 인수인계 — DarwinForge 4기능 중 R1·R2·R4 이어서 구현

- **작성**: 2026-06-08 (KST), Claude (Opus 4.8)
- **브랜치**: `claude/robotis-darwin-op-setup-oyzTi`
- **직전 커밋**: `f676ade` (R3 완료)
- **목적**: 사용자 요청 4기능 중 R3 완료. 새 세션에서 **R1 → R2 → R4** 순으로 이어서 구현.

---

## 0. 한 줄 요약

> 콕핏 메뉴·3D·안전게이트·온보드 브릿지·부팅 rc.local 훅·앱 빌드/설치 스크립트는 **대부분 이미 존재**한다.
> 신규 작업은 (R1) 콕핏을 실로봇 명령 경로에 **배선**, (R2) 스위치 agent **자동 배포 커맨드+UI**, (R4) **빌드 후 재설치**뿐이다.
> 설계 없이 코딩 금지(HARD-GATE) — R1·R2는 ≥3파일이므로 착수 전 계획 확인. 진행상황은 메모리 `darwinforge-4feature-progress.md` 에도 있음.

## 1. 사용자가 승인한 제품 결정 (확정)

| 항목 | 결정 |
|---|---|
| R1 콕핏 성격 | **맥에서 실로봇 직접 조종** (키보드/패드 → Mac이 SSH로 `/tmp/df-walklab-cmd` 전송, Switch와 동일) |
| R3 부팅 거동 | 선택형 + **천천히·안정적 기립** (완료) |
| R2 주입 범위 | **전체 자동 배포** (package→scp→install.sh→config 머지→재시작, sudo 비번은 앱이 입력받아 처리) |

## 2. R3 — 완료 (커밋 `f676ade`, 실기 검증됨)

- **느린 기립**: `firmware-patches/walklab-brokerage/install-onboard.sh` 의 주입 walk-ready 를
  `LoadPage(9,&p)` 후 `p.header.speed*=3` (32→96) 으로 재생. page9="walkready", schedule=TIME_BASE(0x0a)
  → 재생시간 ∝ step.time×speed 이므로 speed↑=느림. `Action::Start(int,PAGE*)` 는 체크섬 미검증이라 수정 페이지 재생 가능.
- **부팅 자동기동**: `/etc/rc.local` 에 복원 훅 추가(데모 실행 전 영구 `~/.config/darwinforge/pilot-mode==walklab`
  이면 `/tmp/df-pilot-mode` 복원). 토글 = pilot-mode 파일.
- **install-onboard.sh 가 strip+reinject** 로 바뀌어 주입 코드 변경이 재설치로 반영됨.
- **미완**: 실제 reboot 종단 검증(사용자 전원 재인가 시 부팅→느린기립 확인).

## 3. 현재 실기 상태 (이어받을 때 가정)

- **로봇**: OP2/CM-740, `robotis@192.168.123.1`(유선, 빠름) / `192.168.0.33`(무선, Switch가 닿는 IP).
  데모 walklab 제어모드로 실행 중(pid 가변), head_tilt 65° + 느린기립 binary. demo가 `/dev/video0`+8080 점유(카메라 충돌 미해결 — `camera-vs-walklab-dev-video` 메모리).
- **Switch**: `yuseok@192.168.0.25`, 새 agent 설치+config 머지 완료, mode=ssh, ssh.host=0.33. 조종 실전 검증됨(빠르게 잘 달림).
- **접속**: Mac→로봇 비번 `111111` (`sshpass` 설치됨; `export SSHPASS=111111; sshpass -e ssh ... robotis@192.168.123.1`).
  Mac→Switch 키 `~/.ssh/id_rsa_darwin` (`ssh -i ~/.ssh/id_rsa_darwin yuseok@192.168.0.25`). Switch sudo는 비번필요(yuseok), systemctl restart darwin-switch-agent 만 NOPASSWD.
  ⚠️ 로봇 authorized_keys 에 Switch 공개키 등록은 사용자 승인 받음(공유기기 영구접근). 비번 평문 SSH 헬퍼는 매 세션 끝에 삭제.

## 4. R1 — 콕핏 실로봇 직접 조종 (배선 위주)

**이미 존재(재사용)**
- 메뉴 등록됨: `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift:1072` (`.cockpit → PilotCockpitView()`).
- `Pilot/Cockpit/PilotCockpitView.swift` (≈1555줄): 30Hz 적분기, 가상 스틱, `RobotScene3D`, `realMotorEnabled` 게이트(기본 OFF).
- `CockpitState.swift`, `CockpitCommandSmoother.swift`(EMA α=0.25), `WalkingCommand`(`TelloRCMapper.swift`), `PilotSafetyGate.swift`(4단).
- **Mac이 이미 `/tmp/df-walklab-cmd` 기록**: `WalkLab/WalkLabSession+Pilot.swift:58-181`(`pilotApplyFreeform` 등) + `WalkLab/Components/WalkLabOnboardBridge.swift`(직렬화·write-race 주석 :390).
- SSH e-stop: `Connection/RobotSetupCommand.swift:1467-1488`.

**신규/배선(예상 1~2파일)**
- `CockpitOnboardRouter`(신규): `CockpitState.motorCommand` → 기존 `pilotApplyFreeform()` → `WalkLabOnboardBridge`.
- `realMotorEnabled` 게이트 기본 OFF 유지, **ARM 뒤에서만** 실모터 전송.
- **보행모드 배타성**(CLAUDE.md): 콕핏은 walk 모드 필요(bus 모드 아님). 모드 전환 가드.
- **단일 writer**: 콕핏이 보내는 동안 Switch와 동시에 `/tmp/df-walklab-cmd` 쓰지 않도록(레이스 :390). 콕핏 사용 시 경고/배타.

**테스트(직렬 swift)**: `CockpitState.integrate()` 스틱→`WalkingCommand`, 스무더 EMA, auto-disarm dwell, `CockpitOnboardRouter`(브릿지 writer mock). Rust/pytest 없음.

## 5. R2 — 스위치 주입(전체 자동 배포)

**이미 존재(재사용)**
- `Connection/SwitchRobotLinkSession.swift` — 9단계 마법사 + LaunchMode; `SSHShell.run()`(`:251-285`), `enable-agent-ssh`(`:537-558`).
- `SwitchLink/SwitchRobotLinkView.swift` — 호스트 카드; 신규 카드는 `launchModesCard`/`stabilizeCard:829` 부근.
- 자동화 대상 CLI: `tools/switch-pilot/{package.sh, install.sh, deploy-to-switch.sh}`.

**신규**
- `Connection/SwitchAgentDeployCommand.swift`(신규):
  1. `Process` 로 `tools/switch-pilot/package.sh` 실행 → `dist/switch-pilot/darwin-switch-agent-<ver>.tar.gz`.
  2. **scp 헬퍼 추가**(현재 없음 — `SSHShell` 에 scp arg 빌더 추가, 기존 `SSHShellArgumentsTests` 패턴 따라).
  3. SSH로 `install.sh` 실행(sudo). 4. **config 머지**(invert_right_x·빠른보행·비대칭틸트, `ssh.host` 보존). 5. `systemctl is-active` 검증.
- UI: `SwitchRobotLinkView` 에 `agentDeploymentCard`(빌드→전송→설치→검증 진행률).
- **sudo 처리**: `SecureField` 1회 입력 → stdin 파이프. **평문 저장/로그 절대 금지**. (install.sh 는 sudo 필수, config.json 은 yuseok 소유라 편집은 sudo 불필요, restart 는 NOPASSWD.)

**테스트**: scp/ssh 인자 구성(`SSHShellArgumentsTests` 패턴), 배포 상태머신(executor mock), config 머지 순수함수, pytest 번들 내용 검증(`tools/switch-pilot/tests`).

## 6. R4 — 빌드 후 기존 삭제 + 최신 설치 (마지막)

- `scripts/build-app.sh` → `.build/release/DarwinForge.app`(실 번들·ad-hoc 서명; mic/TCC 위해 swift run 금지).
- `scripts/install-app.sh` → 기존 `/Applications/DarwinForge.app` 백업 후 교체·de-quarantine·lsregister.
- 버전 bump 선택: `Sources/DarwinForgeApp/Info.plist` `CFBundleShortVersionString`(빌드번호는 git commit수 자동).
- **R1·R2 반영 + `make test`(cargo)·`swift test`(직렬) 통과 후** 실행. 증거: 빌드 "0 errors" + 설치 번들 버전.

## 7. 순서·게이트·안전

1. (선택) R3 reboot 종단 검증. 2. **R1** 콕핏 배선. 3. **R2** 주입. 4. **R4** 빌드/설치.
- 각 단계: 테스트 통과 증거 제시(증거기반 완료). swift test 는 **직렬**(UserDefaults 공유).
- 실로봇/Switch 반영은 코드+테스트 통과 후, **거치 상태**에서. 모션 기동은 사용자 입회.
- HARD-GATE: R1·R2 착수 전 계획 확인(≥3파일).

## 8. 새 세션 첫 단계 (제안)

```
1) 이 문서 + 메모리(darwinforge-4feature-progress, camera-vs-walklab-dev-video, robot-demo-no-roboplus) 로드
2) R1: PilotCockpitView/CockpitState ↔ WalkLabOnboardBridge 경로 정독 후 CockpitOnboardRouter 설계 → 계획 확인 → TDD 구현
3) git: 현재 브랜치 claude/robotis-darwin-op-setup-oyzTi 에서 계속, Conventional Commits(한글 제목)
```
