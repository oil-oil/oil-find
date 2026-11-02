import XCTest
import Foundation
@testable import OilFindCore

final class M14Tests: XCTestCase {
    private func withTree(_ body: (URL, IndexStore) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OilFindM14-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for directory in ["Oil Find.app", "readme", "Readme.app", "docs", "项目目录"] {
            try fm.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for file in ["b c.md", "main.swift", "README.md", "README documentation.md", "docs.md", "other.txt", "项目文档.md"] {
            try Data([65]).write(to: root.appendingPathComponent(file))
        }
        let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 2).run()), config: config)
        try body(root, store)
    }

    func testT110NormalizePaste() {
        let examples: [(String, String)] = [
            ("~/a.txt\n", "~/a.txt"),
            (" \t/a/b.md\r\n", "/a/b.md"),
            ("'/a/b c.app'", "/a/b c.app"),
            ("\"/a/b c.app\"", "/a/b c.app"),
            (#"'/a/Oil\' Find.app'"#, "/a/Oil' Find.app"),
            ("file:///Users/a/b%20c.md", "/Users/a/b c.md"),
            ("file://localhost/Users/a/b%20c.md", "/Users/a/b c.md"),
            ("file://LOCALHOST/Users/a/b%20c.md", "/Users/a/b c.md"),
            ("file://server/Users/a/b%20c.md", "file://server/Users/a/b%20c.md"),
            ("file:///a/%E9%A1%B9%E7%9B%AE.md", "/a/项目.md"),
            ("file:///a/b%ZZ.md", "file:///a/b%ZZ.md"),
            ("file:///a/b%FF.md", "file:///a/b%FF.md"),
            ("file://localhost", "file://localhost"),
            ("/a/Oil\\ Find.app", "/a/Oil Find.app"),
            (#"/a/\(b\)\'c\"\&\;\[d\].md"#, #"/a/(b)'c"&;[d].md"#),
            (#"/a/b\d\q.md"#, #"/a/b\d\q.md"#),
            ("/a/main.swift:10:5", "/a/main.swift"),
            ("/a/main.swift:10", "/a/main.swift"),
            ("/a/b:12", "/a/b:12"),
            ("/a.swift/b:12", "/a.swift/b:12"),
            ("/a/main.swift:ten", "/a/main.swift:ten"),
            ("/a/main.swift:", "/a/main.swift:"),
            ("/a/main.swift/:12", "/a/main.swift/:12"),
            ("file:///a/b/", "/a/b/"),
            ("/a/Oil Find.app", "/a/Oil Find.app"),
            ("readme", "readme"),
            ("report final", "report final"),
            (" \treadme\n", " \treadme\n"),
            ("\"a b\" c", "\"a b\" c"),
            ("\"/a/b c\" \"d/e\"", "\"/a/b c\" \"d/e\""),
            ("file:report", "file:report")
        ]
        for (input, expected) in examples {
            XCTAssertEqual(Query.normalizePaste(input), expected, input)
            XCTAssertEqual(Query.parse(input).raw, expected.precomposedStringWithCanonicalMapping, input)
        }
        let path = Query.parse(" \t'/a/Oil\\ Find.app'\n", pathExists: { _ in true })
        XCTAssertEqual(path.raw, "/a/Oil Find.app")
        XCTAssertEqual(path.clauses.count, 1)
        guard case .path(let components) = path.clauses[0].alternatives[0].matcher else { return XCTFail("Expected one path atom") }
        XCTAssertEqual(components.map { String(decoding: $0, as: UTF8.self) }, ["", "a", "oil find.app"])
        XCTAssertEqual(Query.parse("\"a b\" c").clauses.count, 2)
        XCTAssertEqual(Query.parse("\"/a/b c\" \"d/e\"").clauses.count, 2)
        XCTAssertEqual(Query.parse("\"/a/b c\" !readme").clauses.count, 2)
        XCTAssertEqual(Query.parse("/a/b !readme").clauses.count, 2)
        let alternatives = Query.parse("/a/b c|d")
        XCTAssertEqual(alternatives.clauses.count, 2)
        XCTAssertEqual(alternatives.clauses[1].alternatives.count, 2)
    }

    func testT111PastedPathsFindExactlyOneEntry() throws {
        try withTree { root, store in
            for name in ["Oil Find.app", "b c.md", "main.swift"] {
                let path = root.appendingPathComponent(name).path
                let url = URL(fileURLWithPath: path, isDirectory: false)
                var inputs = ["'\(path)'", "\"\(path)\"", " \t'\(path)'\n", path,
                              url.absoluteString, url.absoluteString.replacingOccurrences(of: "file://", with: "file://localhost"),
                              path.replacingOccurrences(of: " ", with: "\\ "), path + ":10:5", path + ":10"]
                inputs.append(url.absoluteString + ":10:5")
                for input in inputs {
                    let result = try XCTUnwrap(Searcher.search(Query.parse(input), in: store))
                    XCTAssertEqual(result.total, 1, input)
                    XCTAssertEqual(result.items.map { store.path($0) }, [path], input)
                }
            }
        }
    }

    func testT112TypedNamesPreserveResultsNegationAndOR() throws {
        for (text, folders) in [("file:readme", false), ("folder:docs", true)] {
            let query = Query.parse(text)
            XCTAssertEqual(query.clauses.count, 2)
            XCTAssertTrue(query.clauses.allSatisfy { $0.alternatives.count == 1 && !$0.alternatives[0].negated })
            if folders {
                guard case .foldersOnly = query.clauses[0].alternatives[0].matcher else { return XCTFail("Expected folder filter") }
            } else {
                guard case .filesOnly = query.clauses[0].alternatives[0].matcher else { return XCTFail("Expected file filter") }
            }
            guard case .name(_, let sensitive) = query.clauses[1].alternatives[0].matcher else { return XCTFail("Expected name driver") }
            XCTAssertFalse(sensitive)
        }
        let negated = Query.parse("!file:readme")
        XCTAssertEqual(negated.clauses.count, 1)
        XCTAssertTrue(negated.clauses[0].alternatives[0].negated)
        guard case .fileName = negated.clauses[0].alternatives[0].matcher else { return XCTFail("Expected combined negated matcher") }
        try withTree { root, store in
            let pairs = [("file:readme", "readme file:"), ("folder:docs", "docs folder:"),
                         ("FILE:README", "readme file:"), ("FOLDER:DOCS", "docs folder:"),
                         ("file:\"README documentation\"", "\"README documentation\" file:"),
                         ("file:xm", "xm file:"), ("folder:xm", "xm folder:"),
                         ("file:项目", "项目 file:"), ("folder:项目", "项目 folder:")]
            for pinyin in [true, false] {
                for sort in [SortKey.relevance, .name, .modified, .size] {
                    let options = SearchOptions(sort: sort, pinyin: pinyin)
                    for (typed, separate) in pairs {
                        let a = try XCTUnwrap(Searcher.search(Query.parse(typed), options: options, in: store))
                        let b = try XCTUnwrap(Searcher.search(Query.parse(separate), options: options, in: store))
                        XCTAssertEqual(Set(a.items), Set(b.items), typed)
                        XCTAssertEqual(a.items, b.items, typed)
                        XCTAssertEqual(a.scores, b.scores, typed)
                        XCTAssertEqual(a.total, b.total, typed)
                    }
                }
            }
            func ids(_ text: String) throws -> Set<UInt32> {
                Set(try XCTUnwrap(Searcher.search(Query.parse(text), in: store)).items)
            }
            let all = Set((1..<store.count).map(UInt32.init))
            for (text, matcher, positive) in [("!file:readme", Matcher.fileName(Array("readme".utf8)), "file:readme"),
                                               ("!folder:docs", Matcher.folderName(Array("docs".utf8)), "folder:docs")] {
                let legacy = Query(clauses: [Clause(alternatives: [Atom(negated: true, matcher: matcher)])], raw: text)
                XCTAssertEqual(try ids(text), Set(try XCTUnwrap(Searcher.search(legacy, in: store)).items), text)
                XCTAssertEqual(try ids(text), all.subtracting(try ids(positive)), text)
            }
            let inversePaths = try ids("!file:readme").map { store.path($0) }
            XCTAssertTrue(inversePaths.contains(root.appendingPathComponent("readme").path))
            let filePaths = try ids("file:readme").map { store.path($0) }
            XCTAssertTrue(filePaths.contains(root.appendingPathComponent("Readme.app").path))
            XCTAssertFalse(filePaths.contains(root.appendingPathComponent("readme").path))
            for (left, right) in [("file:readme", "folder:docs"), ("file:readme", "docs"),
                                  ("file:readme", "!folder:docs"), ("folder:docs", "folder:readme")] {
                XCTAssertEqual(try ids(left + "|" + right), try ids(left).union(ids(right)))
            }
            XCTAssertEqual(try ids("file:readme|folder:docs ext:md"),
                           try ids("file:readme").union(ids("folder:docs")).intersection(ids("ext:md")))
        }
    }

    func testT113TypedNameMedianWithinTwiceSeparateFilters() throws {
        try skipIfCI("The search latency ratio is performance-sensitive in CI.")
        let entryCount = 524_288, count = entryCount + 1
        let names = ["ordinary-item.txt", "README.md", "src"].map { Array($0.utf8) }
        let store = IndexStore(rootPath: "/", count: count, namesLen: entryCount * names[0].count,
                               altCount: 0, altLen: 0, fingerprint: 0, homeIndex: .max, finishedAt: 0)
        store.nameOff[0] = 0; store.parent[0] = 0; store.flags[0] = SiftFlag.dir
        store.kind[0] = 1; store.depth[0] = 0; store.sizeC[0] = 0; store.mtime[0] = 0; store.altOff[0] = 0
        var offset = 0
        for i in 1..<count {
            let pattern = i % 512 == 0 ? 1 : (i % 512 == 1 ? 2 : 0), bytes = names[pattern]
            store.nameOff[i] = UInt32(offset)
            bytes.withUnsafeBufferPointer { store.names.advanced(by: offset).update(from: $0.baseAddress!, count: bytes.count) }
            offset += bytes.count
            store.parent[i] = 0; store.flags[i] = pattern == 2 ? SiftFlag.dir : 0
            store.kind[i] = pattern == 2 ? 1 : 3; store.depth[i] = 1
            store.sizeC[i] = 1; store.mtime[i] = 1_700_000_000
        }
        store.namesLen = offset; store.nameOff[count] = UInt32(offset)
        let queue = DispatchQueue(label: "OilFindM14.performance", qos: .userInteractive)
        for (typed, separate) in [("file:readme", "readme file:"), ("folder:src", "src folder:")] {
            let queries = [Query.parse(typed), Query.parse(separate)]
            func search(_ i: Int) throws -> SearchResult {
                try XCTUnwrap(queue.sync { Searcher.search(queries[i], in: store) })
            }
            let expected = try search(1)
            XCTAssertEqual(expected.total, 1024)
            XCTAssertEqual(try search(0).items, expected.items)
            var times = [[Double](), [Double]()]
            for iteration in 0..<20 {
                for i in iteration.isMultiple(of: 2) ? [0, 1] : [1, 0] {
                    let result = try search(i)
                    XCTAssertEqual(result.total, expected.total)
                    times[i].append(result.elapsedMs)
                }
            }
            let typedMedian = times[0].sorted()[10], separateMedian = times[1].sorted()[10]
            print(String(format: "T113 %@ median=%.3fms %@ median=%.3fms ratio=%.3f", typed, typedMedian, separate, separateMedian, typedMedian / separateMedian))
            XCTAssertLessThanOrEqual(typedMedian, separateMedian * 2, typed)
        }
    }
}
