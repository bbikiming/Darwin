import Foundation

// MARK: - HarnessKoreanLabels (V290-A, 2026-05-25)
//
// 비유: 이 파일은 "전문용어 해설 사전". 약어 옆에 한글 풀네임을 병기하여
// 신규 사용자·외부 검수자도 화면의 의미를 즉시 파악할 수 있도록 한다.
//
// 기술: Nielsen Heuristic #6 "Recognition over Recall" 적용.
// 모든 센서 약어·이벤트 종류 라벨을 한 곳에 정의하여 5개 뷰에서 재사용.
// 로직·구조 무변경 — 텍스트 라벨만 변경.

// MARK: - SensorLabel

/// 실시간 센서 데이터 화면에 표시되는 약어에 한글 풀네임을 병기한 라벨 사전.
public enum SensorLabel {
    case imu
    case dxl
    case dxlPower
    case zmp
    case cop
    case fsr
    case eStop
    case heartbeat
    case bus
    case gyro
    case accel
    case roll
    case pitch
    case yaw
    case rtt
    case preflight

    /// 약어 + 한글 풀네임 병기 표시명.
    public var displayName: String {
        switch self {
        case .imu:       return "IMU (관성 측정)"
        case .dxl:       return "DXL (다이나믹셀 모터)"
        case .dxlPower:  return "모터 전원 (dxlPower)"
        case .zmp:       return "ZMP (영점 모멘트)"
        case .cop:       return "CoP (압력 중심)"
        case .fsr:       return "FSR (발바닥 압력 센서)"
        case .eStop:     return "비상 정지 (E-Stop)"
        case .heartbeat: return "심박 신호 (heartbeat)"
        case .bus:       return "통신 버스 (bus)"
        case .gyro:      return "자이로 (각속도)"
        case .accel:     return "가속도"
        case .roll:      return "roll (좌우 기울기)"
        case .pitch:     return "pitch (앞뒤 기울기)"
        case .yaw:       return "yaw (좌우 회전)"
        case .rtt:       return "RTT (왕복 지연)"
        case .preflight: return "출발 전 점검 (preflight)"
        }
    }

    /// 상단 상태바 셀처럼 공간이 좁을 때 사용하는 짧은 라벨.
    public var shortLabel: String {
        switch self {
        case .imu:       return "IMU 관성"
        case .dxl:       return "DXL 모터"
        case .dxlPower:  return "모터 전원"
        case .zmp:       return "ZMP"
        case .cop:       return "CoP"
        case .fsr:       return "FSR"
        case .eStop:     return "비상 정지"
        case .heartbeat: return "심박 신호"
        case .bus:       return "통신 버스"
        case .gyro:      return "자이로"
        case .accel:     return "가속도"
        case .roll:      return "roll 좌우"
        case .pitch:     return "pitch 앞뒤"
        case .yaw:       return "yaw 회전"
        case .rtt:       return "RTT 지연"
        case .preflight: return "출발 전 점검"
        }
    }

    /// hover 툴팁 — 약어 풀네임 설명.
    public var tooltip: String {
        switch self {
        case .imu:
            return "IMU: Inertial Measurement Unit — 가속도계·자이로스코프로 로봇 자세를 측정하는 관성 센서"
        case .dxl:
            return "DXL: Dynamixel — ROBOTIS 사의 스마트 서보 모터 시리즈"
        case .dxlPower:
            return "dxlPower: Dynamixel 모터 전원 공급 ON/OFF 상태"
        case .zmp:
            return "ZMP: Zero Moment Point — 로봇이 넘어지지 않고 균형을 유지하기 위한 영점 모멘트 지점"
        case .cop:
            return "CoP: Center of Pressure — 발바닥이 지면에 가하는 힘의 합력 작용점 (압력 중심)"
        case .fsr:
            return "FSR: Force-Sensitive Resistor — 발바닥에 부착된 압력 감지 센서"
        case .eStop:
            return "E-Stop: Emergency Stop — 즉각 모터 전원을 차단하는 비상 정지 명령"
        case .heartbeat:
            return "heartbeat: 제어 루프가 정상 작동 중임을 알리는 주기적 신호 (1 Hz 기준)"
        case .bus:
            return "bus: Dynamixel U2D2 USB-RS485 통신 버스 — 모터와 소프트웨어를 연결"
        case .gyro:
            return "gyro: Gyroscope — 각속도(°/s)를 측정하는 센서. 자세 변화율 추정에 사용"
        case .accel:
            return "accel: Accelerometer — 선형 가속도(m/s²)를 측정하는 센서"
        case .roll:
            return "roll: 로봇의 좌우 기울기 각도 (X축 회전, °)"
        case .pitch:
            return "pitch: 로봇의 앞뒤 기울기 각도 (Y축 회전, °)"
        case .yaw:
            return "yaw: 로봇의 좌우 수평 회전 각도 (Z축 회전, °)"
        case .rtt:
            return "RTT: Round-Trip Time — 제어 명령이 모터까지 갔다 돌아오는 왕복 지연 시간 (ms)"
        case .preflight:
            return "preflight: 출발 전 점검 — 보행 세션 시작 전 안전·연결 상태를 자동으로 확인하는 체크리스트"
        }
    }
}

// MARK: - EventKindLabel

/// TelemetryEvent.Kind 별 한글 라벨 사전.
public enum EventKindLabel {
    case walklab
    case motion
    case pilot
    case teach
    case conversation
    case claude

    /// 영문 + 한글 병기 표시명.
    public var displayName: String {
        switch self {
        case .walklab:      return "WalkLab (보행 실험)"
        case .motion:       return "Motion (모션)"
        case .pilot:        return "Pilot (조종)"
        case .teach:        return "Teach (티칭)"
        case .conversation: return "대화 (conversation)"
        case .claude:       return "Claude (AI)"
        }
    }

    /// Kind rawValue prefix 에서 EventKindLabel 매핑.
    public static func from(kindRawValue: String) -> EventKindLabel? {
        let lower = kindRawValue.lowercased()
        if lower.hasPrefix("walklab") { return .walklab }
        if lower.hasPrefix("motion")  { return .motion }
        if lower.hasPrefix("pilot")   { return .pilot }
        if lower.hasPrefix("teach")   { return .teach }
        if lower.hasPrefix("conversation") { return .conversation }
        if lower.hasPrefix("claude")  { return .claude }
        return nil
    }
}
