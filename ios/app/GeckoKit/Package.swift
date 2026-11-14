// swift-tools-version: 5.10
// GeckoKit holds the app's pure, dependency-free helpers (no SwiftUI / UIKit /
// bridge) so they can be unit-tested with `swift test` on the host. The very
// same source files are compiled straight into the Gecko app by build-app.sh
// (it globs GeckoKit/Sources/GeckoKit/*.swift alongside Sources/*.swift), so
// there is one source of truth — the tests exercise exactly what ships.
import PackageDescription

let package = Package(
    name: "GeckoKit",
    // AttributedString needs macOS 12+ / iOS 15+; the host build (swift test)
    // uses the macOS floor.
    platforms: [.macOS(.v13), .iOS(.v16)],
    // The app links the same version, built by `ios/build-deps.sh <target> grdb`.
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
    ],
    targets: [
        // libomemo-c from Homebrew for the host tests; the app links the
        // prefix's build (ios/build-deps.sh).
        .systemLibrary(name: "COMEMO", pkgConfig: "libomemo-c", providers: [.brew(["libomemo-c"])]),
        .target(name: "GeckoKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "COMEMO"],
                // libomemo-c's pkg-config file names protobuf-c without its folder.
                linkerSettings: [.unsafeFlags(["-L/opt/homebrew/lib"], .when(platforms: [.macOS]))]),
        .testTarget(name: "GeckoKitTests", dependencies: ["GeckoKit"]),
    ]
)
