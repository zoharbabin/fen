@testable import FenCore
import Foundation
import Testing

@Suite("VectorCodec and VectorMatrix")
struct VectorStoreTests {
    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let na = a.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let nb = b.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return dot / (na * nb)
    }

    private func random(_ seed: inout UInt64, dimension: Int) -> [Float] {
        (0 ..< dimension).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: seed >> 11) % 2000 - 1000) / 1000
        }
    }

    @Test("the stored form is a quarter of Float32 and keeps cosine close")
    func quantization() throws {
        var seed: UInt64 = 7
        let a = random(&seed, dimension: 512)
        let b = random(&seed, dimension: 512)
        let encoded = try #require(VectorCodec.encode(a))
        #expect(encoded.count == 4 + 512)
        var matrix = VectorMatrix(dimension: 512)
        matrix.append(id: 1, encoded: encoded)
        let query = try #require(VectorCodec.normalized(b))
        let score = try #require(matrix.top(1, for: query).first?.score)
        #expect(abs(score - cosine(a, b)) < 0.02)
    }

    @Test("top returns the best matches first and never more than asked")
    func ranking() throws {
        var seed: UInt64 = 42
        let vectors = (0 ..< 200).map { _ in random(&seed, dimension: 64) }
        var matrix = VectorMatrix(dimension: 64)
        for (index, vector) in vectors.enumerated() {
            try matrix.append(id: Int64(index), encoded: #require(VectorCodec.encode(vector)))
        }
        let query = try #require(VectorCodec.normalized(vectors[17]))
        let top = matrix.top(5, for: query)
        #expect(top.count == 5)
        #expect(top[0].id == 17)
        #expect(zip(top, top.dropFirst()).allSatisfy { $0.score >= $1.score })
        let exact = vectors.indices.sorted { cosine(vectors[$0], vectors[17]) > cosine(vectors[$1], vectors[17]) }
        #expect(Set(top.prefix(3).map(\.id)) == Set(exact.prefix(3).map(Int64.init)))
    }

    @Test("bad vectors are refused: empty, zero, and not finite")
    func refusals() {
        #expect(VectorCodec.encode([]) == nil)
        #expect(VectorCodec.encode([0, 0, 0]) == nil)
        #expect(VectorCodec.encode([1, .nan, 0]) == nil)
        #expect(VectorCodec.encode([1, .infinity, 0]) == nil)
        #expect(VectorCodec.normalized([.nan]) == nil)
        var matrix = VectorMatrix(dimension: 4)
        matrix.append(id: 1, encoded: Data([1, 2, 3]))
        #expect(matrix.ids.isEmpty)
        #expect(matrix.top(3, for: [1, 0, 0, 0]).isEmpty)
        #expect(matrix.top(3, for: [1, 0]).isEmpty)
    }
}
