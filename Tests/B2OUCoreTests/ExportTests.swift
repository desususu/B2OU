import XCTest
@testable import B2OUCore

final class ExportTests: XCTestCase {

    // MARK: - YAML Front Matter

    func testYamlEscapeSimple() {
        XCTAssertEqual(yamlEscape("hello"), "hello")
    }

    func testYamlEscapeEmpty() {
        XCTAssertEqual(yamlEscape(""), "\"\"")
    }

    func testYamlEscapeSpecialChars() {
        let result = yamlEscape("title: with colon")
        XCTAssertTrue(result.hasPrefix("\""))
        XCTAssertTrue(result.hasSuffix("\""))
    }

    func testYamlEscapeNewline() {
        let result = yamlEscape("line1\nline2")
        XCTAssertTrue(result.contains("\\n"))
    }

    // MARK: - Filename Strategies

    func testGenerateFilenameTitle() {
        let note = BearNote(title: "My Note", text: "", creationDate: 0,
                            modifiedDate: 0, uuid: "abc12345-uuid", pk: 1)
        XCTAssertEqual(generateFilename(note: note, naming: "title"), "My Note")
    }

    func testGenerateFilenameSlug() {
        let note = BearNote(title: "My Note Title!", text: "", creationDate: 0,
                            modifiedDate: 0, uuid: "abc12345-uuid", pk: 1)
        let result = generateFilename(note: note, naming: "slug")
        XCTAssertEqual(result, "my-note-title-")
    }

    func testGenerateFilenameId() {
        let note = BearNote(title: "Any Title", text: "", creationDate: 0,
                            modifiedDate: 0, uuid: "ABCDEFGH-1234", pk: 1)
        XCTAssertEqual(generateFilename(note: note, naming: "id"), "ABCDEFGH")
    }

    // MARK: - Placeholder Detection

    func testIsUntitledPlaceholderEmpty() {
        let note = BearNote(title: "", text: "", creationDate: 0,
                            modifiedDate: 0, uuid: "test", pk: 1)
        XCTAssertTrue(isUntitledPlaceholder(note))
    }

    func testIsUntitledPlaceholderWithTitle() {
        let note = BearNote(title: "Real Title", text: "Content", creationDate: 0,
                            modifiedDate: 0, uuid: "test", pk: 1)
        XCTAssertFalse(isUntitledPlaceholder(note))
    }

    func testIsUntitledPlaceholderHashOnly() {
        let note = BearNote(title: "", text: "# ", creationDate: 0,
                            modifiedDate: 0, uuid: "test", pk: 1)
        XCTAssertTrue(isUntitledPlaceholder(note))
    }

    // MARK: - Manifest

    func testManifestRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("b2ou-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let paths: Set<URL> = [
            tmp.appendingPathComponent("note1.md"),
            tmp.appendingPathComponent("sub/note2.md"),
        ]

        writeManifest(exportPath: tmp, paths: paths)
        let read = readManifest(exportPath: tmp)
        XCTAssertTrue(read.contains("note1.md"))
        XCTAssertTrue(read.contains("sub/note2.md"))
    }
}
