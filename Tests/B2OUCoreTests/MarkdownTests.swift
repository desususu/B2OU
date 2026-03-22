import XCTest
@testable import B2OUCore

final class MarkdownTests: XCTestCase {

    // MARK: - cleanTitle

    func testCleanTitleBasic() {
        XCTAssertEqual(cleanTitle("My Note Title"), "My Note Title")
    }

    func testCleanTitleReplacesInvalidChars() {
        XCTAssertEqual(cleanTitle("path/to:file\\name"), "path-to-file-name")
    }

    func testCleanTitleTrimsTrailingDash() {
        XCTAssertEqual(cleanTitle("title-"), "title")
    }

    func testCleanTitleEmpty() {
        XCTAssertEqual(cleanTitle(""), "Untitled")
    }

    func testCleanTitleTruncatesLongUTF8() {
        let longTitle = String(repeating: "a", count: 300)
        let result = cleanTitle(longTitle)
        XCTAssertLessThanOrEqual(result.utf8.count, 240)
    }

    // MARK: - Bear Highlight

    func testBearHighlightToMd() {
        XCTAssertEqual(bearHighlightToMd("text ::highlighted:: text"), "text ==highlighted== text")
    }

    func testBearHighlightNoFalsePositive() {
        XCTAssertEqual(bearHighlightToMd("text :::not::: text"), "text :::not::: text")
    }

    // MARK: - Tag Extraction

    func testExtractTagsBasic() {
        let tags = extractTags("Hello #world #nested/tag text")
        XCTAssertTrue(tags.contains("world"))
        XCTAssertTrue(tags.contains("nested/tag"))
    }

    func testExtractTagsMultiWord() {
        let tags = extractTags("Hello #multi word tag# text")
        XCTAssertTrue(tags.contains("multi word tag"))
    }

    // MARK: - HTML Img to Markdown

    func testHtmlImgToMarkdown() {
        let input = #"<img src="photo.jpg" alt="My Photo">"#
        let result = htmlImgToMarkdown(input)
        XCTAssertEqual(result, "![My Photo](photo.jpg)")
    }

    func testHtmlImgWithoutAlt() {
        let input = #"<img src="photo.jpg">"#
        let result = htmlImgToMarkdown(input)
        XCTAssertEqual(result, "![image](photo.jpg)")
    }

    // MARK: - Normalize Local Image Ref

    func testNormalizeLocalImageRefBasic() {
        XCTAssertEqual(normalizeLocalImageRef("photo.jpg"), "photo.jpg")
    }

    func testNormalizeLocalImageRefFileURL() {
        XCTAssertEqual(normalizeLocalImageRef("file:///path/to/photo.jpg"), "/path/to/photo.jpg")
    }

    func testNormalizeLocalImageRefNil() {
        XCTAssertEqual(normalizeLocalImageRef(nil), "")
    }

    func testNormalizeLocalImageRefURLEncoded() {
        XCTAssertEqual(normalizeLocalImageRef("photo%20name.jpg"), "photo name.jpg")
    }

    // MARK: - First Heading

    func testFirstHeading() {
        XCTAssertEqual(firstHeading("# My Title\nSome text"), "My Title")
    }

    func testFirstHeadingNoPrefix() {
        XCTAssertEqual(firstHeading("Plain text\nMore text"), "Plain text")
    }
}
