import Foundation

/// **Wave D2 (2026-06-12, bus-direct-teleop-upgrade §4)** — 자이로 각속도 입력의
/// 1차(IIR) 저역 통과 필터.
///
/// # 비유
///
/// 50Hz 로 자주 들여다보면 손떨림(raw MEMS 노이즈)까지 또렷이 보인다. LPF 는 흔들리는
/// 손으로 찍은 연사 사진을 살짝 겹쳐 평균 내는 것 — 큰 움직임(기울임 rate)은 남기고
/// 고주파 떨림만 지운다. 50Hz 로 보정을 주입(D2)하면 raw ADC 노이즈가 D항을 지배해
/// 진동/limit-cycle 을 부를 수 있어, 보정 입력 직전에 ~15Hz 위로만 깎는다.
///
/// # 이산화
///
/// 1차 LPF `y += α(x − y)`, `α = dt / (τ + dt)`, `τ = 1/(2π·fc)`.
/// α 는 **step 주기(dt) 기준**으로 산출한다(직결 50Hz → dt=20ms → α≈0.65 @ fc=15Hz).
///
/// 순수 struct 라 계수·수렴을 실시간 없이 단위 테스트한다. `seeded=false` 첫 샘플은
/// 그대로 수용(수렴 지연 0).
public struct FirstOrderLpf: Equatable, Sendable {
    public private(set) var value: Double
    public private(set) var seeded: Bool

    public init() {
        value = 0
        seeded = false
    }

    /// 이산 1차 LPF 계수. `α = dt/(τ+dt)`, `τ = 1/(2π·fc)`.
    public static func alpha(fcHz: Double, dtMs: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * max(0.01, fcHz))
        let dt = max(0.0001, dtMs / 1000.0)
        return dt / (tau + dt)
    }

    /// 한 샘플 전진. 첫 샘플은 슬루/수렴 지연 없이 그대로 수용.
    @discardableResult
    public mutating func update(_ sample: Double, fcHz: Double, dtMs: Double) -> Double {
        guard seeded else {
            value = sample
            seeded = true
            return value
        }
        let a = Self.alpha(fcHz: fcHz, dtMs: dtMs)
        value = a * sample + (1.0 - a) * value
        return value
    }

    /// 보행 시작 시 재초기화(다음 update 가 첫 샘플을 그대로 수용).
    public mutating func reset() {
        value = 0
        seeded = false
    }
}

public enum GyroBalanceFilter {
    /// 자이로 보정 입력 LPF 차단 주파수(Hz).
    /// 출처: 온보드 O3-2(`walklab-onboard-teleop-upgrade.md`)의 동일 1차 LPF 설계값과
    /// 동일(fc≈15Hz) — 변경 시 양쪽 동시. 정상 보행/기울임 rate(±수십~150°/s)는 통과,
    /// 고주파 MEMS 노이즈만 차단.
    public static let cutoffHz: Double = 15.0

    /// LPF 이산화 기준 dt — 직결 50Hz 보정 주입 주기(step 20ms).
    public static let nominalDtMs: Double = Double(WalkDenseStreaming.denseStepMs)
}
