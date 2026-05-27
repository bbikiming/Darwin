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
    public static func loadGeometry(named name: String,
                                     scale: Float = 1.0,
                                     diffuse: NSColor) throws -> SCNGeometry {
        guard let url = SafeResourceBundle.url(forResource: name,
                                                withExtension: "stl",
                                                subdirectory: "Meshes") else {
            throw Error.fileNotFound(name)
        }
        let data = try Data(contentsOf: url)
        return try parseBinarySTL(data: data, scale: scale, diffuse: diffuse)
    }

    /// 임의 path STL 로드 (테스트용).
    public static func loadGeometry(url: URL,
                                     scale: Float = 1.0,
                                     diffuse: NSColor) throws -> SCNGeometry {
        let data = try Data(contentsOf: url)
        return try parseBinarySTL(data: data, scale: scale, diffuse: diffuse)
    }

    // MARK: - Binary parser

    private static func parseBinarySTL(data: Data,
                                        scale: Float,
                                        diffuse: NSColor) throws -> SCNGeometry {
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

        // Vertex / normal 배열 (각 triangle마다 3 vertex).
        var vertexBytes = Data()
        vertexBytes.reserveCapacity(triCount * 3 * 12)   // 3 verts × 3 floats × 4 bytes
        var normalBytes = Data()
        normalBytes.reserveCapacity(triCount * 3 * 12)
        var indices = [UInt32]()
        indices.reserveCapacity(triCount * 3)

        var offset = 84
        for tri in 0..<triCount {
            // normal 12B (3 floats)
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
                appendFloat(&vertexBytes, vx)
                appendFloat(&vertexBytes, vy)
                appendFloat(&vertexBytes, vz)
                appendFloat(&normalBytes, nx)
                appendFloat(&normalBytes, ny)
                appendFloat(&normalBytes, nz)
                indices.append(UInt32(tri * 3 + v))
            }
            offset += 2  // attribute byte count
        }

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

        let geom = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        let mat = SCNMaterial()
        mat.diffuse.contents = diffuse
        mat.specular.contents = NSColor.white.withAlphaComponent(0.30)
        mat.shininess = 18
        mat.lightingModel = .blinn
        mat.isDoubleSided = true   // STL normal이 가끔 뒤집혀 있어 양면 활성화.
        geom.firstMaterial = mat
        return geom
    }

    @inline(__always)
    private static func readFloat(_ data: Data, offset: Int) -> Float {
        data.withUnsafeBytes { ptr in
            let raw = ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            return Float(bitPattern: UInt32(littleEndian: raw))
        }
    }

    @inline(__always)
    private static func appendFloat(_ data: inout Data, _ value: Float) {
        var v = value
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}
