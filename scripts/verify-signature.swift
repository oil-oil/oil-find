import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("Usage: verify-signature.swift <app> <expected-bundle-id> <requirement>")
}

let app = URL(fileURLWithPath: arguments[1], isDirectory: true)
let expectedBundleID = arguments[2]
let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
guard info?["CFBundleIdentifier"] as? String == expectedBundleID else {
    fail("Bundle identifier does not match \(expectedBundleID).")
}

var requirement: SecRequirement?
guard SecRequirementCreateWithString(arguments[3] as CFString, [], &requirement) == errSecSuccess,
      let requirement else {
    fail("Could not create the signature requirement.")
}
var candidate: SecStaticCode?
guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess,
      let candidate else {
    fail("Could not read the application signature.")
}
let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
guard SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess else {
    fail("The application does not satisfy the required update signature.")
}
print("Signature requirement verified for \(expectedBundleID).")
