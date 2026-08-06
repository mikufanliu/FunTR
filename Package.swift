// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FunTR",
    platforms: [
        .macOS("15.0")
    ],
    dependencies: [
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .target(
            name: "CThermalSensor",
            path: "Sources/CThermalSensor",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "FunTR",
            dependencies: [
                "CLibUSB",
                "CThermalSensor",
            ],
            // The sources keep their original directory name; only the product is
            // renamed, so the rebrand costs no file moves.
            path: "Sources/MacTR",
            swiftSettings: [
                .unsafeFlags(["-I/opt/homebrew/include/libusb-1.0"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib"]),
                .linkedLibrary("usb-1.0"),
            ]
        ),
    ]
)
