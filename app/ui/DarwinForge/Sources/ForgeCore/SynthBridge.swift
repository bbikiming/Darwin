//  SynthBridge.swift — Sprint 11 (Motion Synthesis SwiftUI 통합).
//
//  Swift UI 가 `forge synth ...` CLI 를 외부 호출해 결과 Motion JSON 을 받는다.
//  FFI 직접 노출 대신 CLI 호출로 단순화 — forge-cli/src/synth.rs 의 안전 게이트
//  + 백업 정책을 그대로 사용.
//
//  본 모듈은 macOS sandbox 외부 명령 실행이 필요하므로 entitlement 설정 시
//  활성화. 미설정 환경에서는 `executeForgeSynth` 가 `.commandUnavailable` 반환.

import Foundation

/// `forge synth ...` 호출 결과.
public enum SynthBridgeError: Error, Equatable {
    case commandUnavailable
    case nonZeroExit(code: Int32, stderr: String)
    case decodeFailed(String)
}

/// Synth 호출 결과 — Motion JSON 텍스트 또는 에러.
public struct SynthResult {
    public let motionJSON: String
    public let stderr: String

    public init(motionJSON: String, stderr: String) {
        self.motionJSON = motionJSON
        self.stderr = stderr
    }
}

/// Synth bridge — 외부 CLI 호출 + 결과 파싱.
public struct SynthBridge {
    /// `forge` 바이너리 경로. 기본은 workspace 내 `target/debug/forge`.
    public let forgePath: String
    /// `motion_4096.bin` 경로. 환경변수 `FORGE_MOTION_BIN` 으로 자식 프로세스에 전달.
    public let motionBinPath: String?
    /// Workspace 루트 (`cargo run` 의 manifest 위치).
    public let workspaceRoot: String

    public init(
        forgePath: String = "cargo",
        motionBinPath: String? = nil,
        workspaceRoot: String = FileManager.default.currentDirectoryPath
    ) {
        self.forgePath = forgePath
        self.motionBinPath = motionBinPath
        self.workspaceRoot = workspaceRoot
    }

    /// `forge synth <args>` 실행. 표준 출력을 motion JSON 으로 반환.
    public func executeForgeSynth(_ args: [String]) -> Result<SynthResult, SynthBridgeError> {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        if forgePath == "cargo" {
            // workspace 모드 — cargo run -p forge-cli --quiet --manifest-path ... -- synth ...
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            var fullArgs = [
                "cargo",
                "run",
                "--quiet",
                "--manifest-path",
                "\(workspaceRoot)/app/core/Cargo.toml",
                "-p",
                "forge-cli",
                "--",
                "synth",
            ]
            fullArgs.append(contentsOf: args)
            process.arguments = fullArgs
        } else {
            process.executableURL = URL(fileURLWithPath: forgePath)
            process.arguments = ["synth"] + args
        }

        var env = ProcessInfo.processInfo.environment
        if let bin = motionBinPath {
            env["FORGE_MOTION_BIN"] = bin
        }
        process.environment = env
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(.commandUnavailable)
        }
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outText = String(data: outData, encoding: .utf8) ?? ""
        let errText = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            return .failure(.nonZeroExit(
                code: process.terminationStatus,
                stderr: errText
            ))
        }
        return .success(SynthResult(motionJSON: outText, stderr: errText))
    }

    // MARK: - High-level convenience

    public func mirror(pageId: Int, newId: Int, newName: String) -> Result<SynthResult, SynthBridgeError> {
        executeForgeSynth([
            "mirror", "\(pageId)",
            "--new-id", "\(newId)",
            "--name", newName,
        ])
    }

    public func sequence(pageIds: [Int], transitionMs: Int, baseId: Int, name: String) -> Result<SynthResult, SynthBridgeError> {
        var args = ["sequence"]
        for id in pageIds { args.append("\(id)") }
        args.append(contentsOf: [
            "--transition-ms", "\(transitionMs)",
            "--base-id", "\(baseId)",
            "--name", name,
        ])
        return executeForgeSynth(args)
    }

    public func mutateTimeScale(pageId: Int, factor: Double, newId: Int) -> Result<SynthResult, SynthBridgeError> {
        executeForgeSynth([
            "mutate", "\(pageId)",
            "--time-scale", "\(factor)",
            "--new-id", "\(newId)",
        ])
    }
}
