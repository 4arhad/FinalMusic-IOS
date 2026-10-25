import Foundation

// Pure caching policy for artwork, shared by LastWaveCoreChecks and the app.
// Nothing here touches UIKit or the network: URL shaping, disk eviction and
// request deduplication are decided by these functions and executed by
// ArtworkCache.

// MARK: - Thumbnail URL policy
//
// YouTube serves artwork from two hosts with two different resize dialects:
//   * yt3.googleusercontent.com/... =sNNN-c-k-no   — a size token after `=`
//   * i.ytimg.com/vi/<id>/hqdefault.jpg            — fixed-size filenames
// Downloading full-resolution artwork when the row is 48 pt wide wastes
// bandwidth and decode time, so callers ask for a max pixel size and get the
// smallest variant that still covers it. Unrecognised shapes pass through
// unchanged — an artwork URL that renders at its original size beats one that
// 404s on a invented variant.
public enum ArtworkPolicy {

    /// Standard i.ytimg.com thumbnail filenames with their pixel width.
    static let ytimgVariants: [(name: String, pixels: Int)] = [
        ("default.jpg", 120),
        ("mqdefault.jpg", 320),
        ("hqdefault.jpg", 480),
        ("sddefault.jpg", 640),
        ("maxresdefault.jpg", 1280),
    ]

    /// A URL whose bytes should be no wider/taller than `maxPixel` on one side.
    public static func sizedURLString(for raw: String, maxPixel: Int) -> String {
        guard maxPixel > 0, let url = URL(string: raw), let host = url.host else { return raw }
        switch host {
        case "yt3.googleusercontent.com", "yt3.ggpht.com", "lh3.googleusercontent.com":
            return resizedGoogleImage(raw, maxPixel: maxPixel)
        case "i.ytimg.com":
            return resizedYtimg(raw, url: url, maxPixel: maxPixel)
        default:
            return raw
        }
    }

    /// Rewrites the `sNNN` (or `wNNN`/`hNNN`) size tokens in the trailing
    /// `=...` parameter segment of a Google image URL, clamped to maxPixel.
    /// Only existing tokens are touched; absent tokens are NOT appended,
    /// because unsigned yt3 paths differ in what they accept.
    static func resizedGoogleImage(_ raw: String, maxPixel: Int) -> String {
        guard let eqIndex = raw.lastIndex(of: "=") else { return raw }
        let head = String(raw[..<eqIndex])
        let spec = String(raw[raw.index(after: eqIndex)...])
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        var wroteAny = false
        let mapped = parts.map { part -> String in
            guard part.first == "s" || part.first == "w" || part.first == "h",
                  let digits = Int(part.dropFirst()), digits > 0 else { return String(part) }
            wroteAny = true
            return "\(part.first!)\(min(digits, maxPixel))"
        }
        guard wroteAny else { return raw }
        return head + "=" + mapped.joined(separator: "-")
    }

    /// Maps an i.ytimg.com `/vi/<id>/<variant>.jpg` path to the smallest
    /// standard variant that still covers maxPixel; keeps the original when it
    /// already fits or when the filename is not one of the standard sizes.
    static func resizedYtimg(_ raw: String, url: URL, maxPixel: Int) -> String {
        let components = url.pathComponents
        guard components.count == 4, components[1] == "vi" else { return raw }
        let name = components[3]
        guard let current = ytimgVariants.first(where: { $0.name == name }) else { return raw }
        if current.pixels <= maxPixel { return raw }
        let target = ytimgVariants.first(where: { $0.pixels >= maxPixel })
            ?? ytimgVariants[ytimgVariants.count - 1]
        guard let found = raw.range(of: "/\(name)", options: .backwards) else { return raw }
        return raw.replacingOccurrences(of: "/\(name)",
                                        with: "/\(target.name)",
                                        options: [],
                                        range: found)
    }

    /// True when the URL belongs to a host we know how to downsize; drives
    /// whether ArtworkCache bothers rewriting before prefetch.
    public static func isResizable(_ raw: String) -> Bool {
        guard let host = URL(string: raw)?.host else { return false }
        switch host {
        case "yt3.googleusercontent.com", "yt3.ggpht.com", "lh3.googleusercontent.com", "i.ytimg.com":
            return true
        default:
            return false
        }
    }
}

// MARK: - Disk cache eviction

public struct DiskCacheEntry {
    public let name: String
    public let bytes: Int
    public let modified: Date
    public init(name: String, bytes: Int, modified: Date) {
        self.name = name
        self.bytes = bytes
        self.modified = modified
    }
}

/// Decides which files a bounded disk cache must delete: everything older than
/// `maxAge` first, then least-recently-modified until the survivors fit into
/// `budgetBytes`. Pure so the policy is checkable without a filesystem.
public enum CacheEviction {
    public static func victims(entries: [DiskCacheEntry],
                               budgetBytes: Int,
                               maxAge: TimeInterval,
                               now: Date) -> Set<String> {
        var victims = Set<String>()
        var survivors: [DiskCacheEntry] = []
        for entry in entries {
            if now.timeIntervalSince(entry.modified) > maxAge {
                victims.insert(entry.name)
            } else {
                survivors.append(entry)
            }
        }
        var total = survivors.reduce(0) { $0 + $1.bytes }
        guard total > budgetBytes else { return victims }
        for entry in survivors.sorted(by: { $0.modified < $1.modified }) {
            victims.insert(entry.name)
            total -= entry.bytes
            if total <= budgetBytes { break }
        }
        return victims
    }
}

// MARK: - Stable hash for cache keys
//
// Swift's built-in String.hashValue is seeded per process — useless for a disk
// cache that must survive relaunches. FNV-1a is tiny, deterministic, and
// checkable against hand-computed vectors.
public enum StableHash {
    public static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

// MARK: - Request deduplication

/// A key must never be fetched twice at the same time (tab switching, two rows
/// with the same artwork, and prefetch racing a visible load). `begin` returns
/// false when a fetch for that key is already in flight, and the caller skips
/// its own work; `end` releases the key.
public struct DedupeLedger {
    private var inFlight: Set<String> = []

    public init() {}
    public var count: Int { inFlight.count }

    /// true = this caller owns the key and should fetch; false = someone else
    /// is already fetching it.
    public mutating func begin(_ key: String) -> Bool {
        inFlight.insert(key).inserted
    }

    public mutating func end(_ key: String) {
        inFlight.remove(key)
    }
}
