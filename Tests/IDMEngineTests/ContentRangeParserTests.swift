import XCTest

@testable import IDMEngine

final class ContentRangeParserTests: XCTestCase {
    func testParsingRejectsInvalidRanges() {
        XCTAssertEqual(
            ContentRangeParser.parse("bytes 0-0/100"),
            ParsedContentRange(start: 0, endInclusive: 0, total: 100)
        )
        XCTAssertNil(ContentRangeParser.parse("bytes 5-4/100"))
        XCTAssertNil(ContentRangeParser.parse("bytes 0-100/100"))
        XCTAssertNil(ContentRangeParser.parse("bytes 0-0/*"))
        XCTAssertNil(ContentRangeParser.parse("items 0-0/100"))
    }
}
