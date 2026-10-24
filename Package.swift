// swift-tools-version:5.10
import PackageDescription

// libssh2 + OpenSSL come from Homebrew; scripts/build-app.sh copies them into the app bundle.
let brewInclude = "/opt/homebrew/include"
let brewLib = "/opt/homebrew/lib"

let package = Package(
    name: "SkyMount",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "CShims",
            cSettings: [.unsafeFlags(["-I\(brewInclude)"])],
            linkerSettings: [
                .linkedLibrary("curl"),
                .linkedLibrary("ssh2"),
                .unsafeFlags(["-L\(brewLib)"]),
            ]
        ),
        .target(
            name: "SkyMountCore",
            dependencies: ["CShims"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(brewInclude)"])]
        ),
        .target(name: "SkyMountShared"),
        // Finder Sync extension; scripts/build-app.sh wraps it into SkyMount.app/Contents/PlugIns.
        .executableTarget(
            name: "SkyMountFinder",
            dependencies: ["SkyMountShared"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                                           "-Xlinker", "-application_extension"])]
        ),
        .executableTarget(
            name: "SkyMount",
            dependencies: ["SkyMountCore", "SkyMountShared"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(brewInclude)"])]
        ),
        .executableTarget(
            name: "smctl",
            dependencies: ["SkyMountCore"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(brewInclude)"])]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
