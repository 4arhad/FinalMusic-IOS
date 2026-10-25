import UIKit
import ImageIO

/// Two-level artwork cache (the port's answer to the Android app's Coil
/// pipeline): an NSCache of DECODED, DOWNSAMPLED UIImages keyed by
/// url+size, over a bounded disk cache of the original bytes, over the
/// URLSession URLCache configured in LastWaveApp. Decoding happens off the
/// main thread inside this actor, so scrolling never pays for a full-res
/// JPEG decode; ArtworkPolicy keeps the fetched variant near the display
/// size, DedupeLedger stops prefetch racing a visible load, and CacheEviction
/// bounds the disk side with an age limit plus an LRU byte budget.
actor ArtworkCache {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, UIImage>()
    private let diskDir: URL
    private let diskBudgetBytes = 150 * 1024 * 1024
    private let diskMaxAge: TimeInterval = 60 * 60 * 24 * 30   // 30 days
    private var ledger = DedupeLedger()
    private var didCleanDisk = false

    private init() {
        memory.countLimit = 300
        // ~60 MB of decoded bitmaps — a row-sized image is a few hundred KB,
        // a player-sized one a few MB; the count limit alone would let 300
        // full-screen artworks balloon into hundreds of MB.
        memory.totalCostLimit = 60 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("LastWaveArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    // MARK: - Loading

    /// The decoded image sized for a `maxPixel`-pt-side render. Hits memory,
    /// then disk, then the network (through the shared URLCache).
    func image(url raw: String?, maxPixel: Int) async -> UIImage? {
        guard let raw, !raw.isEmpty else { return nil }
        let sized = ArtworkPolicy.isResizable(raw)
            ? ArtworkPolicy.sizedURLString(for: raw, maxPixel: maxPixel)
            : raw
        let key = "\(maxPixel)|\(sized)" as NSString
        if let hit = memory.object(forKey: key) { return hit }

        let file = diskFile(for: key)
        if let data = try? Data(contentsOf: file), let image = downsample(data: data, maxPixel: maxPixel) {
            store(image, forKey: key)
            return image
        }

        guard ledger.begin(key as String) else {
            // Another task (usually a prefetch) is fetching this exact
            // variant. Wait for its result instead of failing the view:
            // it writes to memory before releasing the ledger key.
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let hit = memory.object(forKey: key) { return hit }
                if let data = try? Data(contentsOf: file),
                   let image = downsample(data: data, maxPixel: maxPixel) {
                    store(image, forKey: key)
                    return image
                }
            }
            return nil
        }
        defer { ledger.end(key as String) }

        guard let url = URL(string: sized) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = downsample(data: data, maxPixel: maxPixel) else { return nil }
            try? data.write(to: file, options: .atomic)
            store(image, forKey: key)
            scheduleDiskCleanupIfNeeded()
            return image
        } catch {
            NSLog("LWART fail %@", sized)
            return nil
        }
    }

    /// Warm memory+disk for artwork that is about to scroll into view (next
    /// queue entries, the head of a just-parsed page). Fire-and-forget.
    func prefetch(_ urls: [String?], maxPixel: Int) {
        for raw in urls where ArtworkPolicy.isResizable(raw ?? "") {
            guard let raw, !raw.isEmpty else { continue }
            let sized = ArtworkPolicy.sizedURLString(for: raw, maxPixel: maxPixel)
            let key = "\(maxPixel)|\(sized)" as NSString
            if memory.object(forKey: key) != nil { continue }
            Task { _ = await self.image(url: raw, maxPixel: maxPixel) }
        }
    }

    /// Convenience for callers that have track artwork URLs at hand.
    func prefetchArtwork(of tracks: [MusicTrack], maxPixel: Int) {
        prefetch(tracks.map(\.artwork), maxPixel: maxPixel)
    }

    // MARK: - Internals

    private func store(_ image: UIImage, forKey key: NSString) {
        let cost = max(image.size.width * image.size.height * image.scale * image.scale * 4, 1)
        memory.setObject(image, forKey: key, cost: Int(cost))
    }

    private func diskFile(for key: NSString) -> URL {
        // Stable across launches (StableHash, not Swift's per-process hashValue)
        // so a cold app still reads its warm artwork bytes off disk.
        diskDir.appendingPathComponent(String(StableHash.fnv1a64(key as String), radix: 16))
    }

    /// Decode with ImageIO capping the bitmap at maxPixel during decompress —
    /// a 1280x1280 JPEG asked for as 48 px never materialises full-size.
    private func downsample(data: Data, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let cap = CGFloat(max(maxPixel, 32))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: cap,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            // Thumbnail creation refused (or a corrupt body) — last resort standard decode.
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }

    private func scheduleDiskCleanupIfNeeded() {
        guard !didCleanDisk else { return }
        didCleanDisk = true
        Task.detached(priority: .utility) {
            await ArtworkCache.shared.cleanDisk()
        }
    }

    /// Age + LRU eviction of the disk side (mirrors Coil's errorResume +
    /// cleanup sweep). Expired files first, oldest-modified until the budget
    /// fits; runs at most once per session, after the first network fetch.
    func cleanDisk() {
        let values: [(DiskCacheEntry)]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        values = files.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return DiskCacheEntry(name: url.lastPathComponent,
                                  bytes: v.fileSize ?? 0,
                                  modified: v.contentModificationDate ?? .distantPast)
        }
        let victims = CacheEviction.victims(entries: values,
                                            budgetBytes: diskBudgetBytes,
                                            maxAge: diskMaxAge,
                                            now: Date())
        for name in victims {
            try? FileManager.default.removeItem(at: diskDir.appendingPathComponent(name))
        }
        if !victims.isEmpty {
            NSLog("LWART disk cleanup removed=%d", victims.count)
        }
    }
}
