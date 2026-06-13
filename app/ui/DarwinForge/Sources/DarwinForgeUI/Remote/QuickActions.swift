import SwiftUI

/// 원격 셸에서 자주 쓰는 명령 — 카테고리별 그룹.
///
/// UX 리디자인 (2026-06-13, 실기 브링업 후속 — docs/design 기획서 v1):
///   - 라이팅 규약: label = 동사형(진단 "~확인" / 동작 "~시작·중지·재시작·켜기·끄기"),
///     detail = 결과 중심(명령 원문 금지 — 전문은 툴팁·"명령 보기" 담당),
///     confirmSummary = "~합니다/됩니다" 사실 전달 + 행동 지시만 "~하세요".
///   - 확인 마찰 3티어(`confirmTier`): T1 즉시(읽기·가역) / T2 시트(상태 변경) /
///     T3 홀드(danger — 비가역·연결 상실). **정지 계열은 항상 T1** — "멈추는 일은
///     쉽게, 움직이게 하는 일은 어렵게"(E-STOP 즉시발화 불변식과 동일 축).
///   - 색 불변식: 빨강=danger 전용. bus(읽기 전용 진단)는 warning 금지 → infoText.
///
/// 용어 사전(이 화면 전역): 로봇(실기) · 데모(demo/demo-pilot 프로세스) ·
/// 브리지(forge-bridge/5530) · 채널(Mac↔로봇 SSH) · 셋업 가이드(최초 구성) ·
/// 패드(RG G01) · 셸(명령 실행 모드 — "콘솔"은 출력 영역 전용).
public enum QuickActionCategory: String, CaseIterable, Identifiable {
    case system, service, robotis, bus, danger
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system:  return "시스템 진단"
        case .service: return "서비스"
        case .robotis: return "로봇 데모"
        case .bus:     return "버스/USB 진단"
        case .danger:  return "위험 명령"
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
        // 색 불변식(기획 2.3): 노랑=주의 전용. 읽기 전용 진단이 warning 이던 종전은 위반.
        case .bus:     return DFColor.infoText
        case .danger:  return DFColor.danger
        }
    }
}

/// 확인 마찰 티어 — 위험도에 비례하는 마찰(기획 5.1).
public enum QuickActionConfirmTier {
    /// 읽기 전용·가역 — 클릭 즉시 실행.
    case none
    /// 상태 변경 — 확인 시트(요약 + 명시 동사 버튼).
    case sheet
    /// 비가역·연결 상실(danger) — 시트 + 1.5초 홀드 버튼.
    case hold
}

public struct QuickAction: Identifiable, Hashable {
    public let id: String
    public let category: QuickActionCategory
    public let label: String
    public let detail: String
    public let icon: String
    public let command: String
    public let requiresConfirm: Bool
    /// 확인 다이얼로그의 **영향 요약** (실기 UI fix, 2026-06-12).
    /// 다이얼로그 본문엔 스크립트 전문 대신 이 요약만 표시 — nil 이면 카테고리 기본 문구
    /// (`QuickActionConfirmModel.summaryText`). `requiresConfirm` 액션은 지정 권장.
    public let confirmSummary: String?
    /// 확인 다이얼로그 제목 — "~할까요?" 질문형. nil 이면 "{label} — 실행할까요?".
    public let confirmTitle: String?
    /// 확인 버튼 동사 — "재부팅"·"데모 시작" 등 1~2어절. nil 이면 "실행".
    /// danger 액션은 전용 동사 필수("확인"/"실행" 단독 금지 — QuickActionSafetyTests).
    public let confirmVerb: String?

    /// 확인 마찰 티어 — 저장 필드가 아닌 파생값: danger=홀드, confirm=시트, 그 외 즉시.
    public var confirmTier: QuickActionConfirmTier {
        if category == .danger { return .hold }
        return requiresConfirm ? .sheet : .none
    }

    public init(id: String, category: QuickActionCategory, label: String,
                detail: String, icon: String, command: String,
                requiresConfirm: Bool = false,
                confirmSummary: String? = nil,
                confirmTitle: String? = nil,
                confirmVerb: String? = nil) {
        self.id = id
        self.category = category
        self.label = label
        self.detail = detail
        self.icon = icon
        self.command = command
        self.requiresConfirm = requiresConfirm
        self.confirmSummary = confirmSummary
        self.confirmTitle = confirmTitle
        self.confirmVerb = confirmVerb
    }
}

public enum QuickActionCatalog {

    /// 패널 섹션 순서 — 빈도 내림차순, danger 는 항상 최하단 격리(기획 1.2).
    public static let sectionOrder: [QuickActionCategory] = [.robotis, .system, .bus, .service, .danger]

    /// 자주 사용하는 명령 33개 — id 는 외부 계약(PilotTests)·텔레메트리 키라 불변.
    public static let all: [QuickAction] = [
        // ── robotis (로봇 데모) — 핵심 업무, 조종기 데모가 첫 행(발견성) ──────
        QuickAction(id: "gamepad-pilot-start", category: .robotis,
                    label: "조종기 데모 시작",
                    detail: "RG G01 패드로 보행 조종 (A=ARM·B=E-STOP·LB/RB=킥)",
                    icon: "gamecontroller.fill",
                    command: RobotSetupCommand.walkLabRobotisStart,
                    requiresConfirm: true,
                    confirmSummary: "데모를 재시작해 WalkLab 조종 모드로 들어갑니다 — "
                        + "기립과 자이로 캘리브레이션에 약 20초 걸립니다. 로봇을 크래들에 "
                        + "거치하거나 평지에 세운 뒤, 패드 A(ARM)로 조종을 시작하세요. "
                        + "LB=왼발 킥 / RB=오른발 킥 — ARM 후 STANDUP 상태에서만 발화합니다.",
                    confirmTitle: "조종기 데모를 시작할까요?",
                    confirmVerb: "데모 시작"),
        QuickAction(id: "camera-start", category: .robotis, label: "카메라 데모 시작",
                    detail: "8080 포트로 카메라 영상 송출", icon: "camera.viewfinder",
                    command: RobotSetupCommand.cameraTutorialStart),
        QuickAction(id: "camera-status", category: .robotis, label: "카메라 상태 확인",
                    detail: "프로세스·8080 포트·video 장치", icon: "video.badge.checkmark",
                    command: RobotSetupCommand.cameraTutorialStatus),
        QuickAction(id: "camera-stop", category: .robotis, label: "카메라 데모 중지",
                    detail: "8080 영상 송출 종료", icon: "camera.fill.badge.ellipsis",
                    command: RobotSetupCommand.cameraTutorialStop),
        QuickAction(id: "ball-tracker-start", category: .robotis, label: "공 추적 데모 시작",
                    detail: "공을 따라 머리·보행 추적", icon: "target",
                    command: RobotSetupCommand.ballTrackerStart),
        QuickAction(id: "demo-status", category: .robotis, label: "데모 상태 확인",
                    detail: "데모 프로세스·브리지·USB 점유자", icon: "list.bullet.indent",
                    command: RobotSetupCommand.ballTrackerStatus),
        QuickAction(id: "walk-demo-start", category: .robotis, label: "걷기 데모 시작",
                    detail: "walk_tuner 보행 튜닝 진입", icon: "figure.walk.motion",
                    command: RobotSetupCommand.walkDemoStart),
        QuickAction(id: "action-demo-start", category: .robotis, label: "액션 데모 시작",
                    detail: "action_editor 모션 재생 진입", icon: "play.rectangle.fill",
                    command: RobotSetupCommand.actionDemoStart),
        // 정지·복구 동작 — 의도적 T1(멈추는 일은 쉽게).
        QuickAction(id: "demo-stop", category: .robotis, label: "데모 종료 (브리지 복구)",
                    detail: "데모를 멈추고 forge-bridge 재기동", icon: "gamecontroller",
                    command: RobotSetupCommand.demoStop),

        // Phase B (Sprint 18) — patched demo binary 자동 빌드 + 관리.
        QuickAction(id: "demo-patch-build", category: .robotis,
                    label: "패치 demo 빌드",
                    detail: "SOCCER 자동 진입용 demo-pilot 생성 (1회)",
                    icon: "hammer.fill",
                    command: RobotSetupCommand.demoBuildPatched,
                    requiresConfirm: true,
                    confirmSummary: "로봇에서 demo 를 재빌드합니다 — 약 1~2분 걸리고, "
                        + "빌드가 끝나면 원본 main.cpp 는 복구됩니다.",
                    confirmTitle: "demo 를 다시 빌드할까요?",
                    confirmVerb: "빌드 시작"),
        QuickAction(id: "demo-patch-status", category: .robotis,
                    label: "패치 demo 상태 확인",
                    detail: "demo-pilot 설치 여부",
                    icon: "checkmark.seal",
                    command: RobotSetupCommand.demoPatchedStatus),
        QuickAction(id: "demo-patch-remove", category: .robotis,
                    label: "패치 demo 제거",
                    detail: "demo-pilot 정리 — 원본 demo 유지",
                    icon: "trash",
                    command: RobotSetupCommand.demoRemovePatched,
                    requiresConfirm: true,
                    confirmSummary: "demo-pilot 바이너리와 주입 흔적을 정리합니다 — "
                        + "원본 demo 는 그대로 유지됩니다.",
                    confirmTitle: "패치 demo 를 제거할까요?",
                    confirmVerb: "제거"),
        QuickAction(id: "fuser-ttyusb", category: .robotis, label: "ttyUSB 점유자 확인",
                    detail: "USB 시리얼을 잡은 프로세스", icon: "questionmark.circle",
                    command: "sudo fuser -v /dev/ttyUSB0 2>&1"),

        // ── system (시스템 진단) — 읽기 전용 고빈도 ─────────────────────
        QuickAction(id: "uptime", category: .system, label: "가동 시간 확인",
                    detail: "부팅 후 경과 시간·부하", icon: "clock.fill",
                    command: "uptime"),
        QuickAction(id: "memory", category: .system, label: "메모리 확인",
                    detail: "사용 중·여유 메모리", icon: "memorychip",
                    command: "free -m | head -2"),
        QuickAction(id: "disk", category: .system, label: "디스크 확인",
                    detail: "홈·루트 파티션 사용량", icon: "internaldrive",
                    command: "df -h ~ | tail -1; df -h / | tail -1"),
        QuickAction(id: "cpu-temp", category: .system, label: "CPU 온도 확인",
                    detail: "현재 보드 온도", icon: "thermometer.medium",
                    command: "cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf \"%.1f°C\\n\", $1/1000}'"),
        QuickAction(id: "os-version", category: .system, label: "OS 버전 확인",
                    detail: "리눅스 배포판·커널", icon: "info.circle",
                    command: "lsb_release -a 2>/dev/null; uname -a"),
        QuickAction(id: "network", category: .system, label: "네트워크 확인",
                    detail: "인터페이스별 IP 주소", icon: "network",
                    command: "ifconfig | grep -E 'inet |^[a-z]+:' | head -10"),
        QuickAction(id: "processes", category: .system, label: "상위 프로세스 확인",
                    detail: "CPU 점유 상위 8개", icon: "list.bullet.rectangle",
                    command: "ps aux --sort=-%cpu | head -8"),

        // ── bus (버스/USB 진단) — 읽기 전용, 데모 트러블슈팅 보조 ─────────
        QuickAction(id: "tty-list", category: .bus, label: "USB 시리얼 목록 확인",
                    detail: "연결된 USB 시리얼 장치 노드", icon: "list.bullet",
                    command: "ls -la /dev/ttyUSB* /dev/ttyACM* 2>/dev/null"),
        QuickAction(id: "stty-status", category: .bus, label: "Baud rate 확인",
                    detail: "ttyUSB0 통신 설정", icon: "speedometer",
                    command: "sudo stty -F /dev/ttyUSB0 -a 2>&1 | head -3"),
        QuickAction(id: "dmesg-usb", category: .bus, label: "USB 이벤트 확인",
                    detail: "최근 USB 연결·해제 커널 로그", icon: "doc.text",
                    command: "dmesg 2>/dev/null | grep -i 'usb\\|ftdi' | tail -10"),
        QuickAction(id: "port-listen", category: .bus, label: "열린 포트 확인",
                    detail: "SSH·브리지·VNC 수신 포트", icon: "network.badge.shield.half.filled",
                    command: "ss -lnt 2>/dev/null | grep -E ':(22|139|445|5530|5900|8080)\\s' || netstat -lnt | grep -E ':(22|139|445|5530|5900|8080)'"),

        // ── service (서비스) — 셋업기 외 저빈도 ─────────────────────────
        QuickAction(id: "df-inbox-status", category: .service, label: "df-inbox 상태 확인",
                    detail: "원격 명령 수신 채널 동작 여부", icon: "tray.fill",
                    command: "sudo /etc/init.d/df-inbox status 2>/dev/null"),
        QuickAction(id: "forge-bridge-status", category: .service, label: "forge-bridge 상태 확인",
                    detail: "USB-TCP 브리지(5530) 동작 여부", icon: "antenna.radiowaves.left.and.right",
                    command: "sudo /etc/init.d/forge-bridge status 2>/dev/null; ss -lnt 2>/dev/null | grep :5530"),
        QuickAction(id: "ssh-start", category: .service, label: "SSH 켜기 (이번만)",
                    detail: "이번 부팅 동안만 SSH 활성", icon: "key.fill",
                    command: "sudo service ssh start"),
        QuickAction(id: "ssh-permanent", category: .service, label: "SSH 영구 켜기",
                    detail: "설치 후 부팅마다 자동 시작", icon: "key.horizontal.fill",
                    command: "sudo apt-get install -y --force-yes openssh-server && sudo service ssh start && sudo update-rc.d ssh defaults",
                    requiresConfirm: true,
                    confirmSummary: "openssh 를 설치하고 부팅 자동 시작에 등록합니다 — "
                        + "약 1분 걸리고, 로봇 네트워크 구성이 바뀝니다.",
                    confirmTitle: "SSH 를 영구 활성화할까요?",
                    confirmVerb: "영구 켜기"),
        QuickAction(id: "smb-restart", category: .service, label: "Samba 재시작",
                    detail: "SMB 공유 목록 갱신", icon: "externaldrive.connected.to.line.below",
                    command: "sudo service smbd restart && sudo service nmbd restart"),
        QuickAction(id: "forge-bridge-restart", category: .service, label: "forge-bridge 재시작",
                    detail: "브리지(5530) 점유 해제 후 재기동", icon: "arrow.clockwise",
                    command: "sudo killall socat 2>/dev/null; sudo /etc/init.d/forge-bridge restart"),

        // ── danger (위험 명령) — 패널 최하단 GroupBox 격리 + T3 홀드 ──────
        QuickAction(id: "reboot", category: .danger, label: "재부팅",
                    detail: "약 1~2분 오프라인", icon: "arrow.triangle.2.circlepath",
                    command: "sudo reboot",
                    requiresConfirm: true,
                    confirmSummary: "로봇이 즉시 재부팅됩니다 — 약 1~2분 오프라인이고, "
                        + "보행 중이면 그 자리에서 멈춥니다. 로봇이 서 있다면 먼저 크래들에 거치하세요.",
                    confirmTitle: "로봇을 재부팅할까요?",
                    confirmVerb: "재부팅"),
        QuickAction(id: "shutdown", category: .danger, label: "전원 끄기",
                    detail: "물리 버튼으로만 재시작", icon: "power",
                    command: "sudo poweroff",
                    requiresConfirm: true,
                    confirmSummary: "로봇 전원이 꺼집니다 — 물리 전원 버튼으로만 다시 켤 수 "
                        + "있습니다. 로봇이 서 있다면 먼저 크래들에 거치하세요.",
                    confirmTitle: "로봇 전원을 끌까요?",
                    confirmVerb: "전원 끄기"),
        QuickAction(id: "killall-socat", category: .danger, label: "브리지 강제 끊기",
                    detail: "socat 전부 종료 — LAN 연결 끊김", icon: "xmark.octagon",
                    command: "sudo killall -9 socat 2>/dev/null && echo killed all",
                    requiresConfirm: true,
                    confirmSummary: "5530 브리지가 끊겨 이 앱의 LAN 연결이 즉시 끊어집니다 — "
                        + "forge-bridge 재시작 전까지 원격 제어가 멈춥니다.",
                    confirmTitle: "브리지를 강제로 끊을까요?",
                    confirmVerb: "브리지 끊기"),
    ]

    public static func actions(in category: QuickActionCategory) -> [QuickAction] {
        all.filter { $0.category == category }
    }

    /// id → 액션 (최근 섹션·재실행 매칭용).
    public static func action(id: String) -> QuickAction? {
        all.first { $0.id == id }
    }

    /// 명령 원문 → 카탈로그 액션 (콘솔 "다시 실행"이 confirm 위계를 재경유하기 위함).
    public static func action(command: String) -> QuickAction? {
        all.first { $0.command == command }
    }
}

/// 직접 입력 명령의 위험 감지 (기획 3.5) — 차단이 아니라 1단계 확인 마찰.
/// 보수적 패턴만(오탐 회피): 전원·연결·파일시스템 파괴 계열.
public enum DangerCommandDetector {
    private static let patterns: [String] = [
        // 명령 위치(행 시작/구분자 뒤) + 명령 끝(공백/끝/구분자) — "reboot-needed"
        // 같은 파일명·인자 오탐 차단(\b 는 하이픈 앞에서도 성립해 부적합).
        #"(^|\s|;|&&|\|\|)\s*(sudo\s+)?reboot(\s|$|;)"#,
        #"(^|\s|;|&&|\|\|)\s*(sudo\s+)?poweroff(\s|$|;)"#,
        #"(^|\s|;|&&|\|\|)\s*(sudo\s+)?shutdown(\s|$|;)"#,
        #"(^|\s|;|&&|\|\|)\s*(sudo\s+)?halt(\s|$|;)"#,
        #"killall\s+(-9\s+)?socat(\s|$|;)"#,
        #"rm\s+-[a-z]*r[a-z]*f?\s+/(\s|$)"#,
        #"(^|\s|;|&&)\s*(sudo\s+)?mkfs(\.|\s)"#,
        #"(^|\s|;|&&)\s*(sudo\s+)?dd\s+if="#,
    ]

    public static func isDangerous(_ command: String) -> Bool {
        patterns.contains { command.range(of: $0, options: .regularExpression) != nil }
    }
}
