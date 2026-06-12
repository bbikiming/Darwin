import SwiftUI

/// 원격 셸에서 자주 쓰는 명령 — 카테고리별 그룹.
///
/// 카테고리 선정 근거 (지금까지 디버그/셋업에서 반복 사용된 명령):
///   - system:    환경 진단 (uptime / 메모리 / 디스크 / 온도)
///   - service:   부팅 데몬 제어 (sshd / forge-bridge / df-inbox / samba)
///   - robotis:   ROBOTIS framework (vision_demo / walk_tuner / framework 재시작)
///   - bus:       Dynamixel / USB serial 진단
///   - danger:    재부팅 / 셧다운 / 강제 종료 (confirm 필수)
public enum QuickActionCategory: String, CaseIterable, Identifiable {
    case system, service, robotis, bus, danger
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system:  return "시스템"
        case .service: return "서비스"
        case .robotis: return "ROBOTIS"
        case .bus:     return "버스/USB"
        case .danger:  return "위험"
        }
    }

    public var icon: String {
        switch self {
        case .system:  return "cpu.fill"
        case .service: return "gearshape.2.fill"
        case .robotis: return "figure.stand"
        case .bus:     return "cable.connector"
        case .danger:  return "exclamationmark.octagon.fill"
        }
    }

    public var tint: Color {
        switch self {
        case .system:  return DFColor.accent
        case .service: return DFColor.success
        case .robotis: return DFColor.forge
        case .bus:     return DFColor.warning
        case .danger:  return DFColor.danger
        }
    }
}

public struct QuickAction: Identifiable, Hashable {
    public let id: String
    public let category: QuickActionCategory
    public let label: String
    public let detail: String
    public let icon: String
    public let command: String
    public let requiresConfirm: Bool
    /// 확인 다이얼로그의 **영향 요약 한 줄** (실기 UI fix, 2026-06-12).
    /// 다이얼로그 본문엔 스크립트 전문 대신 이 요약만 표시 — nil 이면 카테고리 기본 문구
    /// (`QuickActionConfirmModel.summaryText`). `requiresConfirm` 액션은 지정 권장.
    public let confirmSummary: String?

    public init(id: String, category: QuickActionCategory, label: String,
                detail: String, icon: String, command: String,
                requiresConfirm: Bool = false,
                confirmSummary: String? = nil) {
        self.id = id
        self.category = category
        self.label = label
        self.detail = detail
        self.icon = icon
        self.command = command
        self.requiresConfirm = requiresConfirm
        self.confirmSummary = confirmSummary
    }
}

public enum QuickActionCatalog {

    /// 자주 사용하는 명령 30+ — 지금까지 디버그/셋업에서 반복 사용된 것들 + 일반 진단.
    public static let all: [QuickAction] = [
        // ── system ──────────────────────────────────────────────────────
        QuickAction(id: "uptime", category: .system, label: "Uptime",
                    detail: "가동 시간 + load", icon: "clock.fill",
                    command: "uptime"),
        QuickAction(id: "memory", category: .system, label: "메모리",
                    detail: "free -m head", icon: "memorychip",
                    command: "free -m | head -2"),
        QuickAction(id: "disk", category: .system, label: "디스크",
                    detail: "home 사용량", icon: "internaldrive",
                    command: "df -h ~ | tail -1; df -h / | tail -1"),
        QuickAction(id: "cpu-temp", category: .system, label: "CPU 온도",
                    detail: "thermal_zone0", icon: "thermometer.medium",
                    command: "cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf \"%.1f°C\\n\", $1/1000}'"),
        QuickAction(id: "os-version", category: .system, label: "OS 버전",
                    detail: "lsb_release", icon: "info.circle",
                    command: "lsb_release -a 2>/dev/null; uname -a"),
        QuickAction(id: "network", category: .system, label: "네트워크",
                    detail: "ifconfig 핵심", icon: "network",
                    command: "ifconfig | grep -E 'inet |^[a-z]+:' | head -10"),
        QuickAction(id: "processes", category: .system, label: "프로세스 top",
                    detail: "CPU 점유 상위", icon: "list.bullet.rectangle",
                    command: "ps aux --sort=-%cpu | head -8"),

        // ── service ─────────────────────────────────────────────────────
        QuickAction(id: "df-inbox-status", category: .service, label: "df-inbox 상태",
                    detail: "원격 명령 채널", icon: "tray.fill",
                    command: "sudo /etc/init.d/df-inbox status 2>/dev/null"),
        QuickAction(id: "forge-bridge-status", category: .service, label: "forge-bridge 상태",
                    detail: "USB-TCP 5530", icon: "antenna.radiowaves.left.and.right",
                    command: "sudo /etc/init.d/forge-bridge status 2>/dev/null; ss -lnt 2>/dev/null | grep :5530"),
        QuickAction(id: "ssh-start", category: .service, label: "SSH 시작",
                    detail: "한 번 service start", icon: "key.fill",
                    command: "sudo service ssh start"),
        QuickAction(id: "ssh-permanent", category: .service, label: "SSH 영구 활성",
                    detail: "설치 + 부팅 자동", icon: "key.horizontal.fill",
                    command: "sudo apt-get install -y --force-yes openssh-server && sudo service ssh start && sudo update-rc.d ssh defaults",
                    requiresConfirm: true,
                    confirmSummary: "openssh 설치 + 부팅 자동시작 등록 — 약 1분, 네트워크 구성 변경"),
        QuickAction(id: "smb-restart", category: .service, label: "Samba 재시작",
                    detail: "SMB share 갱신", icon: "externaldrive.connected.to.line.below",
                    command: "sudo service smbd restart && sudo service nmbd restart"),
        QuickAction(id: "forge-bridge-restart", category: .service, label: "forge-bridge 재시작",
                    detail: "5530 socat 재시작", icon: "arrow.clockwise",
                    command: "sudo killall socat 2>/dev/null; sudo /etc/init.d/forge-bridge restart"),

        // ── robotis ────────────────────────────────────────────────────
        // 카메라 (8080 process — 다른 모드와 동시 실행 OK)
        QuickAction(id: "camera-start", category: .robotis, label: "카메라 데모 시작",
                    detail: "공식 8080 snapshot", icon: "camera.viewfinder",
                    command: RobotSetupCommand.cameraTutorialStart),
        QuickAction(id: "camera-status", category: .robotis, label: "카메라 상태",
                    detail: "프로세스/8080/video", icon: "video.badge.checkmark",
                    command: RobotSetupCommand.cameraTutorialStatus),
        QuickAction(id: "camera-stop", category: .robotis, label: "카메라 데모 중지",
                    detail: "8080 종료", icon: "camera.fill.badge.ellipsis",
                    command: RobotSetupCommand.cameraTutorialStop),

        // 실기 F12 (2026-06-13) — RG G01 조종기 데모 원클릭. walkLabRobotisStart 는
        // estop flag 해제 → demo(-pilot) 재시작 → walklab 진입 → ACK 게이트까지
        // 하는 검증된 시작 경로(connectOnboard 자동 복구와 동일 스크립트).
        // 진입 후 패드 A(ARM)만 누르면 조종 시작 — GamepadPilot 은 동글 자동 획득.
        QuickAction(id: "gamepad-pilot-start", category: .robotis,
                    label: "조종기 데모 시작",
                    detail: "WalkLab + RG G01 패드 (A=ARM, B=E-STOP)",
                    icon: "gamecontroller.fill",
                    command: RobotSetupCommand.walkLabRobotisStart,
                    requiresConfirm: true,
                    confirmSummary: "데모를 재시작해 WalkLab 조종 모드로 진입합니다 — "
                        + "기립+자이로 캘리브레이션(~20초) 후 패드 A(ARM)로 조종 시작. "
                        + "로봇을 크래들에 거치하거나 평지에 세워 두세요."),

        // 볼 트래킹 / 걷기 / 액션 데모 — USB bus 점유, forge-bridge 와 양립 불가.
        QuickAction(id: "ball-tracker-start", category: .robotis, label: "공 추적 데모 시작",
                    detail: "ROBOTIS demo (vision/soccer)", icon: "target",
                    command: RobotSetupCommand.ballTrackerStart),
        QuickAction(id: "demo-status", category: .robotis, label: "데모 상태",
                    detail: "demo / 5530 / USB 점유자", icon: "list.bullet.indent",
                    command: RobotSetupCommand.ballTrackerStatus),
        QuickAction(id: "walk-demo-start", category: .robotis, label: "걷기 데모 시작",
                    detail: "walk_tuner", icon: "figure.walk.motion",
                    command: RobotSetupCommand.walkDemoStart),
        QuickAction(id: "action-demo-start", category: .robotis, label: "액션 데모 시작",
                    detail: "action_editor (motion_4096)", icon: "play.rectangle.fill",
                    command: RobotSetupCommand.actionDemoStart),
        QuickAction(id: "demo-stop", category: .robotis, label: "수동 모드 (데모 종료)",
                    detail: "demo kill + forge-bridge 복구", icon: "gamecontroller",
                    command: RobotSetupCommand.demoStop),

        // Phase B (Sprint 18) — patched demo binary 자동 빌드 + 관리.
        QuickAction(id: "demo-patch-build", category: .robotis,
                    label: "패치 demo 빌드 (1회)",
                    detail: "demo 시작 시 SOCCER 자동 진입 (demo-pilot)",
                    icon: "hammer.fill",
                    command: RobotSetupCommand.demoBuildPatched,
                    requiresConfirm: true,
                    confirmSummary: "로봇에서 demo 를 재빌드합니다 — 약 1~2분, 빌드 후 원본 main.cpp 복구"),
        QuickAction(id: "demo-patch-status", category: .robotis,
                    label: "패치 demo 상태",
                    detail: "demo-pilot 설치 여부",
                    icon: "checkmark.seal",
                    command: RobotSetupCommand.demoPatchedStatus),
        QuickAction(id: "demo-patch-remove", category: .robotis,
                    label: "패치 demo 제거",
                    detail: "demo-pilot binary + 흔적 정리",
                    icon: "trash",
                    command: RobotSetupCommand.demoRemovePatched,
                    requiresConfirm: true,
                    confirmSummary: "demo-pilot 바이너리와 주입 흔적을 정리합니다 — 원본 demo 는 유지"),

        // 진단
        QuickAction(id: "fuser-ttyusb", category: .robotis, label: "ttyUSB 점유자",
                    detail: "USB serial 잡은 PID", icon: "questionmark.circle",
                    command: "sudo fuser -v /dev/ttyUSB0 2>&1"),

        // ── bus ────────────────────────────────────────────────────────
        QuickAction(id: "tty-list", category: .bus, label: "USB serial 목록",
                    detail: "/dev/ttyUSB*", icon: "list.bullet",
                    command: "ls -la /dev/ttyUSB* /dev/ttyACM* 2>/dev/null"),
        QuickAction(id: "stty-status", category: .bus, label: "Baud rate 확인",
                    detail: "ttyUSB0 settings", icon: "speedometer",
                    command: "sudo stty -F /dev/ttyUSB0 -a 2>&1 | head -3"),
        QuickAction(id: "dmesg-usb", category: .bus, label: "USB 이벤트",
                    detail: "dmesg 최근 USB", icon: "doc.text",
                    command: "dmesg 2>/dev/null | grep -i 'usb\\|ftdi' | tail -10"),
        QuickAction(id: "port-listen", category: .bus, label: "Listen 포트",
                    detail: "5530 / 22 / 445", icon: "network.badge.shield.half.filled",
                    command: "ss -lnt 2>/dev/null | grep -E ':(22|139|445|5530|5900|8080)\\s' || netstat -lnt | grep -E ':(22|139|445|5530|5900|8080)'"),

        // ── danger ─────────────────────────────────────────────────────
        QuickAction(id: "reboot", category: .danger, label: "재부팅",
                    detail: "sudo reboot", icon: "arrow.triangle.2.circlepath",
                    command: "sudo reboot",
                    requiresConfirm: true,
                    confirmSummary: "로봇이 즉시 재부팅됩니다 — 약 1~2분 오프라인, 보행 중이면 정지"),
        QuickAction(id: "shutdown", category: .danger, label: "셧다운",
                    detail: "sudo poweroff", icon: "power",
                    command: "sudo poweroff",
                    requiresConfirm: true,
                    confirmSummary: "로봇 전원이 꺼집니다 — 물리 전원 버튼으로만 재시작 가능"),
        QuickAction(id: "killall-socat", category: .danger, label: "모든 socat 종료",
                    detail: "5530 강제 해제", icon: "xmark.octagon",
                    command: "sudo killall -9 socat 2>/dev/null && echo killed all",
                    requiresConfirm: true,
                    confirmSummary: "5530 브리지가 끊겨 LAN 연결이 즉시 끊어집니다"),
    ]

    public static func actions(in category: QuickActionCategory) -> [QuickAction] {
        all.filter { $0.category == category }
    }
}
