// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QianliIR",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "QianliIR", targets: ["QianliIR"]),
    ],
    targets: [
        // Pure Swift: frame parsing, temperatures, palettes, rendering. No Apple frameworks.
        .target(name: "ThermalCore"),
        // USB control transfers to the camera (IOKit), for gain switching and shutter.
        .target(name: "USBControl", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        // The macOS app (SwiftUI + AVFoundation).
        .executableTarget(name: "QianliIR", dependencies: ["ThermalCore", "USBControl"]),
        .testTarget(name: "ThermalCoreTests", dependencies: ["ThermalCore"]),
    ]
)
