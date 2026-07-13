// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Screenotate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Screenotate",
            path: "Sources/Screenotate",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ]
)
  
