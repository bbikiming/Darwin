import Foundation

/// macOS-only serial-port abstraction. The production implementation
/// will wrap IOKit (`IOKit/serial`) directly; this skeleton exists so
/// downstream packages can depend on the protocol surface today.
public protocol SerialPort: Sendable {
    var path: String { get }
    var baudRate: Int { get }

    func open() async throws
    func close() async throws
    func write(_ bytes: [UInt8]) async throws
    func read(maxLength: Int, timeout: Duration) async throws -> [UInt8]
}

public struct SerialPortDescriptor: Sendable, Equatable {
    public let path: String
    public let displayName: String
    public let bsdName: String

    public init(path: String, displayName: String, bsdName: String) {
        self.path = path
        self.displayName = displayName
        self.bsdName = bsdName
    }
}

public enum SerialPortError: Error, Equatable {
    case notFound(String)
    case alreadyOpen
    case notOpen
    case ioError(String)
}

/// Lists candidate USB-serial ports for a CM-730 / CM-740 connection.
/// Production will scan `/dev/cu.usbserial-*` and `/dev/cu.usbmodem*`.
public enum SerialPortDiscovery {
    public static func scan() throws -> [SerialPortDescriptor] {
        // TODO: enumerate via IOKit `IOServiceMatching(kIOSerialBSDServiceValue)`
        // and filter to USB CDC / FTDI VID:PID pairs known to be CM-730/740.
        []
    }
}
