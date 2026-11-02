import Foundation

public enum ToastKind { case copiedPath, copiedName, trashed }

public enum Presentation {
    public static func toastText(_ kind: ToastKind, value: String, chinese: Bool) -> String {
        let prefix: String
        switch kind {
        case .copiedPath: prefix = chinese ? "已拷贝：" : "Copied: "
        case .copiedName: prefix = chinese ? "已拷贝名称：" : "Copied name: "
        case .trashed: prefix = chinese ? "已移到废纸篓：" : "Moved to Trash: "
        }
        return prefix + value
    }

    public static func highlightRanges(name: String, query: Query) -> [NSRange] {
        var literals: [(text: String, caseSensitive: Bool)] = []
        for clause in query.clauses {
            for atom in clause.alternatives where !atom.negated {
                switch atom.matcher {
                case .name(let needle, let caseSensitive):
                    literals.append((String(decoding: needle, as: UTF8.self), caseSensitive))
                case .glob(let pattern, _):
                    literals += String(decoding: pattern, as: UTF8.self)
                        .split(whereSeparator: { $0 == "*" || $0 == "?" }).map { (String($0), false) }
                default: break
                }
            }
        }
        let text = name as NSString
        var ranges: [NSRange] = []
        for (literal, caseSensitive) in literals where !literal.isEmpty {
            var start = 0
            while start < text.length {
                let range = text.range(of: literal, options: caseSensitive ? [] : .caseInsensitive,
                                       range: NSRange(location: start, length: text.length - start))
                if range.location == NSNotFound { break }
                ranges.append(range)
                // Advancing one UTF-16 unit also finds overlapping occurrences.
                start = range.location + 1
            }
        }
        ranges.sort { $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, range.location < NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else { merged.append(range) }
        }
        return merged
    }

    public static func abbreviate(path: String, home: String) -> String {
        let base = home == "/" ? home : home.trimmingTrailingSlash
        if path == base { return "~" }
        if path.hasPrefix(base == "/" ? "/" : base + "/") {
            return "~" + (base == "/" ? "/" + path.dropFirst() : String(path.dropFirst(base.count)))
        }
        return path
    }

    public static func dateText(_ date: Date, now: Date, calendar: Calendar, chinese: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: chinese ? "zh_CN" : "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return (chinese ? "今天 " : "Today ") + formatter.string(from: date)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            formatter.dateFormat = "HH:mm"
            return (chinese ? "昨天 " : "Yesterday ") + formatter.string(from: date)
        }
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? (chinese ? "M月d日" : "MMM d") : "yyyy/M/d"
        return formatter.string(from: date)
    }

    public static func sizeText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
    public static func countText(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.secondaryGroupingSize = 3
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
    public static func elapsedText(_ ms: Double) -> String {
        String(format: ms < 10 ? "%.1f" : "%.0f", locale: Locale(identifier: "en_US_POSIX"), ms)
    }
}

private extension String {
    var trimmingTrailingSlash: String {
        var result = self
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
