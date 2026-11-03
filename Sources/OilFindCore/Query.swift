import Foundation
import Darwin

public struct Query {
    public var clauses: [Clause]
    public var raw: String
    public var diagnostics: [QueryDiagnostic] = []
    public var isEmpty: Bool { clauses.isEmpty }
    public var isTimeDependent: Bool {
        clauses.contains { clause in
            clause.alternatives.contains { atom in
                if case .modified = atom.matcher { return true }
                return false
            }
        }
    }
    public static func normalizePaste(_ text: String) -> String {
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.contains("/") || source.hasPrefix("~") || source.hasPrefix("file:") else { return text }
        if let first = source.first, source.count >= 2,
           (first == "'" || first == "\""), source.last == first {
            var escaped = false, innerQuote = false
            for c in source.dropFirst().dropLast() {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == first { innerQuote = true; break }
            }
            if !innerQuote && !escaped { source = String(source.dropFirst().dropLast()) }
        }
        if source.hasPrefix("file://") {
            let remainder = source.dropFirst(7)
            if let slash = remainder.firstIndex(of: "/"),
               let decoded = String(remainder[slash...]).removingPercentEncoding {
                source = decoded
            }
        }
        let escapable: Set<Character> = [" ", "(", ")", "'", "\"", "&", ";", "[", "]"]
        var unescaped = "", cursor = source.startIndex
        while cursor < source.endIndex {
            let next = source.index(after: cursor)
            if source[cursor] == "\\", next < source.endIndex, escapable.contains(source[next]) {
                unescaped.append(source[next]); cursor = source.index(after: next)
            } else {
                unescaped.append(source[cursor]); cursor = next
            }
        }
        source = unescaped
        var end = source.endIndex
        for _ in 0..<2 {
            guard let colon = source[..<end].lastIndex(of: ":") else { break }
            let digits = source[source.index(after: colon)..<end]
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { break }
            end = colon
        }
        if end != source.endIndex, source[..<end].split(separator: "/", omittingEmptySubsequences: false).last?.contains(".") == true {
            source = String(source[..<end])
        }
        return source
    }
    public static let kindNames = ["folder", "app", "doc", "image", "video", "audio", "code", "archive"]
    public static func kindValue(_ value: String) -> UInt8? {
        if let i = kindNames.firstIndex(of: value.lowercased()) { return UInt8(i + 1) }
        if let n = UInt8(value), n <= 8 { return n }
        return nil
    }
    public static func parse(_ text: String, now: Date = Date(), home: String = NSHomeDirectory(),
                             store: IndexStore? = nil, editingRange: NSRange? = nil, isComposing: Bool = false,
                             pathExists: ((String) -> Bool)? = nil) -> Query {
        let source = normalizePaste(text).precomposedStringWithCanonicalMapping
        var clauses: [Clause] = [], alts: [Atom] = [], diagnostics: [QueryDiagnostic] = []
        func flushClause() {
            guard !alts.isEmpty else { return }
            if alts.count == 1, !alts[0].negated {
                let needle: [UInt8], filter: Matcher
                switch alts[0].matcher {
                case .fileName(let n): needle = n; filter = .filesOnly
                case .folderName(let n): needle = n; filter = .foldersOnly
                default: clauses.append(Clause(alternatives: alts)); alts = []; return
                }
                clauses.append(Clause(alternatives: [Atom(negated: false, matcher: filter)]))
                clauses.append(Clause(alternatives: [Atom(negated: false, matcher: .name(needle: needle, caseSensitive: false))]))
            } else { clauses.append(Clause(alternatives: alts)) }
            alts = []
        }
        let possiblePath = source.contains("/") && source.contains(where: { $0.isWhitespace })
        var wholePath = false
        if possiblePath {
            let expanded = source.hasPrefix("~") ? home + source.dropFirst() : source
            let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
            let indexed = store?.read { store!.containsPath(absolute) } ?? false
            if indexed { wholePath = true }
            else if let pathExists { wholePath = pathExists(absolute) }
            else { var info = stat(); wholePath = absolute.withCString { stat($0, &info) == 0 } }
        }
        func tokenize(_ input: String) -> [(body: String, range: NSRange)] {
            var result: [(body: String, range: NSRange)] = []
            var token = "", quoted = false, start: String.Index?
            func flush(_ end: String.Index) {
                if let begin = start, !token.isEmpty { result.append((token, NSRange(begin..<end, in: input))) }
                token = ""; start = nil
            }
            for i in input.indices {
                let c = input[i]
                if c == "\"" { if start == nil { start = i }; quoted.toggle(); continue }
                if !quoted && (c.isWhitespace || c == "|") {
                    flush(i)
                    if c == "|" { result.append(("|", NSRange(i..<input.index(after: i), in: input))) }
                } else { if start == nil { start = i }; token.append(c) }
            }
            flush(input.endIndex)
            return result
        }
        let tokens = wholePath ? [(body: source, range: NSRange(location: 0, length: source.utf16.count))] : tokenize(source)
        let originalTokens = tokenize(text)
        var originalCursor = 0
        for i in tokens.indices {
            let t = tokens[i]
            if t.body == "|" { continue }
            var body = t.body, neg = false
            if body.first == "!" { neg = true; body.removeFirst() }
            if !body.isEmpty {
                var originalRange = t.range
                if let colon = body.firstIndex(of: ":") {
                    let key = body[..<colon].lowercased() + ":"
                    if let ordinal = originalTokens.indices.dropFirst(originalCursor).first(where: {
                        let original = originalTokens[$0].body.hasPrefix("!") ? String(originalTokens[$0].body.dropFirst()) : originalTokens[$0].body
                        return normalizePaste(original).lowercased().hasPrefix(key)
                    }) { originalRange = originalTokens[ordinal].range; originalCursor = ordinal + 1 }
                }
                var diagnostic: QueryDiagnostic?
                let matcher = wholePath ? Matcher.path(components: pathComponents(body.lowercased(), home: home)) : parseMatcher(body, now: now, home: home, diagnostic: &diagnostic)
                if var d = diagnostic {
                    d.range = originalRange
                    let editing = editingRange.map { $0.location >= originalRange.location && $0.location <= NSMaxRange(originalRange) } ?? false
                    if !isComposing && !editing { diagnostics.append(d) }
                } else {
                    let ordinary = !body.contains(":") && !body.contains("/") && !body.hasPrefix("~") && !body.contains("*") && !body.contains("?")
                    alts.append(Atom(negated: neg, matcher: matcher, excludesAncestors: neg && ordinary))
                }
            }
            if i + 1 == tokens.count || tokens[i + 1].body != "|" { flushClause() }
        }
        flushClause()
        // A query made only of invalid values must not fall back to the recent-files list.
        if clauses.isEmpty && tokens.contains(where: { $0.body != "|" }) {
            clauses = [Clause(alternatives: [Atom(negated: false, matcher: .name(needle: Array(source.lowercased().utf8), caseSensitive: false))])]
        }
        return Query(clauses: clauses, raw: source, diagnostics: diagnostics)
    }
}
public struct Clause { public var alternatives: [Atom] }
public struct Atom {
    public var negated: Bool; public var matcher: Matcher
    public var excludesAncestors: Bool = false
}
public struct QueryDiagnostic: Equatable {
    public enum Kind: String { case regex, kind, size, date }
    public var kind: Kind
    public var value: String = ""
    public var range: NSRange = NSRange(location: 0, length: 0)
    public init(kind: Kind, value: String = "", range: NSRange = NSRange(location: 0, length: 0)) {
        self.kind = kind; self.value = value; self.range = range
    }
}
public enum Matcher {
    case name(needle: [UInt8], caseSensitive: Bool)
    case path(components: [[UInt8]])
    case glob(pattern: [UInt8], onPath: Bool)
    case regex(NSRegularExpression, onPath: Bool)
    case ext(Set<UInt64>)
    case noExtension
    case kind(UInt8)
    case filesOnly
    case foldersOnly
    case fileName([UInt8])
    case folderName([UInt8])
    case size(ClosedRange<UInt64>)
    case modified(ClosedRange<UInt32>)
}
private func extKey(_ s: String) -> UInt64? {
    let b = Array(s.lowercased().utf8); guard (1...8).contains(b.count), b.allSatisfy({ $0 < 128 }) else { return nil }
    return b.reduce(0) { ($0 << 8) | UInt64($1) }
}
private func parseMatcher(_ body: String, now: Date, home: String, diagnostic: inout QueryDiagnostic?) -> Matcher {
    let lower = body.lowercased()
    if let colon = body.firstIndex(of: ":") {
        let key = body[..<colon].lowercased(), value = String(body[body.index(after: colon)...])
        switch key {
        case "ext":
            let parts = value.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == "，" }).compactMap { extKey(String($0)) }
            if !parts.isEmpty { return .ext(Set(parts)) }
        case "noext": if value.isEmpty { return .noExtension }
        case "kind":
            if let i = Query.kindNames.firstIndex(of: value.lowercased()) { return .kind(UInt8(i + 1)) }
            diagnostic = QueryDiagnostic(kind: .kind)
        case "file": return value.isEmpty ? .filesOnly : .fileName(Array(value.lowercased().utf8))
        case "folder": return value.isEmpty ? .foldersOnly : .folderName(Array(value.lowercased().utf8))
        case "size": if let range = parseSize(value) { return .size(range) }; diagnostic = QueryDiagnostic(kind: .size)
        case "dm": if let range = parseDate(value, now: now) { return .modified(range) }; diagnostic = QueryDiagnostic(kind: .date)
        case "path": return .path(components: pathComponents(value.lowercased(), home: home))
        case "case": return .name(needle: Array(value.utf8), caseSensitive: true)
        case "regex":
            do { return .regex(try NSRegularExpression(pattern: value), onPath: value.contains("/")) }
            catch { diagnostic = QueryDiagnostic(kind: .regex, value: value) }
        default: return .name(needle: Array(lower.utf8), caseSensitive: false)
        }
        return .name(needle: Array(lower.utf8), caseSensitive: false)
    }
    let folded = lower
    if folded.contains("*") || folded.contains("?") { return .glob(pattern: Array(folded.utf8), onPath: folded.contains("/")) }
    if folded.contains("/") || folded.hasPrefix("~") { return .path(components: pathComponents(folded, home: home)) }
    return .name(needle: Array(folded.utf8), caseSensitive: false)
}
private func pathComponents(_ s: String, home: String) -> [[UInt8]] {
    let expanded = s.hasPrefix("~") ? home.lowercased() + s.dropFirst() : s
    return expanded.split(separator: "/", omittingEmptySubsequences: false).map { Array($0.utf8) }
}
private func parseBytes(_ s: String) -> UInt64? {
    let t = s.lowercased()
    let suffixes: [(String, UInt64)] = [("gb", 1_000_000_000), ("mb", 1_000_000), ("kb", 1_000), ("b", 1)]
    let suffix = suffixes.first { t.hasSuffix($0.0) }
    let number = suffix == nil ? t : String(t.dropLast(suffix!.0.count))
    guard let d = Double(number), d >= 0, d.isFinite else { return nil }
    let value = d * Double(suffix?.1 ?? 1)
    // Double(UInt64.max) rounds up to 2^64, so a strict comparison rejects
    // the first representable value that cannot fit in UInt64.
    guard value.isFinite, value >= 0, value < Double(UInt64.max) else { return nil }
    return UInt64(exactly: value.rounded(.towardZero))
}
private func parseSize(_ s: String) -> ClosedRange<UInt64>? {
    if s.hasPrefix(">"), let n = parseBytes(String(s.dropFirst())) {
        let (lower, overflow) = n.addingReportingOverflow(1)
        guard !overflow else { return nil }
        return checkedRange(lower, UInt64.max)
    }
    if s.hasPrefix("<"), let n = parseBytes(String(s.dropFirst())) {
        let (upper, overflow) = n.subtractingReportingOverflow(1)
        guard !overflow else { return nil }
        return checkedRange(0, upper)
    }
    if let r = s.range(of: ".."), let a = parseBytes(String(s[..<r.lowerBound])), let b = parseBytes(String(s[r.upperBound...])) {
        return checkedRange(a, b)
    }
    if let n = parseBytes(s) { return checkedRange(n, n) }
    return nil
}
private func checkedRange<T: Comparable>(_ lower: T, _ upper: T) -> ClosedRange<T>? {
    guard lower <= upper else { return nil }
    return lower...upper
}
private func parseDate(_ s: String, now: Date) -> ClosedRange<UInt32>? {
    var cal = Calendar.current; cal.timeZone = .current
    let today = cal.startOfDay(for: now)
    let t = s.lowercased()
    let start: Date?, end: Date?
    switch t {
    case "today": start = today; end = cal.date(byAdding: .day, value: 1, to: today)
    case "yesterday": start = cal.date(byAdding: .day, value: -1, to: today); end = today
    case "week": start = cal.dateInterval(of: .weekOfYear, for: now)?.start; end = cal.dateInterval(of: .weekOfYear, for: now)?.end
    case "month": start = cal.dateInterval(of: .month, for: now)?.start; end = cal.dateInterval(of: .month, for: now)?.end
    case "year": start = cal.dateInterval(of: .year, for: now)?.start; end = cal.dateInterval(of: .year, for: now)?.end
    default:
        if let unit = t.last, ["h", "d", "w"].contains(unit), let n = Int(t.dropLast()), n >= 0 {
            let multiplier = unit == "h" ? 3_600 : unit == "d" ? 86_400 : 604_800
            let (seconds, overflow) = n.multipliedReportingOverflow(by: multiplier)
            guard !overflow, seconds <= 100 * 365 * 24 * 60 * 60 else { return nil }
            start = now.addingTimeInterval(TimeInterval(-seconds)); end = now.addingTimeInterval(1)
        } else if let dots = t.range(of: ".."), let a = datePart(String(t[..<dots.lowerBound])), let b = datePart(String(t[dots.upperBound...])) {
            return dateRange(a.start, b.end.addingTimeInterval(-1))
        } else if t.hasPrefix(">"), let d = datePart(String(t.dropFirst())) {
            guard let lower = wholeSeconds(d.end), lower >= 0, lower <= Int64(UInt32.max), let bound = UInt32(exactly: lower) else { return nil }
            return checkedRange(bound, UInt32.max)
        } else if t.hasPrefix("<"), let d = datePart(String(t.dropFirst())) {
            guard let start = wholeSeconds(d.start) else { return nil }
            let (upper, overflow) = start.subtractingReportingOverflow(1)
            guard !overflow, upper >= 0 else { return nil }
            return checkedRange(0, UInt32(clamping: upper))
        }
        else if let d = datePart(t) { start = d.start; end = d.end }
        else { return nil }
    }
    guard let a = start, let b = end else { return nil }
    return dateRange(a, b.addingTimeInterval(-1))
}
private func dateRange(_ start: Date, _ end: Date) -> ClosedRange<UInt32>? {
    guard start <= end else { return nil }
    return checkedRange(stamp(start), stamp(end))
}
private func stamp(_ d: Date) -> UInt32 {
    let seconds = d.timeIntervalSince1970
    guard seconds.isFinite else { return seconds.sign == .minus ? 0 : .max }
    if seconds <= 0 { return 0 }
    if seconds >= Double(UInt32.max) { return .max }
    return UInt32(seconds.rounded(.towardZero))
}
private func wholeSeconds(_ d: Date) -> Int64? {
    let seconds = d.timeIntervalSince1970
    guard seconds.isFinite else { return nil }
    return Int64(exactly: seconds.rounded(.towardZero))
}
private func datePart(_ s: String) -> (start: Date, end: Date)? {
    let rawParts = s.split(separator: "-", omittingEmptySubsequences: false)
    guard (1...3).contains(rawParts.count), rawParts.allSatisfy({ !$0.isEmpty }) else { return nil }
    let parts = rawParts.compactMap { Int($0) }
    guard parts.count == rawParts.count, parts[0] >= 1970 else { return nil }
    var c = DateComponents(); c.year = parts[0]; c.month = parts.count > 1 ? parts[1] : 1; c.day = parts.count > 2 ? parts[2] : 1
    var cal = Calendar.current; cal.timeZone = .current
    guard let d = cal.date(from: c), cal.dateComponents([.year, .month, .day], from: d) == c else { return nil }
    let unit: Calendar.Component = parts.count == 1 ? .year : parts.count == 2 ? .month : .day
    guard let end = cal.date(byAdding: unit, value: 1, to: d) else { return nil }
    return (d, end)
}
