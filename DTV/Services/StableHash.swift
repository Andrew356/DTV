import Foundation

/// Deterministic FNV-1a hash (Swift's `Hasher` is randomly seeded per launch,
/// so it can't be used for ids that must match across devices).
enum StableHash {
    static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }
}
