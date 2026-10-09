import Foundation
import Darwin

struct ToolAnswer {
    let expression: String
    let value: String
    let detail: String
}

enum WebSearchEngine: String, CaseIterable {
    case duckDuckGo, google, bing

    var title: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        }
    }

    func url(for query: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        switch self {
        case .duckDuckGo: components.host = "duckduckgo.com"; components.path = "/"
        case .google: components.host = "www.google.com"; components.path = "/search"
        case .bing: components.host = "www.bing.com"; components.path = "/search"
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // Search services decode '+' as a space in form-style query strings.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

enum LauncherTools {
    private static let maximumLength = 256

    static func evaluate(_ input: String) -> ToolAnswer? {
        // Bound the original input before allocating normalized parser storage.
        guard input.utf16.count <= maximumLength else { return nil }
        let expression = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return nil }
        let normalized = normalize(expression)
        if let conversion = convert(normalized) {
            let value = "\(format(conversion.value)) \(conversion.target.symbol)"
            return ToolAnswer(expression: expression, value: value, detail: "\(expression) = \(value)")
        }
        // Dates and version-like filenames should keep their search meaning.
        guard expression.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil else { return nil }
        var parser = ArithmeticParser(normalized)
        guard let result = parser.parse(), parser.hasSyntax else { return nil }
        let value = format(result)
        return ToolAnswer(expression: expression, value: value, detail: "\(expression) = \(value)")
    }

    static func url(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !text.contains("\\"), validPercentEscapes(text) else { return nil }
        let lower = text.lowercased()
        let explicit = lower.hasPrefix("https://") || lower.hasPrefix("http://")
        // Only a recognizable bare domain gets an implicit HTTPS scheme.
        guard explicit || !text.contains("://") else { return nil }
        guard let components = URLComponents(string: explicit ? text : "https://" + text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              let host = components.host, validHost(host, explicit: explicit),
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return components.url
    }

    static func explicitWebQuery(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.prefix(4).lowercased() == "web:" else { return nil }
        let query = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
    }

    private static func format(_ value: Double) -> String {
        if value == 0 { return "0" }
        return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func validPercentEscapes(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        for index in bytes.indices where bytes[index] == 37 {
            guard index + 2 < bytes.count,
                  bytes[index + 1].isHexDigit, bytes[index + 2].isHexDigit else { return false }
        }
        return true
    }

    private static func validHost(_ host: String, explicit: Bool) -> Bool {
        if explicit, host.hasPrefix("["), host.hasSuffix("]") {
            var address = in6_addr()
            return String(host.dropFirst().dropLast()).withCString { inet_pton(AF_INET6, $0, &address) == 1 }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, !labels.isEmpty,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
              }) else { return false }
        if explicit { return true }
        guard labels.count >= 2, let last = labels.last else { return false }
        let suffix = last.lowercased()
        // Common file extensions overlap real TLDs; require an explicit scheme for them.
        let fileExtensions: Set<String> = [
            "txt", "md", "pdf", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "tsv",
            "json", "xml", "html", "htm", "css", "js", "ts", "swift", "py", "c", "h", "cpp",
            "jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "mp3", "mp4", "mov", "wav",
            "zip", "gz", "tar", "dmg", "pkg", "app", "exe", "log", "ini", "yaml", "yml"
        ]
        guard !fileExtensions.contains(suffix) else { return false }
        return (suffix.count >= 2 && suffix.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }) ||
            (suffix.hasPrefix("xn--") && suffix.count > 4)
    }

    private enum Dimension: Equatable { case length, mass, temperature, area, volume, time, information }

    private struct Unit {
        let dimension: Dimension
        let symbol: String
        let scale: Double
        let offset: Double
    }

    private struct Conversion {
        let value: Double
        let target: Unit
    }

    private static let quantityPattern = try! NSRegularExpression(
        pattern: #"^([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)\s*(.+)$"#
    )
    private static let connectorPattern = try! NSRegularExpression(
        pattern: #"\s+(?:to|in)\s+|\s*转\s*"#, options: .caseInsensitive
    )

    private static func convert(_ text: String) -> Conversion? {
        let nsText = text as NSString
        guard let match = quantityPattern.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              let amount = Double(nsText.substring(with: match.range(at: 1))), amount.isFinite else { return nil }
        let remainder = nsText.substring(with: match.range(at: 2))
        let nsRemainder = remainder as NSString
        let connectors = connectorPattern.matches(in: remainder, range: NSRange(location: 0, length: nsRemainder.length))
        guard connectors.count == 1, let connector = connectors.first else { return nil }
        let sourceName = nsRemainder.substring(to: connector.range.location)
        let targetName = nsRemainder.substring(from: NSMaxRange(connector.range))
        guard let source = unit(sourceName), let target = unit(targetName), source.dimension == target.dimension else { return nil }
        let shifted = amount + source.offset
        let base = shifted * source.scale
        let converted = base / target.scale - target.offset
        guard shifted.isFinite, base.isFinite, converted.isFinite else { return nil }
        return Conversion(value: converted, target: target)
    }

    private static func unitKey(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .replacingOccurrences(of: "²", with: "2")
            .replacingOccurrences(of: "³", with: "3")
            .replacingOccurrences(of: "μ", with: "µ")
    }

    private static func unit(_ text: String) -> Unit? {
        let key = unitKey(text)
        return storageSymbols[key] ?? units[key.lowercased()]
    }

    private static let units: [String: Unit] = {
        var result: [String: Unit] = [:]
        func add(_ dimension: Dimension, _ symbol: String, _ scale: Double, _ aliases: [String], offset: Double = 0) {
            let unit = Unit(dimension: dimension, symbol: symbol, scale: scale, offset: offset)
            for alias in aliases { result[unitKey(alias).lowercased()] = unit }
        }
        add(.length, "m", 1, ["m", "meter", "meters", "metre", "metres", "米", "公尺"])
        add(.length, "km", 1000, ["km", "kilometer", "kilometers", "kilometre", "kilometres", "公里", "千米"])
        add(.length, "cm", 0.01, ["cm", "centimeter", "centimeters", "centimetre", "centimetres", "厘米", "公分"])
        add(.length, "mm", 0.001, ["mm", "millimeter", "millimeters", "millimetre", "millimetres", "毫米"])
        add(.length, "µm", 1e-6, ["µm", "um", "micrometer", "micrometers", "micrometre", "micrometres", "微米"])
        add(.length, "nm", 1e-9, ["nm", "nanometer", "nanometers", "nanometre", "nanometres", "纳米"])
        add(.length, "in", 0.0254, ["in", "inch", "inches", "英寸"])
        add(.length, "ft", 0.3048, ["ft", "foot", "feet", "英尺"])
        add(.length, "yd", 0.9144, ["yd", "yard", "yards", "码"])
        add(.length, "mi", 1609.344, ["mi", "mile", "miles", "英里"])
        add(.length, "nmi", 1852, ["nmi", "nautical mile", "nautical miles", "海里"])
        add(.mass, "kg", 1, ["kg", "kilogram", "kilograms", "公斤", "千克"])
        add(.mass, "g", 0.001, ["g", "gram", "grams", "克"])
        add(.mass, "mg", 1e-6, ["mg", "milligram", "milligrams", "毫克"])
        add(.mass, "µg", 1e-9, ["µg", "ug", "microgram", "micrograms", "微克"])
        add(.mass, "t", 1000, ["t", "tonne", "tonnes", "metric ton", "metric tons", "吨"])
        add(.mass, "lb", 0.45359237, ["lb", "lbs", "pound", "pounds", "磅"])
        add(.mass, "oz", 0.028349523125, ["oz", "ounce", "ounces", "盎司"])
        // Temperature uses Celsius as its affine base: (value + offset) * scale.
        add(.temperature, "°C", 1, ["c", "°c", "℃", "celsius", "摄氏度", "摄氏"])
        add(.temperature, "°F", 5.0 / 9.0, ["f", "°f", "℉", "fahrenheit", "华氏度", "华氏"], offset: -32)
        add(.temperature, "K", 1, ["k", "kelvin", "开尔文"], offset: -273.15)
        add(.area, "m²", 1, ["m2", "m^2", "sq m", "square meter", "square meters", "square metre", "square metres", "平方米"])
        add(.area, "km²", 1e6, ["km2", "km^2", "sq km", "square kilometer", "square kilometers", "平方公里", "平方千米"])
        add(.area, "cm²", 1e-4, ["cm2", "cm^2", "sq cm", "square centimeter", "square centimeters", "平方厘米"])
        add(.area, "mm²", 1e-6, ["mm2", "mm^2", "sq mm", "square millimeter", "square millimeters", "平方毫米"])
        add(.area, "in²", 0.0254 * 0.0254, ["in2", "in^2", "sq in", "square inch", "square inches", "平方英寸"])
        add(.area, "ft²", 0.3048 * 0.3048, ["ft2", "ft^2", "sq ft", "square foot", "square feet", "平方英尺"])
        add(.area, "yd²", 0.9144 * 0.9144, ["yd2", "yd^2", "sq yd", "square yard", "square yards", "平方码"])
        add(.area, "mi²", 1609.344 * 1609.344, ["mi2", "mi^2", "sq mi", "square mile", "square miles", "平方英里"])
        add(.area, "ha", 10000, ["ha", "hectare", "hectares", "公顷"])
        add(.area, "acre", 4046.8564224, ["acre", "acres", "英亩"])
        add(.volume, "L", 1, ["l", "liter", "liters", "litre", "litres", "升", "公升"])
        add(.volume, "mL", 0.001, ["ml", "milliliter", "milliliters", "millilitre", "millilitres", "毫升"])
        add(.volume, "µL", 1e-6, ["µl", "ul", "microliter", "microliters", "微升"])
        add(.volume, "m³", 1000, ["m3", "m^3", "cubic meter", "cubic meters", "cubic metre", "cubic metres", "立方米"])
        add(.volume, "cm³", 0.001, ["cm3", "cm^3", "cc", "cubic centimeter", "cubic centimeters", "立方厘米"])
        add(.volume, "ft³", 28.316846592, ["ft3", "ft^3", "cubic foot", "cubic feet", "立方英尺"])
        add(.volume, "in³", 0.016387064, ["in3", "in^3", "cubic inch", "cubic inches", "立方英寸"])
        add(.volume, "US gal", 3.785411784, ["gal", "gallon", "gallons", "us gal", "us gallon", "us gallons", "美制加仑"])
        add(.volume, "US qt", 0.946352946, ["qt", "quart", "quarts", "us qt", "美制夸脱"])
        add(.volume, "US pt", 0.473176473, ["pt", "pint", "pints", "us pt", "美制品脱"])
        add(.volume, "US fl oz", 0.0295735295625, ["fl oz", "fluid ounce", "fluid ounces", "us fl oz", "美制液体盎司"])
        add(.time, "s", 1, ["s", "sec", "second", "seconds", "秒"])
        add(.time, "ms", 0.001, ["ms", "millisecond", "milliseconds", "毫秒"])
        add(.time, "µs", 1e-6, ["µs", "us", "microsecond", "microseconds", "微秒"])
        add(.time, "ns", 1e-9, ["ns", "nanosecond", "nanoseconds", "纳秒"])
        add(.time, "min", 60, ["min", "minute", "minutes", "分钟"])
        add(.time, "h", 3600, ["h", "hr", "hrs", "hour", "hours", "小时"])
        add(.time, "d", 86400, ["d", "day", "days", "天", "日"])
        add(.time, "wk", 604800, ["wk", "week", "weeks", "周", "星期"])
        add(.information, "B", 1, ["byte", "bytes", "字节"])
        add(.information, "b", 0.125, ["bit", "bits", "比特", "位"])
        let prefixes: [(String, String, String, Double)] = [
            ("K", "kilo", "千", 1e3), ("M", "mega", "兆", 1e6), ("G", "giga", "吉", 1e9),
            ("T", "tera", "太", 1e12), ("P", "peta", "拍", 1e15), ("E", "exa", "艾", 1e18),
            ("Ki", "kibi", "", 1024), ("Mi", "mebi", "", 1048576), ("Gi", "gibi", "", 1073741824),
            ("Ti", "tebi", "", 1099511627776), ("Pi", "pebi", "", 1125899906842624),
            ("Ei", "exbi", "", 1152921504606846976)
        ]
        for (symbol, name, chinese, scale) in prefixes {
            var bytes = [name + "byte", name + "bytes"]
            var bits = [name + "bit", name + "bits"]
            if !chinese.isEmpty { bytes.append(chinese + "字节"); bits.append(chinese + "比特") }
            add(.information, symbol + "B", scale, bytes)
            add(.information, symbol + "b", scale / 8, bits)
        }
        return result
    }()

    // Symbols are deliberately case-sensitive: MB is eight times Mb.
    private static let storageSymbols: [String: Unit] = {
        var result: [String: Unit] = [
            "B": Unit(dimension: .information, symbol: "B", scale: 1, offset: 0),
            "b": Unit(dimension: .information, symbol: "b", scale: 0.125, offset: 0)
        ]
        let decimal = ["K", "M", "G", "T", "P", "E"]
        let binary = ["Ki", "Mi", "Gi", "Ti", "Pi", "Ei"]
        for index in decimal.indices {
            for (prefix, scale) in [(decimal[index], pow(1000, Double(index + 1))), (binary[index], pow(1024, Double(index + 1)))] {
                for (suffix, divisor) in [("B", 1.0), ("b", 8.0)] {
                    let symbol = prefix + suffix
                    let unit = Unit(dimension: .information, symbol: symbol, scale: scale / divisor, offset: 0)
                    result[symbol] = unit
                    if prefix == "K" { result["k" + suffix] = unit }
                }
            }
        }
        return result
    }()
}

private extension UInt8 {
    var isDigit: Bool { (48...57).contains(self) }
    var isHexDigit: Bool { isDigit || (65...70).contains(self) || (97...102).contains(self) }
}

private struct ArithmeticParser {
    private let bytes: [UInt8]
    private var position = 0
    private var operations = 0
    private(set) var hasSyntax = false
    private let maximumDepth = 32
    private let maximumOperations = 256

    init(_ input: String) { bytes = Array(input.utf8) }

    mutating func parse() -> Double? {
        guard let value = sum(depth: 0), value.isFinite else { return nil }
        skipWhitespace()
        return position == bytes.count ? value : nil
    }

    private mutating func sum(depth: Int) -> Double? {
        guard var value = product(depth: depth) else { return nil }
        while let operation = take([43, 45]) {
            guard countOperation(), let rhs = product(depth: depth) else { return nil }
            value = operation == 43 ? value + rhs : value - rhs
            guard value.isFinite else { return nil }
        }
        return value
    }

    private mutating func product(depth: Int) -> Double? {
        guard var value = unary(depth: depth) else { return nil }
        while let operation = take([42, 47]) {
            guard countOperation(), let rhs = unary(depth: depth), operation != 47 || rhs != 0 else { return nil }
            value = operation == 42 ? value * rhs : value / rhs
            guard value.isFinite else { return nil }
        }
        return value
    }

    private mutating func unary(depth: Int) -> Double? {
        guard depth <= maximumDepth else { return nil }
        if let sign = take([43, 45]) {
            guard countOperation(), let value = unary(depth: depth + 1) else { return nil }
            return sign == 45 ? -value : value
        }
        return power(depth: depth)
    }

    private mutating func power(depth: Int) -> Double? {
        guard let value = postfix(depth: depth) else { return nil }
        if take([94]) != nil {
            guard countOperation(), let exponent = unary(depth: depth + 1) else { return nil }
            let result = pow(value, exponent)
            return result.isFinite ? result : nil
        }
        return value
    }

    private mutating func postfix(depth: Int) -> Double? {
        guard var value = primary(depth: depth) else { return nil }
        while take([37]) != nil {
            guard countOperation() else { return nil }
            value /= 100
        }
        return value
    }

    private mutating func primary(depth: Int) -> Double? {
        guard depth <= maximumDepth else { return nil }
        if take([40]) != nil {
            hasSyntax = true
            guard depth < maximumDepth, let value = sum(depth: depth + 1), take([41]) != nil else { return nil }
            return value
        }
        skipWhitespace()
        let start = position
        var digits = 0
        while position < bytes.count, bytes[position].isDigit { position += 1; digits += 1 }
        if position < bytes.count, bytes[position] == 46 {
            position += 1
            while position < bytes.count, bytes[position].isDigit { position += 1; digits += 1 }
        }
        guard digits > 0 else { return nil }
        if position < bytes.count, bytes[position] == 101 || bytes[position] == 69 {
            position += 1
            if position < bytes.count, bytes[position] == 43 || bytes[position] == 45 { position += 1 }
            let exponentStart = position
            while position < bytes.count, bytes[position].isDigit { position += 1 }
            guard position > exponentStart else { return nil }
        }
        guard let value = Double(String(decoding: bytes[start..<position], as: UTF8.self)), value.isFinite else { return nil }
        return value
    }

    private mutating func take(_ choices: [UInt8]) -> UInt8? {
        skipWhitespace()
        guard position < bytes.count, choices.contains(bytes[position]) else { return nil }
        let value = bytes[position]
        position += 1
        return value
    }

    private mutating func countOperation() -> Bool {
        operations += 1
        hasSyntax = true
        return operations <= maximumOperations
    }

    private mutating func skipWhitespace() {
        while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
    }
}
