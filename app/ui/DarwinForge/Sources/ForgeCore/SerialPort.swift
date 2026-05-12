import CForgeCore
import Foundation

/// 사용 가능한 USB 직렬 포트 디바이스 노드 enumerator.
public enum SerialPortEnumerator {
    /// 현재 호스트에서 보이는 USB 직렬 포트 경로 목록.
    /// macOS: `/dev/cu.usbserial-*`, `/dev/cu.usbmodem*` 등.
    public static func available() throws -> [String] {
        var err: Int32 = FC_OK
        guard let raw = fc_serial_list_ports(&err) else {
            if err == FC_OK { return [] }
            throw ForgeError.from(err) ?? .generic
        }
        guard let s = consumeForgeString(raw) else { return [] }
        return s
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}

/// `forge-core` 버전.
public func forgeCoreVersion() -> String {
    consumeForgeString(fc_version()) ?? "unknown"
}
