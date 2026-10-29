import XCTest
import Security
@testable import OilFindCore

private func makeRequirement(_ source: String) throws -> SecRequirement {
    var requirement: SecRequirement?
    XCTAssertEqual(SecRequirementCreateWithString(source as CFString, [], &requirement), errSecSuccess)
    return try XCTUnwrap(requirement)
}

private func assertSignatureRejected(_ app: URL, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try SystemUpdateSignature().validate(app), file: file, line: line) {
        XCTAssertEqual($0 as? UpdateFailure, .signature, file: file, line: line)
    }
}

final class UpdateSignatureTests: XCTestCase {
    func testDefaultUpdateFeedIsV2() {
        XCTAssertEqual(UpdateClient.latestURL.absoluteString, "https://find.oiloil.org/updates/latest-v2.json")
    }

    func testDeveloperIDRequirementCanBeConstructed() throws {
        _ = try makeRequirement(SystemUpdateSignature.developerIDRequirement)
    }

    func testBridgeAcceptsDeveloperIDAfterLegacyMismatch() throws {
        let signing = CodeSigning()
        signing.running = try makeRequirement("identifier \"running\"")
        signing.developerID = try makeRequirement("identifier \"developer\"")
        signing.developerIDValid = true
        XCTAssertNoThrow(try SystemUpdateSignature(codeSigning: signing).validate(URL(fileURLWithPath: "/test/Oil Find.app")))
        XCTAssertEqual(signing.legacyAttempts, 1)
        XCTAssertEqual(signing.developerIDAttempts, 1)
        XCTAssertEqual(signing.developerIDSources, [SystemUpdateSignature.developerIDRequirement])
    }

    func testDeveloperIDSuccessorUsesRunningDesignatedRequirement() throws {
        let signing = CodeSigning()
        signing.running = try makeRequirement("identifier \"running\"")
        signing.developerID = try makeRequirement("identifier \"developer\"")
        signing.legacyValid = true
        XCTAssertNoThrow(try SystemUpdateSignature(codeSigning: signing).validate(URL(fileURLWithPath: "/test/Oil Find.app")))
        XCTAssertEqual(signing.legacyAttempts, 1)
        XCTAssertEqual(signing.developerIDAttempts, 0)
        XCTAssertTrue(signing.developerIDSources.isEmpty)
    }

    func testCandidateIsRejectedWhenNeitherIdentityMatches() throws {
        let signing = CodeSigning()
        signing.running = try makeRequirement("identifier \"running\"")
        signing.developerID = try makeRequirement("identifier \"developer\"")
        XCTAssertThrowsError(try SystemUpdateSignature(codeSigning: signing).validate(URL(fileURLWithPath: "/test/Oil Find.app"))) {
            XCTAssertEqual($0 as? UpdateFailure, .signature)
        }
        XCTAssertEqual(signing.legacyAttempts, 1)
        XCTAssertEqual(signing.developerIDAttempts, 1)
    }
}

private final class CodeSigning: UpdateCodeSigning {
    var running: SecRequirement?
    var developerID: SecRequirement?
    var legacyValid = false
    var developerIDValid = false
    private(set) var legacyAttempts = 0
    private(set) var developerIDAttempts = 0
    private(set) var developerIDSources: [String] = []

    func runningDesignatedRequirement() -> SecRequirement? { running }
    func requirement(from source: String) -> SecRequirement? {
        developerIDSources.append(source)
        return developerID
    }
    func validate(_ app: URL, against requirement: SecRequirement) -> Bool {
        if let running, requirement === running {
            legacyAttempts += 1
            return legacyValid
        }
        if let developerID, requirement === developerID {
            developerIDAttempts += 1
            return developerIDValid
        }
        return false
    }
}

final class UpdateSignatureIntegrationTests: XCTestCase {
    private func identity(_ environmentKey: String) throws -> String {
        guard let identity = ProcessInfo.processInfo.environment[environmentKey], !identity.isEmpty else {
            throw XCTSkip("Set \(environmentKey) to run real codesign validation")
        }
        return identity
    }

    func testRealDeveloperIDCandidatePassesAndWrongBundleIsRejected() throws {
        let identity = try identity("OILFIND_TEST_DEVELOPER_IDENTITY")
        try withSignedApp(identity: identity) { app in
            XCTAssertNoThrow(try SystemUpdateSignature().validate(app))
        }
        try withSignedApp(identifier: "com.oiloil.find.invalid", identity: identity) { app in
            assertSignatureRejected(app)
        }
    }

    func testAdHocCandidateIsRejected() throws {
        try withSignedApp(identity: "-") { app in
            assertSignatureRejected(app)
        }
    }

    func testRealSelfSignedBridgeRequiresMatchingRunningRequirement() throws {
        let identity = try identity("OILFIND_TEST_SELF_SIGNED_IDENTITY")
        try withSignedApp(identity: identity) { app in
            assertSignatureRejected(app)
            let signing = RunningRequirementCodeSigning(running: try designatedRequirement(for: app))
            XCTAssertNoThrow(try SystemUpdateSignature(codeSigning: signing).validate(app))
            XCTAssertEqual(signing.developerIDRequests, 0)
        }
    }

    func testRealDeveloperIDSuccessorUsesRunningRequirement() throws {
        let identity = try identity("OILFIND_TEST_DEVELOPER_IDENTITY")
        try withSignedApp(identity: identity) { app in
            let signing = RunningRequirementCodeSigning(running: try designatedRequirement(for: app))
            XCTAssertNoThrow(try SystemUpdateSignature(codeSigning: signing).validate(app))
            XCTAssertEqual(signing.developerIDRequests, 0)
        }
    }

    func testRealDeveloperIDCandidateFailsMismatchedTeamRequirement() throws {
        let identity = try identity("OILFIND_TEST_DEVELOPER_IDENTITY")
        try withSignedApp(identity: identity) { app in
            let signing = SystemUpdateCodeSigning()
            let validRequirement = try XCTUnwrap(signing.requirement(from: SystemUpdateSignature.developerIDRequirement))
            XCTAssertTrue(signing.validate(app, against: validRequirement))
            let source = SystemUpdateSignature.developerIDRequirement.replacingOccurrences(of: "4NZ3X494AF", with: "AAAAAAAAAA")
            let requirement = try XCTUnwrap(signing.requirement(from: source))
            XCTAssertFalse(signing.validate(app, against: requirement))
        }
    }

    func testRealDeveloperIDCandidateRejectsTamperedNestedCode() throws {
        let identity = try identity("OILFIND_TEST_DEVELOPER_IDENTITY")
        try withSignedApp(identity: identity) { app in
            try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/Frameworks/OilFindHelper"))
            assertSignatureRejected(app)
        }
    }

    func testRealBridgeAndDeveloperIDUpdateChain() throws {
        let root = try identity("OILFIND_TEST_CHAIN_ROOT")
        let fixture = URL(fileURLWithPath: root, isDirectory: true)
        let files = SystemUpdateFiles()
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("oilfind-update-chain-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temporary) }
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let app = temporary.appendingPathComponent("Oil Find.app")
        try fm.copyItem(at: fixture.appendingPathComponent("old/Oil Find.app"), to: app)

        func install(_ archiveName: String, _ feedName: String, in directory: String, current: UpdateVersion) throws -> UpdateVersion {
            let archive = fixture.appendingPathComponent("\(directory)/\(archiveName)")
            let feed = fixture.appendingPathComponent("\(directory)/\(feedName)")
            let manifest = try UpdateManifest.parse(try Data(contentsOf: feed))
            let signing = RunningRequirementCodeSigning(running: try designatedRequirement(for: app))
            let installer = UpdateInstaller(application: app, current: current,
                signature: SystemUpdateSignature(codeSigning: signing))
            let installation = try installer.install(archive: archive, manifest: manifest)
            return try files.version(of: installation.target)
        }

        let original = try files.version(of: app)
        let bridge = try install("Oil-Find.zip", "latest.json", in: "bridge", current: original)
        XCTAssertEqual(bridge.version.text, "1.7.2")
        XCTAssertEqual(bridge.build, 17)
        let developer = try install("Oil-Find.zip", "latest-v2.json", in: "developer", current: bridge)
        XCTAssertEqual(developer.version.text, "1.7.3")
        XCTAssertEqual(developer.build, 18)
        XCTAssertNoThrow(try SystemUpdateSignature().validate(app))
    }

    private func designatedRequirement(for app: URL) throws -> SecRequirement {
        var candidate: SecStaticCode?, requirement: SecRequirement?
        XCTAssertEqual(SecStaticCodeCreateWithPath(app as CFURL, [], &candidate), errSecSuccess)
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(candidate), [], &requirement), errSecSuccess)
        return try XCTUnwrap(requirement)
    }

    private func withSignedApp(identifier: String = "com.oiloil.find", identity: String, _ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("oilfind-signature-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Oil Find.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/OilFind")
        let helper = app.appendingPathComponent("Contents/Frameworks/OilFindHelper")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "OilFind",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: helper)
        try sign(helper, identity: identity, identifier: identifier + ".helper")
        try sign(app, identity: identity, identifier: identifier)
        try body(app)
    }

    private func sign(_ code: URL, identity: String, identifier: String) throws {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--force", "--sign", identity, "--identifier", identifier, "--timestamp=none", code.path]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "UpdateSignatureIntegrationTests", code: Int(task.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self),
            ])
        }
    }
}

private final class RunningRequirementCodeSigning: UpdateCodeSigning {
    private let running: SecRequirement
    private let system = SystemUpdateCodeSigning()
    private(set) var developerIDRequests = 0

    init(running: SecRequirement) { self.running = running }
    func runningDesignatedRequirement() -> SecRequirement? { running }
    func requirement(from source: String) -> SecRequirement? {
        developerIDRequests += 1
        return system.requirement(from: source)
    }
    func validate(_ app: URL, against requirement: SecRequirement) -> Bool {
        system.validate(app, against: requirement)
    }
}
