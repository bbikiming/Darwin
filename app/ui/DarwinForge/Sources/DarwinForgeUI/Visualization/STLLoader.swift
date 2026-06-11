import Foundation
import SceneKit

/// Binary STL → `SCNGeometry` 직접 파서.
///
/// STL binary 포맷:
/// - 80-byte header (스킵)
/// - uint32 (LE) facet count
/// - 각 facet: 12 floats (normal x/y/z + 3 vertices) + 2-byte attribute
public enum STLLoader {

    public enum Error: Swift.Error, CustomStringConvertible {
        case fileNotFound(String)
        case truncated
        case asciiUnsupported

        public var description: String {
            switch self {
            case .fileNotFound(let n): return "STL not found: \(n)"
            case .truncated: return "STL file is truncated"
            case .asciiUnsupported: return "ASCII STL not supported (binary only)"
            }
        }
    }

    /// Resources/Meshes/<name>.stl 로드.
    ///
    /// V297-11 CRASH FIX: Bundle.module 직접 호출 폐기. SafeResourceBundle 가
    /// 배포 .app + dev 환경 모두 안전하게 찾음.
    ///
    /// **W1 (2026-06-11)**: 머티리얼 생성 제거 — geometry 만 반환하고 호출자가
    /// `RigMaterials` 로 PBR 머티리얼을 주입한다. normal 은 crease-angle 스무딩 적용.
    public static func loadGeometry(named name: String,
                                     scale: Float = 1.0,
                                     creaseAngleDeg: Float = 35) throws -> SCNGeometry {
        guard let url = SafeResourceBundle.url(forResource: name,
                                                withExtension: "stl",
                                                subdirectory: "Meshes") else {
            throw Error.fileNotFound(name)
        }
        let data = try Data(contentsOf: url)
        return try parseBinarySTL(data: data, scale: scale, creaseAngleDeg: creaseAngleDeg)
    }

    /// 임의 path STL 로드 (테스트용).
    public static func loadGeometry(url: URL,
                                     scale: Float = 1.0,
                                     creaseAngleDeg: Float = 35) throws -> SCNGeometry {
        let data = try Data(contentsOf: url)
        return try parseBinarySTL(data: data, scale: scale, creaseAngleDeg: creaseAngleDeg)
    }

    // MARK: - Binary parser

    private static func parseBinarySTL(data: Data,
                                        scale: Float,
                                        creaseAngleDeg: Float) throws -> SCNGeometry {
        // ASCII STL이면 거부 (header 시작이 "solid "로 시작).
        if data.count >= 5 {
            let head = String(data: data.prefix(5), encoding: .ascii) ?? ""
            if head == "solid" {
                // Binary STL도 헤더가 "solid"로 시작할 수 있어 facet count로 검증.
                // size 검증으로 분기.
                let expectedAscii = data.count > 84 + 50 * 1
                let asciiLikely = !expectedAscii && head == "solid"
                if asciiLikely { throw Error.asciiUnsupported }
            }
        }

        guard data.count >= 84 else { throw Error.truncated }
        let countLE: UInt32 = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 80, as: UInt32.self)
        }
        let triCount = Int(UInt32(littleEndian: countLE))
        let expectedSize = 84 + triCount * 50
        guard data.count >= expectedSize else { throw Error.truncated }

        // Vertex / normal 배열 (각 triangle마다 3 vertex, per-face-vertex 레이아웃).
        var positions = [Float]()
        positions.reserveCapacity(triCount * 3 * 3)
        var normals = [Float]()
        normals.reserveCapacity(triCount * 3 * 3)
        var indices = [UInt32]()
        indices.reserveCapacity(triCount * 3)

        var offset = 84
        for tri in 0..<triCount {
            // normal 12B (3 floats) — face normal, 3 vertex 에 복제.
            let nx = readFloat(data, offset: offset)
            let ny = readFloat(data, offset: offset + 4)
            let nz = readFloat(data, offset: offset + 8)
            offset += 12

            // 3 vertices
            for v in 0..<3 {
                let vx = readFloat(data, offset: offset) * scale
                let vy = readFloat(data, offset: offset + 4) * scale
                let vz = readFloat(data, offset: offset + 8) * scale
                offset += 12
                positions.append(vx); positions.append(vy); positions.append(vz)
                normals.append(nx);   normals.append(ny);   normals.append(nz)
                indices.append(UInt32(tri * 3 + v))
            }
            offset += 2  // attribute byte count
        }

        // **W1**: crease-angle normal smoothing — 곡면 매끈, 직각 모서리 hard 유지.
        let smoothed = STLNormalSmoother.smooth(positions: positions,
                                                 normals: normals,
                                                 creaseAngleDeg: creaseAngleDeg)

        let vertexBytes = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let normalBytes = smoothed.withUnsafeBufferPointer { Data(buffer: $0) }

        let vertexSource = SCNGeometrySource(
            data: vertexBytes,
            semantic: .vertex,
            vectorCount: triCount * 3,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )

        let normalSource = SCNGeometrySource(
            data: normalBytes,
            semantic: .normal,
            vectorCount: triCount * 3,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )

        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: triCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        // **W1**: 머티리얼은 호출자가 RigMaterials 로 주입. geometry 만 반환.
        return SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
    }

    @inline(__always)
    private static func readFloat(_ data: Data, offset: Int) -> Float {
        data.withUnsafeBytes { ptr in
            let raw = ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            return Float(bitPattern: UInt32(littleEndian: raw))
        }
    }
}
