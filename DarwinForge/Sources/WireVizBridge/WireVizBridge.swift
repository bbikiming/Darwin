import Foundation
import HarnessKit

/// Shells out to the Python `wireviz` CLI to render a YAML harness file
/// to SVG/PNG. The Mac app shows a friendly install hint when the
/// binary is not on `PATH`.
public struct WireVizBridge: Sendable {
    public let pythonPath: String
    public let wirevizModule: String

    public init(pythonPath: String = "/usr/bin/python3",
                wirevizModule: String = "wireviz") {
        self.pythonPath = pythonPath
        self.wirevizModule = wirevizModule
    }

    public func render(yamlURL: URL, outputPrefix: String) async throws {
        // TODO: spawn `python3 -m wireviz <yamlURL>` with `Process` and
        // capture rendered SVG + BOM. Stubbed until the macOS shell
        // wrapper module lands.
        _ = yamlURL
        _ = outputPrefix
    }
}
