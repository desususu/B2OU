import XCTest
@testable import B2OUCore

final class ConfigTests: XCTestCase {

    func testDefaultConfig() {
        let cfg = ExportConfig(exportPath: URL(fileURLWithPath: "/tmp/test"))
        XCTAssertEqual(cfg.exportFormat, "md")
        XCTAssertEqual(cfg.naming, "title")
        XCTAssertEqual(cfg.onDelete, "trash")
        XCTAssertFalse(cfg.makeTagFolders)
        XCTAssertFalse(cfg.yamlFrontMatter)
        XCTAssertFalse(cfg.hideTags)
        XCTAssertTrue(cfg.multiTagFolders)
    }

    func testDerivedFlags() {
        var cfg = ExportConfig(exportPath: URL(fileURLWithPath: "/tmp/test"), exportFormat: "md")
        XCTAssertTrue(cfg.exportImageRepository)
        XCTAssertFalse(cfg.exportAsTextbundles)

        cfg.exportFormat = "tb"
        XCTAssertTrue(cfg.exportAsTextbundles)
        XCTAssertFalse(cfg.exportImageRepository)
    }

    func testSplitExportConfigsBothFormat() throws {
        let cfg = ExportConfig(
            exportPath: URL(fileURLWithPath: "/tmp/md"),
            exportPathTB: URL(fileURLWithPath: "/tmp/tb"),
            exportFormat: "both"
        )
        let configs = try cfg.splitExportConfigs()
        XCTAssertEqual(configs.count, 2)
        XCTAssertEqual(configs[0].exportFormat, "md")
        XCTAssertEqual(configs[1].exportFormat, "tb")
    }

    func testSplitExportConfigsMissingTBPath() {
        let cfg = ExportConfig(
            exportPath: URL(fileURLWithPath: "/tmp/md"),
            exportFormat: "both"
        )
        XCTAssertThrowsError(try cfg.splitExportConfigs())
    }

    func testSplitExportConfigsSamePath() {
        let cfg = ExportConfig(
            exportPath: URL(fileURLWithPath: "/tmp/same"),
            exportPathTB: URL(fileURLWithPath: "/tmp/same"),
            exportFormat: "both"
        )
        XCTAssertThrowsError(try cfg.splitExportConfigs())
    }

    func testAssetsPathDefault() {
        let cfg = ExportConfig(exportPath: URL(fileURLWithPath: "/tmp/test"))
        XCTAssertEqual(cfg.assetsPath?.lastPathComponent, "BearImages")
    }
}
