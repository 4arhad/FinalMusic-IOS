// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FinalMusicCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "FinalMusicCore", targets: ["FinalMusicCore"])],
    targets: [
        .target(name: "FinalMusicCore", path: "FinalMusic", sources: ["IntegrationCore.swift", "LastFmSigner.swift", "LRCLIBClient.swift", "InnerTubeAPI.swift", "YouTubeAuthCore.swift", "LocalTasteCore.swift", "ArtworkCore.swift", "QueueCore.swift"]),
        .executableTarget(name: "FinalMusicCoreChecks", dependencies: ["FinalMusicCore"], path: "Tests/FinalMusicCoreChecks")
    ]
)
