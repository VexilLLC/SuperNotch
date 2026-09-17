import XCTest
@testable import SuperNotch

final class ClipboardColorTests: XCTestCase {
    func testHexFormsNormalizeAndFormatCanonically() throws {
        let cases: [(input: String, output: String)] = [
            ("#abc", "#AABBCC"),
            (" #abcd ", "#AABBCCDD"),
            ("#12aBcD", "#12ABCD"),
            ("#12aBcD80", "#12ABCD80")
        ]

        for testCase in cases {
            let value = try XCTUnwrap(ClipboardColorValue.parse(testCase.input), "Expected \(testCase.input) to parse")
            XCTAssertEqual(value.canonicalHex, testCase.output)
            XCTAssertEqual(value.displayLabel, testCase.output)
        }
    }

    func testCommaSeparatedRGBAndRGBAForms() throws {
        let opaqueNumeric = try XCTUnwrap(ClipboardColorValue.parse("rgb(255, 127.5, 0)"))
        XCTAssertEqual(opaqueNumeric.r, 1, accuracy: 0.000_001)
        XCTAssertEqual(opaqueNumeric.g, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(opaqueNumeric.b, 0, accuracy: 0.000_001)
        XCTAssertEqual(opaqueNumeric.a, 1, accuracy: 0.000_001)
        XCTAssertEqual(opaqueNumeric.canonicalHex, "#FF8000")

        let percentage = try XCTUnwrap(ClipboardColorValue.parse("RGB(100%, 50%, 0%)"))
        XCTAssertEqual(percentage.canonicalHex, "#FF8000")

        let translucent = try XCTUnwrap(ClipboardColorValue.parse("rgba(10, 20, 30, 0.25)"))
        XCTAssertEqual(translucent.canonicalHex, "#0A141E40")

        let percentageAlpha = try XCTUnwrap(ClipboardColorValue.parse("rgba(10%, 20%, 30%, 25%)"))
        XCTAssertEqual(percentageAlpha.canonicalHex, "#1A334D40")
    }

    func testWhitespaceAroundCompleteExpressionIsAllowed() throws {
        let value = try XCTUnwrap(ClipboardColorValue.parse("\n  rgba( 1 , 2 , 3 , 100% ) \t"))
        XCTAssertEqual(value.canonicalHex, "#010203")
    }

    func testRejectsMalformedMixedAndOutOfRangeInput() {
        let invalid = [
            "",
            "hello #fff",
            "#12",
            "#12345",
            "#123456789",
            "#12GG34",
            "rgb(255, 0%, 0)",
            "rgb(255, 0, 0, 1)",
            "rgba(255, 0, 0)",
            "rgb(256, 0, 0)",
            "rgb(-1, 0, 0)",
            "rgb(0, 101%, 0%)",
            "rgba(0, 0, 0, 1.01)",
            "rgba(0, 0, 0, 101%)",
            "rgba(0, 0, 0, NaN)",
            "rgba(0, 0, 0, inf)",
            "rgba(0, 0, 0, 1e309)",
            "rgb(0 0 0)",
            "rgb(0, 0, 0) trailing",
            "prefix rgba(0, 0, 0, 1)",
            "rgb(0,,0)",
            "rgb(0, 0, 0,)",
            "rgb(0, 0, 0)()"
        ]

        for input in invalid {
            XCTAssertNil(ClipboardColorValue.parse(input), "Expected \(input) to be rejected")
        }
    }

    func testRejectsUnboundedClipboardText() {
        let oversized = String(repeating: " ", count: 257) + "#fff"
        XCTAssertNil(ClipboardColorValue.parse(oversized))
    }

    func testEquatableValuesUseNormalizedComponents() throws {
        let shorthand = try XCTUnwrap(ClipboardColorValue.parse("#0f08"))
        let expanded = try XCTUnwrap(ClipboardColorValue.parse("#00ff0088"))
        XCTAssertEqual(shorthand, expanded)

        let clamped = ClipboardColorValue(r: -1, g: 0.5, b: 2, a: .infinity)
        XCTAssertEqual(clamped, ClipboardColorValue(r: 0, g: 0.5, b: 1, a: 0))
    }
}
