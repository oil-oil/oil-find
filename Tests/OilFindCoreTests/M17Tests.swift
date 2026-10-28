import XCTest
import Darwin
@testable import OilFindCore

final class M17Tests: XCTestCase {
    private func fixture(_ body: (URL, IndexStore, IndexConfig) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindM17-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["src", "node_modules", "latest", "test", "Node_Modules", "文档", "Desktop", "my_node_modules", "ÄPFEL"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["src/readme.md", "node_modules/readme.md", "latest/readme.md", "test/readme.md", "Node_Modules/readme.md", "my_node_modules/readme.md", "ÄPFEL/readme.md", "文档/项目文档.md", "项目文档.md", "Desktop/a.png", "foo.txt", "bar.txt", "IMG_123.jpg", "file2.txt", "file10.txt", "ÄPFEL.txt", "b c.md", "main.swift", "report final.pdf", "a | b.txt", "a !b.txt", "a colon:1.txt", "readme中文.md", "LICENSE", ".env", ".config.json", "trailing."] {
            try Data(repeating: 65, count: 4).write(to: root.appendingPathComponent(name))
        }
        let config = IndexConfig(rootPath: root.path, indexDependencyDirs: true, indexPackageContents: true, indexUserLibrary: true, indexSystemDirs: true)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 2).run()), config: config)
        store.write { store.buildHash() }
        try body(root, store, config)
    }
    private func paths(_ text: String, root: URL, store: IndexStore, pinyin: Bool = true) throws -> Set<String> {
        let query = Query.parse(text, home: root.path, store: store)
        let result = try XCTUnwrap(Searcher.search(query, options: SearchOptions(pinyin: pinyin), in: store))
        return Set(result.items.map { store.path($0).replacingOccurrences(of: root.path + "/", with: "") })
    }
    func testORWhitespaceAndTypedFilters() throws {
        try fixture { root, store, _ in
            for text in ["foo|bar", "foo | bar", "foo |bar", "foo| bar", "foo\t|\nbar"] {
                XCTAssertEqual(try paths(text, root: root, store: store), ["foo.txt", "bar.txt"], text)
            }
            XCTAssertEqual(try paths("file:readme", root: root, store: store), try paths("readme file:", root: root, store: store))
            XCTAssertEqual(try paths("folder:src", root: root, store: store), ["src"])
            XCTAssertEqual(try paths("foo | bar ext:txt", root: root, store: store), ["foo.txt", "bar.txt"])
        }
    }
    func testExistingPasteAndCombinedPathsUseAtMostOneStat() throws {
        try fixture { root, store, _ in
            XCTAssertEqual(try paths("src/ readme", root: root, store: store), ["src/readme.md"])
            XCTAssertEqual(try paths("\"src/\" readme", root: root, store: store), ["src/readme.md"])
            XCTAssertEqual(try paths("~/Desktop/ png", root: root, store: store), ["Desktop/a.png"])
            for input in [root.path + "/a | b.txt", root.path + "/a !b.txt", root.path + "/a colon:1.txt", root.path + "/b c.md", "'" + root.path + "/b c.md'", URL(fileURLWithPath: root.path + "/b c.md").absoluteString, root.path + "/b\\ c.md", root.path + "/b c.md:10:5"] {
                var calls = 0
                let query = Query.parse(input, store: store, pathExists: { _ in calls += 1; return false })
                XCTAssertEqual(calls, 0, input)
                XCTAssertEqual(try XCTUnwrap(Searcher.search(query, in: store)).total, 1, input)
            }
            var calls = 0
            let query = Query.parse("src/ readme", store: store, pathExists: { _ in calls += 1; return false })
            XCTAssertEqual(calls, 1); XCTAssertEqual(query.clauses.count, 2)
            XCTAssertEqual(Query.parse("/absent/a b", pathExists: { _ in false }).clauses.count, 2)
        }
    }
    func testPlainNegationUsesExactAncestorAndPathNegationUsesSubstring() throws {
        try fixture { root, store, _ in
            let expected: Set<String> = ["src/readme.md", "latest/readme.md", "test/readme.md", "my_node_modules/readme.md", "ÄPFEL/readme.md", "readme中文.md"]
            XCTAssertEqual(try paths("readme !node_modules", root: root, store: store), expected)
            XCTAssertEqual(try paths("!node_modules readme", root: root, store: store), expected)
            XCTAssertEqual(try paths("readme !path:node_modules", root: root, store: store), expected.subtracting(["my_node_modules/readme.md"]))
            XCTAssertEqual(try paths("readme !src/", root: root, store: store), try paths("readme", root: root, store: store).subtracting(["src/readme.md"]))
            XCTAssertTrue(try paths("readme !test", root: root, store: store).contains("latest/readme.md"))
            XCTAssertFalse(try paths("readme !test", root: root, store: store).contains("test/readme.md"))
            XCTAssertFalse(try paths("readme !äpfel", root: root, store: store).contains("ÄPFEL/readme.md"))
            XCTAssertEqual(try paths("文档 !文档", root: root, store: store), [])
            XCTAssertEqual(try paths("wd !文档/", root: root, store: store), ["文档", "项目文档.md"])
            XCTAssertEqual(try paths("wd ext:md", root: root, store: store), ["文档/项目文档.md", "项目文档.md"])
            XCTAssertEqual(try paths("wendang ext:md", root: root, store: store), ["文档/项目文档.md", "项目文档.md"])
            XCTAssertEqual(try paths("wd ext:md", root: root, store: store, pinyin: false), [])
        }
    }
    func testGap13RemainingSamplesAndKindValues() throws {
        try fixture { root, store, _ in
            XCTAssertEqual(try paths(#"regex:^IMG_\d+"#, root: root, store: store), ["IMG_123.jpg"])
            XCTAssertEqual(try paths("äpfel", root: root, store: store), try paths("ÄPFEL", root: root, store: store))
            XCTAssertEqual(try paths("ext:md;png", root: root, store: store), try paths("ext:md | ext:png", root: root, store: store))
            XCTAssertEqual(try paths("ext:md,png", root: root, store: store), try paths("ext:md;png", root: root, store: store))
            XCTAssertEqual(try paths("ext:md，png", root: root, store: store), try paths("ext:md;png", root: root, store: store))
            XCTAssertTrue(try paths("size:>3b", root: root, store: store).contains("foo.txt"))
            XCTAssertTrue(try paths("dm:today", root: root, store: store).contains("foo.txt"))
            let sorted = try XCTUnwrap(Searcher.search(Query.parse("file"), options: SearchOptions(sort: .name, ascending: true), in: store))
            XCTAssertEqual(sorted.items.map { store.name($0) }, ["file2.txt", "file10.txt"])
        }
        for (i, name) in Query.kindNames.enumerated() { XCTAssertEqual(Query.kindValue(name), UInt8(i + 1)); XCTAssertEqual(Query.kindValue(String(i + 1)), UInt8(i + 1)) }
        for value in ["9", "-1", "256", "bogus", ""] { XCTAssertNil(Query.kindValue(value)) }
    }
    func testFilesWithoutExtensions() throws {
        try fixture { root, store, _ in
            XCTAssertEqual(try paths("noext:", root: root, store: store), ["LICENSE", ".env", "trailing."])
            XCTAssertEqual(try paths("noext: license", root: root, store: store), ["LICENSE"])
            XCTAssertFalse(try paths("noext:", root: root, store: store).contains("src"))
        }
    }
    func testDiagnosticsRetainExecutableQueryAndRespectEditing() throws {
        for (text, kind) in [("regex:[", QueryDiagnostic.Kind.regex), ("kind:unknown", .kind), ("size:10zz", .size), ("size:5mb..1mb", .size), ("dm:2026-02-31", .date), ("dm:nope", .date)] {
            let query = Query.parse(text)
            XCTAssertEqual(query.diagnostics.map(\.kind), [kind], text)
            XCTAssertFalse(query.isEmpty)
            XCTAssertTrue(Query.parse(text, editingRange: NSRange(location: text.utf16.count, length: 0)).diagnostics.isEmpty)
            XCTAssertTrue(Query.parse(text + " ", editingRange: NSRange(location: text.utf16.count + 1, length: 0)).diagnostics.count == 1)
            XCTAssertTrue(Query.parse(text, isComposing: true).diagnostics.isEmpty)
        }
        for input in ["'regex:/['", "  regex:/[", "e\u{301} regex:/[", "regex:/\\[ kind:wrong"] {
            XCTAssertTrue(Query.parse(input, editingRange: NSRange(location: input.utf16.count, length: 0)).diagnostics.filter { $0.kind == (input.contains("kind:") ? .kind : .regex) }.isEmpty)
        }
        XCTAssertEqual(Query.parse("kind:bad size:no dm:no regex:[").diagnostics.count, 4)
        XCTAssertTrue(Query.parse("kind:image size:>10mb dm:today regex:^IMG_").diagnostics.isEmpty)
        try fixture { root, store, _ in
            XCTAssertEqual(try paths("foo kind:bad", root: root, store: store), ["foo.txt"])
            XCTAssertEqual(try paths("regex:[", root: root, store: store), [])
        }
    }
    func testCoverageCountsSamplesPersistenceCompactionAndIncrementalExclusion() throws {
        try fixture { root, _, _ in
            let excluded = root.appendingPathComponent("latest").path
            let config = IndexConfig(rootPath: root.path, userExcludedPaths: [excluded], indexSystemDirs: true)
            let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config).run()), config: config)
            store.write { store.buildHash() }
            XCTAssertEqual(store.coverage[.dependency].count, 1)
            XCTAssertEqual(store.coverage[.userExcluded].count, 1)
            XCTAssertEqual(Coverage.explain(path: root.path + "/foo.txt", config: config, store: store), .indexed)
            XCTAssertEqual(Coverage.explain(path: excluded + "/readme.md", config: config, store: store), .userExcluded(excluded))
            XCTAssertEqual(Coverage.explain(path: root.path + "/node_modules/readme.md", config: config, store: store), .scope(.dependency))
            XCTAssertEqual(Coverage.explain(path: "/Volumes/example/a", config: config, store: store), .volume)
            XCTAssertEqual(Coverage.explain(path: root.path + "/missing", config: config, store: store), .pending)
            _ = IndexUpdater(config: config).apply([FSChange(path: excluded + "/readme.md", eventId: 4), FSChange(path: excluded + "/readme.md", eventId: 5)], to: store)
            XCTAssertEqual(store.coverage[.userExcluded].count, 2)
            var stats = CoverageStats()
            for i in 0..<20 { Array("/test/\(i)".utf8).withUnsafeBufferPointer { stats.record(.noAccess, path: $0) } }
            XCTAssertEqual(stats[.noAccess].count, 20); XCTAssertEqual(stats[.noAccess].examples.count, 5)
            store.coverage.merge(stats)
            let db = root.appendingPathComponent("test.oilfind")
            try store.save(to: db.path)
            let loaded = try XCTUnwrap(IndexStore.load(from: db.path))
            XCTAssertEqual(loaded.coverage, store.coverage)
            XCTAssertEqual(store.compacted().coverage, store.coverage)
            let data = try Data(contentsOf: db)
            XCTAssertGreaterThan(data.count, 256)
            var legacy = data
            let length = (0..<4).reduce(0) { $0 | Int(data[116 + $1]) << ($1 * 8) }
            legacy.removeLast(length); legacy[8] = 2
            try legacy.write(to: db)
            XCTAssertEqual(try XCTUnwrap(IndexStore.load(from: db.path)).coverage, CoverageStats())
        }
    }
    func testBatchedNameNegationPreservesFullEvaluationScores() throws {
        try fixture { root, store, _ in
            for text in ["readme !node_modules", "!test readme !src", "wd !node_modules", "文档 !test", "case:README !node_modules", "readme !case:README", "readme !zw", "readme !" + root.lastPathComponent.lowercased()] {
                for kind: UInt8? in [nil, 1, 3, 4] {
                    for pinyin in [true, false] {
                    let options = SearchOptions(kind: kind, pinyin: pinyin)
                    let batch = try XCTUnwrap(Searcher.search(Query.parse(text), options: options, in: store))
                    let full = try XCTUnwrap(Searcher.search(Query.parse(text + " size:0..1000000000"), options: options, in: store))
                    XCTAssertEqual(batch.items, full.items, text); XCTAssertEqual(batch.scores, full.scores, text)
                    }
                }
            }
        }
    }
    func testScopeClassificationAndSampleBoundsForEveryReason() {
        let config = IndexConfig.standard(limited: true)
        let cases: [(String, CoverageReason)] = [("/usr/local/a", .system), (NSHomeDirectory() + "/Library/Mail", .library), ("/Users/demo/project/node_modules", .dependency), ("/Applications/Demo.app/Contents", .packages), (NSHomeDirectory() + "/Library/Containers/a", .noAccess)]
        for (path, reason) in cases { XCTAssertEqual(Array(path.utf8).withUnsafeBufferPointer { config.exclusionReason(path: $0) }, reason) }
        var stats = CoverageStats()
        for reason in CoverageReason.allCases {
            for i in 0..<20 { Array("/example/\(i)".utf8).withUnsafeBufferPointer { stats.record(reason, path: $0) } }
            XCTAssertEqual(stats[reason].count, 20); XCTAssertEqual(stats[reason].examples.count, 5)
        }
        XCTAssertEqual(stats.scopeCount, 80)
    }
    func testPermissionAndPackageCoverage() throws {
        try fixture { root, _, _ in
            let denied = root.appendingPathComponent("denied")
            try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Demo.app"), withIntermediateDirectories: true)
            XCTAssertEqual(chmod(denied.path, 0), 0)
            defer { chmod(denied.path, 0o700) }
            let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
            let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config).run()), config: config)
            XCTAssertEqual(store.coverage[.packages].count, 1)
            XCTAssertEqual(store.coverage[.noAccess].count, 1)
            XCTAssertEqual(Coverage.explain(path: denied.path + "/a", config: config, store: store), .noAccess)
        }
    }
}
