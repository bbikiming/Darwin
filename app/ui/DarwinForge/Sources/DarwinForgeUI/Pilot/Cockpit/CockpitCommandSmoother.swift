import Foundation

/// Cockpit 조종 명령(`WalkingCommand`)의 **프레임간 스무딩 + 다축 결합 안전한계**.
///
/// # 비유
///
/// 자동차 가속 페달을 갑자기 끝까지 밟아도 엔진이 단계적으로 회전수를 올리듯, stick
/// 입력이 급변해도 모터로 가는 보행 진폭을 부드럽게 ramp 시킨다(EMA). 또 핸들·가속을
/// 동시에 끝까지 쓰면 차가 미끄러지듯, 전진·측면·회전을 동시에 최대로 주면 보행이
/// 불안정해지므로 결합 크기를 안정 범위로 정규화한다(combinedClamp).
///
/// 모두 **순수 함수** — 단위 테스트 가능, 디지털 트윈(화면·시뮬·모터 동일 입력) 보존.
enum CockpitCommandSmoother {

    /// 1차 지수이동평균(EMA) — `prev` 를 `target` 으로 `alpha` 만큼 당긴다.
    /// alpha=1 이면 즉시(스무딩 없음), 0 이면 정지. 30Hz 에서 0.25 ≈ 0.3s ramp.
    static func ema(_ prev: Double, _ target: Double, alpha: Double) -> Double {
        let a = max(0.0, min(1.0, alpha))
        return prev + (target - prev) * a
    }

    /// **다축 결합 안전한계** — 정규화 결합크기 `n = √(Σ(axis/max)²)` 가 1을 넘으면
    /// 세 축을 `/n` 비례 축소해 안정 보행 envelope 안으로 되돌린다.
    ///
    /// 단일 축 전속(예: 전진만 max → n=1)은 **불변**. 전진+측면+회전을 동시에 크게
    /// 주는 경우에만 작동해, 방향 비율은 보존하면서 총량만 안전하게 줄인다.
    static func combinedClamp(_ cmd: WalkingCommand,
                              strideMax: Double,
                              sideMax: Double,
                              turnMax: Double) -> WalkingCommand {
        let sx = strideMax > 0 ? cmd.strideMm / strideMax : 0
        let sy = sideMax  > 0 ? cmd.sideMm   / sideMax  : 0
        let st = turnMax  > 0 ? cmd.turnDeg  / turnMax  : 0
        let n = (sx * sx + sy * sy + st * st).squareRoot()
        guard n > 1.0 else { return cmd }
        return WalkingCommand(strideMm: cmd.strideMm / n,
                              sideMm:   cmd.sideMm / n,
                              turnDeg:  cmd.turnDeg / n)
    }

    /// 한 tick 스무딩: **EMA 추종 → 결합 안전한계 → 미세값 snap-to-zero**.
    ///
    /// EMA 는 점근이라 정확히 0에 도달하지 못한다. 정지(target 0) 시 미세 잔류를 0으로
    /// snap 해 `WalkingCommand.isStop` 이 성립하도록 한다(잔존 보행 방지).
    static func step(current: WalkingCommand,
                     target: WalkingCommand,
                     alpha: Double,
                     strideMax: Double,
                     sideMax: Double,
                     turnMax: Double) -> WalkingCommand {
        let blended = WalkingCommand(
            strideMm: ema(current.strideMm, target.strideMm, alpha: alpha),
            sideMm:   ema(current.sideMm,   target.sideMm,   alpha: alpha),
            turnDeg:  ema(current.turnDeg,  target.turnDeg,  alpha: alpha))
        let limited = combinedClamp(blended,
                                    strideMax: strideMax,
                                    sideMax: sideMax,
                                    turnMax: turnMax)
        return WalkingCommand(
            strideMm: abs(limited.strideMm) < 0.5 ? 0 : limited.strideMm,
            sideMm:   abs(limited.sideMm)   < 0.5 ? 0 : limited.sideMm,
            turnDeg:  abs(limited.turnDeg)  < 0.3 ? 0 : limited.turnDeg)
    }
}
