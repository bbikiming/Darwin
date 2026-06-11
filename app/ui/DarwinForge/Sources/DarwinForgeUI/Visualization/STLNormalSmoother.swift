import Foundation
import simd

/// STL per-face normal → crease-angle 스무딩.
///
/// **W1 (2026-06-11)**: binary STL 은 face normal 을 3 vertex 에 그대로 복제하므로
/// 곡면이 각져 보인다. 같은 위치를 공유하는 face normal 중 **crease angle 이하**인
/// 것만 평균해 쉘 곡면은 매끈하게, 서보 하우징 직각 모서리는 hard 유지.
///
/// per-face-vertex 레이아웃 유지(인덱스 공유 안 함) — normal 배열만 교체.
enum STLNormalSmoother {

    /// 같은 위치 판정 격자(m). 1e-5 = 0.01mm.
    static let quantizeGrid: Float = 1e-5

    /// 양자화된 정점 위치 — 해시 키.
    private struct QPos: Hashable {
        let x: Int32, y: Int32, z: Int32
        init(_ px: Float, _ py: Float, _ pz: Float) {
            x = Int32((px / quantizeGrid).rounded())
            y = Int32((py / quantizeGrid).rounded())
            z = Int32((pz / quantizeGrid).rounded())
        }
    }

    /// positions/normals: 정점당 3 float interleaved(per-face-vertex, vertexCount=triCount×3).
    /// 반환: 같은 길이의 스무딩된 normal 배열.
    static func smooth(positions: [Float],
                       normals: [Float],
                       creaseAngleDeg: Float = 35) -> [Float] {
        let vertexCount = positions.count / 3
        guard vertexCount >= 3, vertexCount % 3 == 0 else { return normals }
        let faceCount = vertexCount / 3
        let cosCrease = cosf(creaseAngleDeg * .pi / 180.0)

        // ── 1. face normal (cross product, 퇴화 시 입력 normal 폴백).
        var faceNormals = [SIMD3<Float>](repeating: .zero, count: faceCount)
        for f in 0..<faceCount {
            let i0 = f * 9
            let v0 = SIMD3(positions[i0],     positions[i0 + 1], positions[i0 + 2])
            let v1 = SIMD3(positions[i0 + 3], positions[i0 + 4], positions[i0 + 5])
            let v2 = SIMD3(positions[i0 + 6], positions[i0 + 7], positions[i0 + 8])
            let cross = simd_cross(v1 - v0, v2 - v0)
            let len = simd_length(cross)
            if len > 1e-12 {
                faceNormals[f] = cross / len
            } else {
                let n = SIMD3(normals[i0], normals[i0 + 1], normals[i0 + 2])
                let nl = simd_length(n)
                faceNormals[f] = nl > 1e-12 ? n / nl : SIMD3(0, 0, 1)
            }
        }

        // ── 2. 위치 → 정점 인덱스 버킷.
        var buckets = [QPos: [Int]](minimumCapacity: vertexCount)
        for i in 0..<vertexCount {
            let p = QPos(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
            buckets[p, default: []].append(i)
        }

        // ── 3. 정점별 crease 평균(뒤집힌 normal 방어 포함).
        var out = [Float](repeating: 0, count: normals.count)
        for i in 0..<vertexCount {
            let own = faceNormals[i / 3]
            let p = QPos(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
            var acc = SIMD3<Float>.zero
            for j in buckets[p] ?? [i] {
                var n = faceNormals[j / 3]
                var d = simd_dot(n, own)
                if d < 0 { n = -n; d = -d }   // 인접 평균과 역방향이면 flip
                if d >= cosCrease { acc += n }
            }
            let len = simd_length(acc)
            let result = len > 1e-12 ? acc / len : own
            out[i * 3]     = result.x
            out[i * 3 + 1] = result.y
            out[i * 3 + 2] = result.z
        }
        return out
    }
}
