// swift-tools-version: 5.9
import PackageDescription

let strictConcurrency: [SwiftSetting] = [.enableUpcomingFeature("StrictConcurrency")]

let package = Package(
    name: "TalqynSDK",
    // iOS is what the SDK ships to; macOS is here only so `swift test` builds
    // on a Mac — the UIKit layer is compiled out there and runs in a simulator.
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "TalqynSDK", targets: ["TalqynSDK"]),
        .library(name: "TalqynConsultantCore", targets: ["TalqynConsultantCore"]),
        .library(name: "TalqynUI", targets: ["TalqynUI"]),
    ],
    targets: [
        .target(
            name: "TalqynSDK",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "TalqynConsultantCore",
            dependencies: ["TalqynSDK"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "TalqynUI",
            dependencies: ["TalqynSDK", "TalqynConsultantCore"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "TalqynTestSupport",
            dependencies: ["TalqynSDK"],
            path: "Tests/TalqynTestSupport",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "TalqynSDKTests",
            dependencies: ["TalqynSDK", "TalqynTestSupport"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "TalqynConsultantCoreTests",
            dependencies: ["TalqynConsultantCore", "TalqynSDK", "TalqynTestSupport"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "TalqynUITests",
            dependencies: ["TalqynUI", "TalqynConsultantCore", "TalqynSDK", "TalqynTestSupport"],
            swiftSettings: strictConcurrency
        ),
    ]
)
