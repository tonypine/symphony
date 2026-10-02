import Foundation

/// BLAKE2b-512 (RFC 7693), unkeyed. minisign signs a file's BLAKE2b-512 hash by default, and CryptoKit has no
/// BLAKE2b.
enum Blake2b {
    static let outputLength = 64
    private static let blockLength = 128

    private static let iv: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    /// The 64-byte BLAKE2b-512 hash of `data`.
    static func hash(_ data: Data) -> Data {
        var state = iv
        // Parameter block: digest length 64, no key, fanout 1, depth 1.
        state[0] ^= 0x0101_0000 ^ UInt64(outputLength)

        let bytes = [UInt8](data)
        var offset = 0
        var counter: UInt64 = 0
        // Every block but the last is compressed as it comes; the last one, even when full, is flagged final.
        while bytes.count - offset > blockLength {
            counter &+= UInt64(blockLength)
            compress(&state, block: bytes[offset ..< offset + blockLength], counter: counter, last: false)
            offset += blockLength
        }
        var last = [UInt8](bytes[offset...])
        counter &+= UInt64(last.count)
        last += [UInt8](repeating: 0, count: blockLength - last.count)
        compress(&state, block: last[...], counter: counter, last: true)

        var output = Data(capacity: outputLength)
        for word in state {
            withUnsafeBytes(of: word.littleEndian) { output.append(contentsOf: $0) }
        }
        return output
    }

    private static func compress(_ state: inout [UInt64], block: ArraySlice<UInt8>, counter: UInt64, last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        let start = block.startIndex
        for i in 0 ..< 16 {
            var word: UInt64 = 0
            for j in 0 ..< 8 {
                word |= UInt64(block[start + i * 8 + j]) << (8 * UInt64(j))
            }
            m[i] = word
        }

        var v = state + iv
        // The byte counter is 128 bits; the high word stays 0 for anything that fits in memory.
        v[12] ^= counter
        if last { v[14] = ~v[14] }

        func mix(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x
            v[d] = rotateRight(v[d] ^ v[a], 32)
            v[c] = v[c] &+ v[d]
            v[b] = rotateRight(v[b] ^ v[c], 24)
            v[a] = v[a] &+ v[b] &+ y
            v[d] = rotateRight(v[d] ^ v[a], 16)
            v[c] = v[c] &+ v[d]
            v[b] = rotateRight(v[b] ^ v[c], 63)
        }

        for round in 0 ..< 12 {
            let s = sigma[round % 10]
            mix(0, 4, 8, 12, m[s[0]], m[s[1]])
            mix(1, 5, 9, 13, m[s[2]], m[s[3]])
            mix(2, 6, 10, 14, m[s[4]], m[s[5]])
            mix(3, 7, 11, 15, m[s[6]], m[s[7]])
            mix(0, 5, 10, 15, m[s[8]], m[s[9]])
            mix(1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(2, 7, 8, 13, m[s[12]], m[s[13]])
            mix(3, 4, 9, 14, m[s[14]], m[s[15]])
        }

        for i in 0 ..< 8 {
            state[i] ^= v[i] ^ v[i + 8]
        }
    }

    private static func rotateRight(_ value: UInt64, _ count: UInt64) -> UInt64 {
        (value >> count) | (value << (64 - count))
    }
}
