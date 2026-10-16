import Foundation
@testable import OilFindApp

func runCoreChecks(_ root: URL) throws {
    let directory = root.appendingPathComponent("core-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("index.sqlite"), index = try AITopicIndex(url: directory.appendingPathComponent("index.sqlite"))
    var checks = 0
    func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw NSError(domain: "Core: " + label, code: 1) }; checks += 1
    }
    let words = ["搜索","索引","功能","Claude","Codex","sqlite","swift","gh","pr","abc","aba","bab","开发","界面","登录","设置","a%b","x_y","e\u{301}","é","👩‍💻","👩","👩🏽‍💻","代码","beta","Ωμέγα","İ","العربية","go"]
    var state: UInt64 = 42
    func random(_ limit: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 32) % UInt64(limit)) }
    var rows: [(AITopic,[String])] = []
    for i in 0..<80 {
        let topic = AITopic(id: String(format: "case-%03d", i), provider: i % 2 == 0 ? .claude : .codex, title: words[random(words.count)] + " " + words[random(words.count)], project: "/demo/" + String(i), modified: Double(i))
        let bodies = (0..<6).map { _ in (0..<(2 + random(5))).map { _ in words[random(words.count)] }.joined(separator: [" ","|","-","\n"][random(4)]) }
        rows.append((topic,bodies))
        try index.transaction { try index.upsert(topic); for (j,body) in bodies.enumerated() { try index.message(topic.key, key: String(j), body: body) } }
    }
    let reader = try AITopicIndex(url: url, readOnly: true)
    var queries = words + ["不存在的固定句子", "abab", "%", "_", "'", "\" OR 1=1 --", "👩", "i\u{307}"]
    for _ in 0..<180 { queries.append(words[random(words.count)] + " " + words[random(words.count)]) }
    for _ in 0..<80 {
        let body = rows[random(rows.count)].1[random(6)], scalars = Array(body.unicodeScalars)
        let start = random(scalars.count), end = min(scalars.count, start + 1 + random(8))
        queries.append(String(String.UnicodeScalarView(scalars[start..<end])))
    }
    let folded = rows.map { row in (row.0, ([row.0.title + "\n" + row.0.project] + row.1).map { Data(AITopicIndex.fold($0).utf8) }) }
    for query in Set(queries).sorted() {
        let terms = AITopicIndex.fold(query).split(whereSeparator: { $0.isWhitespace }).map { Data($0.utf8) }
        for provider: AITopicProvider? in [nil, .claude, .codex] {
            let expected = folded.filter { row in (provider == nil || row.0.provider == provider) && terms.allSatisfy { needle in row.1.contains { $0.range(of: needle) != nil } } }
                .sorted { $0.0.modified > $1.0.modified }.prefix(13).map { $0.0.key }
            let actual = try reader.search(query, provider: provider, limit: 13)
            try require(actual.topics.map(\.key) == expected, "oracle \(query) provider=\(String(describing:provider))")
        }
    }
    let tinyCache = try AITopicIndex(url: url, readOnly: true, cacheBudgetBytes: 4096)
    for query in words {
        let expected = try reader.search(query, limit: 13).topics.map(\.key)
        try require(try tinyCache.search(query, limit: 13).topics.map(\.key) == expected, "cache eviction preserves results")
        try require(tinyCache.documentCacheBytes <= 4096, "cache budget is enforced")
    }
    let noCache = try AITopicIndex(url: url, readOnly: true, cacheBudgetBytes: 0)
    try require(try noCache.search("代码").topics.map(\.key) == reader.search("代码").topics.map(\.key) && noCache.documentCacheBytes == 0, "cache can be disabled without changing results")
    let edge = AITopic(id: "edge", provider: .claude, title: "edge", modified: 1000)
    try index.transaction {
        try index.upsert(edge)
        try index.message(edge.key, key: "a", body: "aba x bab")
        try index.message(edge.key, key: "b", body: "ab")
        try index.message(edge.key, key: "c", body: "c")
    }
    try require(try reader.search("abab").topics.allSatisfy { $0.key != edge.key }, "remove overlapping-gram false positives")
    try require(try reader.search("abc").topics.allSatisfy { $0.key != edge.key }, "no matches across message boundaries")
    try index.message(edge.key, key: "long", body: String(repeating: "压缩正文里有 SQL 和代码。", count: 2000) + "独特的压缩尾部")
    try require(try reader.search("独特的压缩尾部").topics.first?.key == edge.key, "compressed body search")
    try index.message(edge.key, key: "long", body: "")
    try require(try reader.search("独特的压缩尾部").topics.isEmpty, "empty replacement removes old postings")
    try index.message(edge.key, key: "nul", body: "before\0after")
    try require(try reader.search("before\0after").topics.first?.key == edge.key, "literal embedded NUL")
    try index.message(edge.key, key: "cache", body: "旧缓存中的唯一版本")
    try require(try reader.search("旧缓存中的唯一版本").topics.first?.key == edge.key, "prime document cache")
    try index.message(edge.key, key: "cache", body: "更新后新的唯一版本")
    try require(try reader.search("更新后新的唯一版本").topics.first?.key == edge.key, "revision invalidates cached documents")
    try require(try reader.search("旧缓存中的唯一版本").topics.isEmpty, "cached old content is withdrawn")
    do {
        try index.transaction { try index.message(edge.key, key: "rollback", body: "回滚以后不能检索到"); throw NSError(domain:"intentional rollback",code:1) }
    } catch { }
    try require(try reader.search("回滚以后不能检索到").topics.isEmpty, "transaction rollback leaves consistent postings")
    var polls = 0
    let cancelled = try reader.search("代码", isCancelled: { polls += 1; return polls > 2 })
    try require(polls > 2 && cancelled.topics.isEmpty, "in-flight cancellation")
    try require(try !reader.search("代码").topics.isEmpty, "reader remains usable after cancellation")
    try JSONSerialization.data(withJSONObject: ["checks":checks,"passed":true,"topics":rows.count,"unique_queries":Set(queries).count], options:[.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("core-results.json"))
    print("All \(checks) core/oracle checks passed across \(Set(queries).count) unique queries")
}
