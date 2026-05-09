import ArgumentParser
import DynamixelKit
import RobotKit

@main
struct DarwinForgeCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darwinforge",
        abstract: "Headless utilities for DARwIn-OP / OP2 maintenance.",
        subcommands: [Ping.self, ListJoints.self]
    )
}

extension DarwinForgeCLI {
    struct Ping: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Ping the CM-730/CM-740 sub-controller (ID 200)."
        )

        @Option(name: .shortAndLong, help: "USB serial path, e.g. /dev/cu.usbserial-A1B2.")
        var port: String

        func run() async throws {
            // TODO: wire SerialPortKit + DynamixelKit and fail loudly if no
            // controller answers. Skeleton only for now.
            print("[stub] would ping ID \(SpecialID.controller) at \(port)")
        }
    }

    struct ListJoints: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list-joints",
            abstract: "Print the canonical 20-DOF joint table."
        )

        func run() {
            for j in JointID.allCases {
                print("ID \(j.rawValue)\t\(j)\t(\(j.bodyPart))")
            }
        }
    }
}
