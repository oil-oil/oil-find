// swift-tools-version:5.10
import PackageDescription
import Foundation

let includesExtension = Context.environment["OILFIND_FREE"] != "1"
    && FileManager.default.fileExists(atPath: Context.packageDirectory + "/Pro/Sources/OilFindPro")
var targets: [Target] = [
    .target(name: "COilFind", publicHeadersPath: "include"),
    .target(name: "OilFindCore", dependencies: ["COilFind"]),
    .target(name: "OilFindApp", dependencies: ["OilFindCore"]),
    .executableTarget(name: "OilFind", dependencies: includesExtension ? ["OilFindApp", "OilFindPro"] : ["OilFindApp"],
                      swiftSettings: includesExtension ? [] : [.define("OILFIND_FREE_BUILD")]),
    .executableTarget(name: "oilfind-cli", dependencies: ["OilFindCore"]),
    .testTarget(name: "OilFindCoreTests", dependencies: ["OilFindCore", "COilFind"]),
    .testTarget(name: "OilFindUITests", dependencies: ["OilFindApp", "OilFindCore"])
]
if includesExtension {
    targets += [
        .target(name: "OilFindPro", dependencies: ["OilFindApp", "OilFindCore"], path: "Pro/Sources/OilFindPro"),
        .testTarget(name: "OilFindProTests", dependencies: ["OilFindPro", "OilFindApp"], path: "Pro/Tests/OilFindProTests")
    ]
}

let package = Package(
    name: "OilFind",
    platforms: [.macOS(.v14)],
    products: [.library(name: "OilFindCore", targets: ["OilFindCore"]), .library(name: "OilFindApp", targets: ["OilFindApp"]), .executable(name: "oilfind-cli", targets: ["oilfind-cli"])],
    targets: targets,
    swiftLanguageVersions: [.v5]
)
