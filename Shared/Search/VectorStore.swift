import Foundation

/// Stores one embedding as 4 bytes of scale plus one byte per dimension (issue #35). That is a
/// quarter of the size of Float32, and cosine ranking barely changes: the vector is unit length
/// before it is scaled.
enum VectorCodec {
    static func encode(_ vector: [Float]) -> Data? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        let unit = vector.map { $0 / norm }
        let peak = unit.map(abs).max() ?? 0
        guard peak > 0 else { return nil }
        let scale = peak / 127
        var data = Data()
        withUnsafeBytes(of: scale.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: unit.map { UInt8(bitPattern: Int8((($0 / scale).rounded()).clamped(-127, 127))) })
        return data
    }

    static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.allSatisfy(\.isFinite) else { return nil }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : nil
    }
}

private extension Float {
    func clamped(_ low: Float, _ high: Float) -> Float {
        Swift.min(Swift.max(self, low), high)
    }
}

/// All of one workspace's vectors in memory, for a brute-force cosine search. A workspace of
/// 100,000 chunks at 512 dimensions takes about 50 MB. Typical ones take a few.
struct VectorMatrix {
    let dimension: Int
    private(set) var ids: [Int64] = []
    private var scales: [Float] = []
    private var values: [Int8] = []

    init(dimension: Int) {
        self.dimension = dimension
    }

    var count: Int {
        ids.count
    }

    mutating func append(id: Int64, encoded: Data) {
        guard encoded.count == 4 + dimension else { return }
        let bits = encoded.prefix(4).enumerated()
            .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        ids.append(id)
        scales.append(Float(bitPattern: bits))
        values.append(contentsOf: encoded.dropFirst(4).map { Int8(bitPattern: $0) })
    }

    /// The `limit` best matches for a unit-length `query`, best first. Scores are cosines.
    func top(_ limit: Int, for query: [Float]) -> [(id: Int64, score: Float)] {
        guard query.count == dimension, limit > 0, !ids.isEmpty else { return [] }
        var best: [(index: Int, score: Float)] = []
        values.withUnsafeBufferPointer { matrix in
            query.withUnsafeBufferPointer { q in
                for row in 0 ..< ids.count {
                    let base = row * dimension
                    var sum: Float = 0
                    for column in 0 ..< dimension {
                        sum += q[column] * Float(matrix[base + column])
                    }
                    let score = sum * scales[row]
                    if best.count < limit || score > best[best.count - 1].score {
                        let position = best.firstIndex { $0.score < score } ?? best.count
                        best.insert((row, score), at: position)
                        if best.count > limit {
                            best.removeLast()
                        }
                    }
                }
            }
        }
        return best.map { (ids[$0.index], $0.score) }
    }
}
