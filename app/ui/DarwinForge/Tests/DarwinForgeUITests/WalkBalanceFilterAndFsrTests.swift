import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// **Wave D2 (2026-06-12, bus-direct-teleop-upgrade §4)** — 자이로 1차 LPF 계수/동작과
/// FSR 관측 데이터(파싱·오버레이 주입)의 단위 검증.
final class WalkBalanceFilterAndFsrTests: XCTestCase {

    // MARK: - LPF 계수 (③)

    /// `α = dt/(τ+dt)`, `τ = 1/(2π·fc)`. fc=15Hz, dt=20ms → α≈0.6534.
    func testLpfAlphaDiscretization() {
        let a = FirstOrderLpf.alpha(fcHz: 15.0, dtMs: 20.0)
        let tau = 1.0 / (2.0 * Double.pi * 15.0)
        let expected = 0.02 / (tau + 0.02)
        XCTAssertEqual(a, expected, accuracy: 1e-12)
        XCTAssertEqual(a, 0.6534, accuracy: 1e-3, "fc=15Hz·dt=20ms 계수")
        // dt 가 짧을수록(폴 빨라질수록) α 작아짐(더 매끄럽게) — 단조성.
        XCTAssertLessThan(FirstOrderLpf.alpha(fcHz: 15, dtMs: 10),
                          FirstOrderLpf.alpha(fcHz: 15, dtMs: 20), "dt↓ → α↓")
    }

    /// 첫 샘플은 슬루 없이 그대로 수용(수렴 지연 0).
    func testLpfSeedsOnFirstSample() {
        var lpf = FirstOrderLpf()
        XCTAssertEqual(lpf.update(42, fcHz: 15, dtMs: 20), 42, "첫 샘플 즉시 수용")
        XCTAssertTrue(lpf.seeded)
    }

    /// DC(상수) 입력은 통과, 계단 입력은 목표로 단조 수렴.
    func testLpfStepResponseConverges() {
        var lpf = FirstOrderLpf()
        lpf.update(0, fcHz: 15, dtMs: 20)        // seed at 0
        var prev = 0.0
        for _ in 0..<20 {
            let y = lpf.update(100, fcHz: 15, dtMs: 20)
            XCTAssertGreaterThan(y, prev, "계단 응답 단조 증가")
            XCTAssertLessThanOrEqual(y, 100.0, "목표 초과 없음")
            prev = y
        }
        XCTAssertEqual(prev, 100, accuracy: 1.0, "20스텝 후 ~목표 수렴")
    }

    /// 고주파(매 스텝 부호 반전) 입력은 진폭이 감쇠된다(노이즈 억제).
    func testLpfAttenuatesHighFrequency() {
        var lpf = FirstOrderLpf()
        lpf.update(0, fcHz: 15, dtMs: 20)
        var maxAbs = 0.0
        for i in 0..<40 {
            let sample = (i % 2 == 0) ? 100.0 : -100.0
            maxAbs = max(maxAbs, abs(lpf.update(sample, fcHz: 15, dtMs: 20)))
        }
        XCTAssertLessThan(maxAbs, 100.0, "±100 고주파 입력의 출력 진폭 < 입력")
    }

    func testLpfResetClearsSeed() {
        var lpf = FirstOrderLpf()
        lpf.update(50, fcHz: 15, dtMs: 20)
        lpf.reset()
        XCTAssertFalse(lpf.seeded)
        XCTAssertEqual(lpf.update(7, fcHz: 15, dtMs: 20), 7, "reset 후 첫 샘플 즉시 수용")
    }

    /// 차단 주파수 상수가 온보드 O3-2 와 동일(15Hz) — 패리티 회귀 가드. dt=50Hz 기준.
    func testGyroBalanceFilterConstants() {
        XCTAssertEqual(GyroBalanceFilter.cutoffHz, 15.0)
        XCTAssertEqual(GyroBalanceFilter.nominalDtMs, 20.0, "직결 50Hz 보정 주입 주기")
    }

    // MARK: - FSR 파싱 / 오버레이 (③)

    /// FsrReading 4셀 raw → total 압력 합산(파싱 결과 소비).
    func testFsrTotalPressure() {
        let fsr = FsrReading(id: 111, cellFrontLeft: 100, cellFrontRight: 200,
                             cellRearRight: 300, cellRearLeft: 400, centerX: -10, centerY: 20)
        XCTAssertEqual(fsr.totalPressureRaw, 1000, "4셀 합")
        XCTAssertEqual(fsr.id, 111, "우측 발")
        XCTAssertEqual(fsr.centerX, -10)
    }

    /// SceneOverlayData 가 좌/우 FSR 를 그대로 운반(오버레이 소비자 입력 계약).
    func testSceneOverlayCarriesFsr() {
        let left = FsrReading(id: 112, cellFrontLeft: 1, cellFrontRight: 2,
                              cellRearRight: 3, cellRearLeft: 4, centerX: 0, centerY: 0)
        let right = FsrReading(id: 111, cellFrontLeft: 5, cellFrontRight: 6,
                               cellRearRight: 7, cellRearLeft: 8, centerX: 1, centerY: -1)
        let overlay = SceneOverlayData(fsrLeft: left, fsrRight: right)
        XCTAssertEqual(overlay.fsrLeft?.id, 112)
        XCTAssertEqual(overlay.fsrRight?.id, 111)
        XCTAssertEqual(overlay.fsrLeft?.totalPressureRaw, 10)
    }
}
