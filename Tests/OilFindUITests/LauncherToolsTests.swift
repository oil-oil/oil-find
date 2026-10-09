import Foundation
import XCTest
@testable import OilFind

final class LauncherToolsTests: XCTestCase {
    private func assertValue(_ input: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(LauncherTools.evaluate(input)?.value, expected, input, file: file, line: line)
    }

    private func assertConversion(_ input: String, _ expected: Double, _ symbol: String,
                                  accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) throws {
        let answer = try XCTUnwrap(LauncherTools.evaluate(input), input, file: file, line: line)
        let suffix = " " + symbol
        XCTAssertTrue(answer.value.hasSuffix(suffix), answer.value, file: file, line: line)
        let number = try XCTUnwrap(Double(answer.value.dropLast(suffix.count)), answer.value, file: file, line: line)
        XCTAssertEqual(number, expected, accuracy: accuracy, input, file: file, line: line)
    }

    func testArithmeticPrecedenceAssociativityAndUnary() {
        assertValue("150*20%", "30")
        assertValue("5/2", "2.5")
        assertValue("2+3*4", "14")
        assertValue("(2+3)*4", "20")
        assertValue("2^3^2", "512")
        assertValue("-2^2", "-4")
        assertValue("(-2)^2", "4")
        assertValue("2^-3", "0.125")
        assertValue("-5+-2", "-7")
        assertValue("8/4/2", "1")
        assertValue("10-3-2", "5")
        assertValue("200*(10+5)%", "30")
        assertValue("50%%", "0.005")
        assertValue("−3 × (2 + 4) ÷ 2", "-9")
        assertValue(".5 + 1.25", "1.75")
        assertValue("1e3*2", "2000")
        assertValue("-0", "0")
        let answer = LauncherTools.evaluate("  5 / 2  ")
        XCTAssertEqual(answer?.expression, "5 / 2")
        XCTAssertEqual(answer?.detail, "5 / 2 = 2.5")
    }

    func testIncompleteInvalidAndNonFiniteArithmeticIsRejected() {
        for input in ["", " ", "2+", "(2+3", "2+3)", "2**3", "2 3", "2(3)", "2+3junk", "1e+*2",
                      "1/0", "0/0", "1/-0", "10^1000", "1e309+1", "(-1)^0.5", "1e308*10/10",
                      "sqrt(4)", "NaN+1", "infinity", "150*20%=30", "1; print(1)"] {
            XCTAssertNil(LauncherTools.evaluate(input), input)
        }
    }

    func testLengthAndRecursiveLimits() {
        assertValue(String(repeating: "(", count: 32) + "1" + String(repeating: ")", count: 32), "1")
        XCTAssertNil(LauncherTools.evaluate(String(repeating: "(", count: 33) + "1" + String(repeating: ")", count: 33)))
        assertValue(String(repeating: "-", count: 32) + "1", "1")
        XCTAssertNil(LauncherTools.evaluate(String(repeating: "-", count: 33) + "1"))
        assertValue(String(repeating: "1+", count: 127) + "1", "128")
        assertValue("1+1" + String(repeating: " ", count: 253), "2")
        XCTAssertNil(LauncherTools.evaluate("1+1" + String(repeating: " ", count: 254)))
        XCTAssertNil(LauncherTools.evaluate(String(repeating: "1+", count: 256) + "1"))
        assertValue("1" + String(repeating: "^1", count: 32), "1")
        XCTAssertNil(LauncherTools.evaluate("1" + String(repeating: "^1", count: 33)))
    }

    func testEnglishChineseLengthAndMassAliases() throws {
        try assertConversion("10 km to mi", 10_000 / 1609.344, "mi")
        try assertConversion("10公里转英里", 10_000 / 1609.344, "mi")
        try assertConversion("10 kilometers TO miles", 10_000 / 1609.344, "mi")
        try assertConversion("12 in in cm", 30.48, "cm")
        try assertConversion("1 英尺 转 厘米", 30.48, "cm")
        try assertConversion("1 kg to g", 1000, "g")
        try assertConversion("1磅转克", 453.59237, "g")
        try assertConversion("1 µm to nm", 1000, "nm")
        try assertConversion("1e3 mg to g", 1, "g")
        try assertConversion("−2kg to g", -2000, "g")
    }

    func testAffineTemperaturesIncludingZeroAndNegatives() throws {
        assertValue("32°F 转 °C", "0 °C")
        try assertConversion("0°C to °F", 32, "°F")
        try assertConversion("-40华氏度转摄氏度", -40, "°C")
        try assertConversion("273.15 K to Celsius", 0, "°C")
        try assertConversion("100℃转℉", 212, "°F")
        try assertConversion("32°F to K", 273.15, "K")
    }

    func testAreaVolumeAndTimeStayInTheirDimensions() throws {
        try assertConversion("2平方公里转平方米", 2_000_000, "m²")
        try assertConversion("1 m² to cm2", 10000, "cm²")
        try assertConversion("1 square foot to square meters", 0.09290304, "m²")
        try assertConversion("1 acre to ha", 0.40468564224, "ha")
        try assertConversion("1 m³ to L", 1000, "L")
        try assertConversion("500毫升转升", 0.5, "L")
        try assertConversion("1 gallon to L", 3.785411784, "L")
        try assertConversion("1 fluid ounce to mL", 29.5735295625, "mL")
        try assertConversion("1 cm^3 to mL", 1, "mL")
        try assertConversion("2小时转分钟", 120, "min")
        try assertConversion("1 week in days", 7, "d")
        try assertConversion("1 ms to µs", 1000, "µs")
    }

    func testStorageUsesSIAndIECFactorsAndCaseSensitiveSymbols() throws {
        assertValue("1 KB to B", "1000 B")
        assertValue("1 KiB to B", "1024 B")
        assertValue("1 kB to B", "1000 B")
        assertValue("1 MB to Mb", "8 Mb")
        assertValue("8 b to B", "1 B")
        assertValue("1 MiB to KiB", "1024 KiB")
        assertValue("1 megabyte to kilobytes", "1000 KB")
        assertValue("1兆字节转字节", "1000000 B")
        try assertConversion("1 GB to GiB", 1e9 / 1073741824, "GiB")
        XCTAssertNil(LauncherTools.evaluate("1 mb to B"))
    }

    func testUnsupportedPartialAndDimensionallyInvalidConversions() {
        for input in ["10 km to", "km to mi", "10 km", "10 km to mi extra", "10 km to mi to m",
                      "10 km to kg", "10 m to m²", "1 L to kg", "1 oz to mL", "1 USD to EUR",
                      "10美元转人民币", "1 month to days", "1 MB to m", "1e309 km to m", "1e308 km to m",
                      "10 unknown to m", "10km tomi", "10 km into mi", "(2+3) km to m"] {
            XCTAssertNil(LauncherTools.evaluate(input), input)
        }
    }

    func testOrdinaryQueriesAndAmbiguousFilenamesRemainSearches() {
        for input in ["report.pdf", "2026", "123", "1.2", "2026-10-08", "1.2.3", "2026-10-08.txt",
                      "notes-2.md", "photo (2).jpg", "~/Documents/2", "*.swift", "meeting notes",
                      "10 km to mi.txt", "web: 5/2", "https://example.com"] {
            XCTAssertNil(LauncherTools.evaluate(input), input)
        }
    }

    func testURLsOnlyRecognizeExplicitHTTPOrClearDomains() throws {
        XCTAssertEqual(LauncherTools.url("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(LauncherTools.url("  https://example.com/path?q=hello%20world#part  ")?.scheme, "https")
        XCTAssertEqual(LauncherTools.url("http://localhost:8080/test")?.host, "localhost")
        XCTAssertEqual(LauncherTools.url("http://127.0.0.1:8080")?.port, 8080)
        XCTAssertNotNil(LauncherTools.url("http://[::1]:8080/"))
        XCTAssertNotNil(LauncherTools.url("HTTPS://EXAMPLE.COM"))
        XCTAssertNotNil(LauncherTools.url("docs.example.org/path?q=1&sort=asc"))
        XCTAssertNotNil(LauncherTools.url("https://report.pdf"))
        for input in ["", "file:///tmp/test", "javascript:alert(1)", "mailto:a@example.com", "ftp://example.com",
                      "oilfind://open", "https:example.com", "https://", "https:///example.com", "//example.com",
                      "https://user:password@example.com", "user@example.com", "https://example.com:0",
                      "https://example.com:65536", "https://example.com/%xx", "https://example.com/%",
                      "https://example.com/hello world", "https://example.com\\@evil.com", "https://bad..com",
                      "-bad.com", "example-.com", "example.com.", "http://[xyz]/", "localhost", "127.0.0.1",
                      "report.pdf", "README.md", "main.swift", "file.app", "meeting notes", "web: example.com"] {
            XCTAssertNil(LauncherTools.url(input), input)
        }
    }

    func testExplicitWebPrefixAndQueryEncodingForEveryEngine() throws {
        XCTAssertEqual(LauncherTools.explicitWebQuery("  web: 猫 & dogs + 10% #tag?  "), "猫 & dogs + 10% #tag?")
        XCTAssertEqual(LauncherTools.explicitWebQuery("WEB:oil find"), "oil find")
        for input in ["web:", "web:   ", "website", "search cats", "cats web: dogs"] {
            XCTAssertNil(LauncherTools.explicitWebQuery(input), input)
        }
        let query = "猫 & dogs + 10% #tag? a=b / coffee ☕"
        let hosts = ["duckduckgo.com", "www.google.com", "www.bing.com"]
        XCTAssertEqual(WebSearchEngine.allCases.map(\.rawValue), ["duckDuckGo", "google", "bing"])
        XCTAssertEqual(WebSearchEngine.allCases.map(\.title), ["DuckDuckGo", "Google", "Bing"])
        for (engine, host) in zip(WebSearchEngine.allCases, hosts) {
            let url = engine.url(for: query)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "https")
            XCTAssertEqual(components.host, host)
            XCTAssertNil(components.fragment)
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: query)])
            XCTAssertTrue(components.percentEncodedQuery?.contains("%2B") == true)
            XCTAssertFalse(components.percentEncodedQuery?.contains("+") == true)
        }
    }
}
