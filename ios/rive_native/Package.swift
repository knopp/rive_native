// swift-tools-version: 5.9
import PackageDescription

// Version and checksum are auto-updated by native/build_xcframework.sh
let riveNativeVersion = "0.1.6+1"
let riveNativeVersionURLComponent = riveNativeVersion.replacingOccurrences(of: "+", with: "%2B")
let riveNativeChecksum = "96b458df775f7630e6b4541d11f7058663a686f0d0a007dc13fe023761173747"

let package = Package(
    name: "rive_native",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "rive-native", targets: ["rive_native"])
    ],
    targets: [
        // Binary target for the pre-built Rive native libraries
        //
        // FOR LOCAL TESTING: Comment out the url/checksum version and uncomment the path version:
        // .binaryTarget(
        //     name: "RiveNative",
        //     path: "Frameworks/RiveNative_ios.xcframework"
        // ),
        //
        // FOR RELEASE: Use url/checksum (auto-updated by build_xcframework.sh):
        .binaryTarget(
            name: "RiveNative",
            url: "https://rive-flutter-artifacts.rive.app/rive_native_versions/\(riveNativeVersionURLComponent)/RiveNative_ios.xcframework.zip",
            checksum: riveNativeChecksum
        ),
        // Plugin target that wraps the binary and provides Flutter integration
        .target(
            name: "rive_native",
            dependencies: ["RiveNative"],
            path: "Sources/rive_native",
            sources: ["rive_native_plugin.mm"],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
