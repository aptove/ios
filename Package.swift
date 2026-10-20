// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AptoveCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "AptoveCore", targets: ["AptoveCore"]),
    ],
    targets: [
        .target(
            name: "AptoveCore",
            path: "Aptove",
            exclude: [
                "AptoveApp.swift",
                "Preview Content",
                "Assets.xcassets",
                "Aptove.entitlements",
                "en.lproj",
                "tr.lproj",
            ]
        ),
    ]
)
