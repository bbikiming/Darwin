import Foundation
import ForgeCore

/// 자동 USB 포트 감지 헬퍼.
/// `/dev/cu.usbserial-*`, `/dev/cu.usbmodem*` 등 ROBOTIS / FTDI / Silicon Labs
/// 디바이스 후보를 우선 추천.
public enum AutoConnect {

    /// 가장 ROBOTIS 가능성이 높은 포트 추정.
    /// 점수: usbserial > usbmodem > 기타. bluetooth/dn-는 감점.
    public static func bestGuess(among ports: [String]) -> String? {
        let scored: [(score: Int, path: String)] = ports.map { p in
            let lower = p.lowercased()
            var score = 0
            if lower.contains("usbserial") { score += 20 }    // FTDI 주류
            if lower.contains("usbmodem")  { score += 12 }
            if lower.contains("ftdi")      { score += 5 }
            if lower.contains("slab")      { score += 5 }     // Silicon Labs
            // bluetooth, dn-, debug-console은 감점.
            if lower.contains("bluetooth") { score -= 50 }
            if lower.hasPrefix("/dev/cu.dn-") { score -= 30 }
            if lower.contains("debug-console") { score -= 20 }
            return (score, p)
        }
        let viable = scored.filter { $0.score >= 0 }
        return viable.max(by: { $0.score < $1.score })?.path
    }

    /// 추천 포트가 있으면 그것을 select하고, 없어도 하나가 보이면 첫 번째 채택.
    public static func suggestPort() -> String? {
        let ports = (try? SerialPortEnumerator.available()) ?? []
        if let best = bestGuess(among: ports) { return best }
        return ports.first
    }

    /// 포트가 발견될 가능성을 한 줄로 — 첫 진입 가이드 카드에 사용.
    public static func reasonForNoPort() -> String {
        return "USB 케이블이 꽂혔는지, 로봇 전원이 켜져 있는지 확인해 주세요."
    }
}

// MARK: - 단위 테스트용 동작 명세 (DarwinForgeUI 모듈에선 외부 테스트 불가능하지만
// 호출 가능한 형태로 노출 — Tests/ForgeCoreTests에서 모방한다).

#if DEBUG
public enum AutoConnectTestVectors {
    public static let inputs: [(label: String, ports: [String], expected: String?)] = [
        ("usbserial 우선",
         ["/dev/cu.usbmodem11201", "/dev/cu.usbserial-AB0123"],
         "/dev/cu.usbserial-AB0123"),
        ("usbmodem만 있을 때",
         ["/dev/cu.usbmodem11201"],
         "/dev/cu.usbmodem11201"),
        ("Bluetooth는 절대 선택 안 함",
         ["/dev/cu.Bluetooth-Incoming-Port", "/dev/cu.usbserial-X"],
         "/dev/cu.usbserial-X"),
        ("Bluetooth만 있으면 nil",
         ["/dev/cu.Bluetooth-Incoming-Port"],
         nil),
        ("빈 배열은 nil",
         [],
         nil)
    ]
}
#endif
