// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IrodoriSpeechCpp",
    platforms: [.iOS(.v17)],
    products: [.library(name: "IrodoriSpeechCpp", targets: ["IrodoriSpeechCpp"])],
    dependencies: [.package(name: "IrodoriTTS", path: "../..")],
    targets: [
        .binaryTarget(name: "SpeechCpp", path: "Artifacts/SpeechCpp.xcframework.zip"),
        .target(name: "IrodoriSpeechNative", dependencies: ["SpeechCpp"],
                sources: ["IrodoriSpeechBridge.mm", "ReazonSpeechBridge.mm"], publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("Metal")]),
        .target(name: "IrodoriSpeechCpp", dependencies: ["IrodoriSpeechNative", .product(name: "IrodoriTTS", package: "IrodoriTTS")]),
    ],
    cxxLanguageStandard: .cxx17
)
