import Foundation

/// DarwinForge 한국어 UX 라이팅 상수.
///
/// 근거:
/// - 토스 8가지 라이팅 원칙 (toss.tech/article/8-writing-principles-of-toss)
/// - 앱인토스 UX 라이팅 (해요체, "닫기" 통일)
/// - 토스 에러 메시지 시스템 (왜·무엇·할 일 3단)
/// - ROBOTIS e-Manual 한국어 표기
/// - KS S ISO 7010 안전 표지
///
/// 모든 사용자 노출 문자열은 이 파일에서 관리해 단어 일관성을 강제한다.
public enum KoreanUX {

    // MARK: - 공용 액션

    public enum Action {
        public static let confirm = "이대로 진행할까요?"
        public static let close = "닫기"      // ❌ 취소 (앱인토스 규정)
        public static let execute = "실행"
        public static let retry = "다시 시도"
        public static let viewDetails = "상세보기"
        public static let cancel = "닫기"     // 같음. compatibility alias.
        public static let back = "뒤로"
        public static let next = "다음"
        public static let finish = "완료"
        public static let save = "저장"
        public static let delete = "삭제"
        public static let edit = "편집"
        public static let send = "보내기"
        public static let stop = "중단"
    }

    // MARK: - 단어 통일 사전 (도메인 → 비전문가 한국어)

    public enum Term {
        public static let robot = "로봇"
        public static let joint = "관절"
        public static let force = "힘"          // ❌ 토크 (전문 화면 외 금지)
        public static let motion = "동작"        // ❌ 모션, 액션
        public static let wakeUp = "깨우기"      // 토크 ON
        public static let goSleep = "재우기"     // 토크 OFF
        public static let goalPosition = "보낼 위치"
        public static let presentPosition = "지금 위치"
        public static let bus = "통신 라인"
        public static let statusPacket = "응답 신호"
        public static let shutdown = "자동 차단"
        public static let compliance = "관절 부드럽기"
        public static let syncWrite = "한꺼번에 보내기"
        public static let estop = "긴급정지"
        public static let battery = "배터리"
        public static let temperature = "온도"
        public static let voltage = "전압"
    }

    // MARK: - 환영 / 빈 상태

    public enum Welcome {
        public static let greeting = "안녕하세요!"
        public static let prompt = "로봇에게 무엇을 시키고 싶으세요?"
        public static let hint = "/ 명령 · @ 자원 · ⌘L 음성 (준비 중)"

        /// 비어있을 때 보여줄 4개 추천 명령 (Gemini 패턴)
        public static let suggestions: [String] = [
            "로봇 깨워줘",
            "지금 어때?",
            "왼팔 들어",
            "천천히 한 발 앞으로"
        ]
    }

    // MARK: - 모드 / 연결

    public enum Mode {
        public static let simulation = "시뮬"
        public static let hardware = "실기"
        public static let offline = "오프라인"

        public static let simulationDescription = "안전한 시뮬레이션 모드 — 실 로봇으로 명령이 가지 않아요"
        public static let hardwareDescription = "실 로봇 모드 — 명령이 그대로 USB로 전송돼요"
        public static let offlineDescription = "USB 케이블이 연결되지 않았어요"
    }

    public enum Connection {
        public static let connecting = "USB 케이블로 로봇과 연결할게요"
        public static let connected = "로봇과 연결됐어요"
        public static let connectFailed = "연결을 다시 시도해 볼게요"
        public static let noPort = "USB 직렬 포트가 없어요. 케이블을 확인해 주세요"
        public static let driverMissing = "USB 드라이버가 꺼져 있어요. 시스템 설정에서 켜야 해요"
        public static let portBusy = "다른 프로그램이 로봇을 잡고 있어요. 먼저 그 프로그램을 닫아주세요"
        public static let macSandbox = "macOS가 USB 접근을 막고 있어요. '시스템 설정 > 개인정보 보호'에서 허용해 주세요"

        public static func portsFound(_ count: Int) -> String {
            "\(count)개의 포트를 찾았어요"
        }
        public static func jointsFound(_ ids: [Int]) -> String {
            "관절 \(ids.count)개를 찾았어요"
        }
    }

    // MARK: - 동작 / 모터

    public enum Motion {
        public static let wakeUpStart = "로봇을 일으킬게요. 잠깐 시간 주세요."
        public static let wakeUpDone = "관절 20개에 모두 힘이 들어갔어요. 살짝 자세를 잡아요."
        public static let sleepStart = "안전 자세로 천천히 앉을게요."
        public static let sleepDone = "관절 힘을 풀었어요. 손으로 받쳐주세요."

        public static func setPositionPreview(joint: String, deg: Double) -> String {
            "\(joint)을(를) \(Int(abs(deg)))° \(deg >= 0 ? "올릴" : "내릴")게요. 진행할까요?"
        }
        public static func clamped(from: Int, to: Int) -> String {
            "목표 위치가 안전 범위(\(to))로 자동 조정됐어요"
        }
        public static func walking(stepCm: Double) -> String {
            "한 걸음에 \(Int(stepCm))cm씩 걸을게요"
        }
        public static let approaching = "공으로 다가가는 중이에요"
        public static let kicking = "차기 동작을 시작했어요"
        public static let cooldown = "잠깐 멈춰서 자세를 다시 잡고 있어요"
    }

    // MARK: - 안전 / 경고

    public enum Safety {
        public static let estopTriggered = "비상 정지! 모든 관절의 힘을 풀었어요. 로봇이 천천히 주저앉으니 손으로 받쳐주세요."
        public static let estopHint = "ESC 키 또는 좌상단 빨간 버튼"

        public static func batteryLow(_ volts: Double) -> String {
            "배터리가 거의 없어요 (\(String(format: "%.1f", volts))V). 5분 안에 충전하지 않으면 곧 멈춰요."
        }
        public static func motorOverheat(joint: String, celsius: Int) -> String {
            "\(joint) 모터가 과열됐어요 (\(celsius)°C). 5분 쉬어야 해요."
        }
        public static let selfCollision = "이 자세로 가면 로봇이 자기 몸과 부딪혀요. 동작을 진행하지 않을게요."
        public static let nearFall = "로봇이 30° 넘게 기울었어요. 손으로 잡아주세요."
        public static let conflictingCommand = "두 명령이 부딪혔어요. 가장 마지막 명령을 따랐어요."
        public static let watchdogLost = "로봇과 신호가 끊겼어요. 케이블을 확인해 주세요."
    }

    // MARK: - 에러 (토스 3단 구조)

    public struct ErrorMessage {
        public let title: String        // 무엇이 일어났는지
        public let body: String         // 왜 + 무엇을 시도했는지 + 사용자가 할 일
        public let action: String?      // 액션 라벨 (Optional)
        public let rawDetail: String?   // (상세보기) 영문 raw

        public init(title: String, body: String, action: String? = nil, rawDetail: String? = nil) {
            self.title = title
            self.body = body
            self.action = action
            self.rawDetail = rawDetail
        }
    }

    public enum Errors {
        public static func disconnected(raw: String) -> ErrorMessage {
            ErrorMessage(
                title: "로봇과 연결이 끊겼어요",
                body: "USB를 다시 인식하려 시도했지만 실패했어요. 케이블을 뽑았다 다시 꽂아주세요.",
                action: "다시 연결",
                rawDetail: raw
            )
        }
        public static let claudeNotInstalled = ErrorMessage(
            title: "Claude CLI가 설치되어 있지 않아요",
            body: "터미널에서 `brew install --cask claude-cli`로 설치한 다음 앱을 다시 시작해 주세요.",
            action: "복사하기",
            rawDetail: "command not found: claude"
        )
        public static let claudeAuthExpired = ErrorMessage(
            title: "Claude 로그인이 만료됐어요",
            body: "터미널에서 `claude login`을 실행해 다시 로그인해 주세요.",
            action: nil,
            rawDetail: nil
        )
        public static let claudeRateLimit = ErrorMessage(
            title: "잠시만 기다려 주세요",
            body: "Claude가 잠깐 바빠요. 자동으로 다시 시도할게요.",
            action: nil,
            rawDetail: "rate_limit_error"
        )
        public static let parseFailed = ErrorMessage(
            title: "응답을 이해하지 못했어요",
            body: "다시 한 번 말씀해 주실래요? 더 짧고 명확한 문장이 좋아요.",
            action: nil,
            rawDetail: nil
        )
        public static func unknownTool(_ name: String) -> ErrorMessage {
            ErrorMessage(
                title: "지원하지 않는 동작이에요",
                body: "이 명령(\(name))은 아직 만들어지지 않았어요. 다른 표현으로 시도해 보세요.",
                action: nil,
                rawDetail: name
            )
        }
        public static func refused(reason: String) -> ErrorMessage {
            ErrorMessage(
                title: "이 명령은 진행하기 어려워요",
                body: reason,
                action: nil,
                rawDetail: nil
            )
        }
    }

    // MARK: - 관절 한글 이름

    public enum JointName {
        public static func from(rawId: Int) -> String {
            switch rawId {
            case 1: return "오른쪽 어깨 (앞뒤)"
            case 2: return "왼쪽 어깨 (앞뒤)"
            case 3: return "오른쪽 어깨 (옆)"
            case 4: return "왼쪽 어깨 (옆)"
            case 5: return "오른쪽 팔꿈치"
            case 6: return "왼쪽 팔꿈치"
            case 11: return "오른쪽 고관절 (회전)"
            case 12: return "왼쪽 고관절 (회전)"
            case 13: return "오른쪽 고관절 (옆)"
            case 14: return "왼쪽 고관절 (옆)"
            case 15: return "오른쪽 고관절 (앞뒤)"
            case 16: return "왼쪽 고관절 (앞뒤)"
            case 17: return "오른쪽 무릎"
            case 18: return "왼쪽 무릎"
            case 19: return "고개 (좌우)"
            case 20: return "고개 (위아래)"
            case 200: return "허리 컨트롤러"
            case 254: return "전체 (브로드캐스트)"
            case 111: return "오른쪽 발 압력 센서"
            case 112: return "왼쪽 발 압력 센서"
            default: return "관절 \(rawId)번"
            }
        }
    }

    // MARK: - 진행 상태 (Toast / Inline)

    public enum Progress {
        public static let thinking = "잠깐 생각 중이에요…"
        public static let connecting = "연결하는 중…"
        public static let scanning = "관절을 찾는 중…"
        public static let executing = "동작을 보내는 중…"
        public static let saved = "저장했어요"
    }
}
