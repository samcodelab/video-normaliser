import XCTest
@testable import FrankLuma

final class FileAccessTests: XCTestCase {
    private func directory() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }
    func testSuccessfulExportCommitsNewFile() throws {
        let destination=try directory().appendingPathComponent("output.mov")
        let staging=try ExportStaging(destination:destination)
        XCTAssertNotEqual(staging.file.deletingLastPathComponent(),destination.deletingLastPathComponent())
        try Data("new video".utf8).write(to:staging.file)
        try staging.commit(to:destination)
        XCTAssertEqual(try Data(contentsOf:destination),Data("new video".utf8))
    }
    func testSuccessfulExportReplacesExistingFile() throws {
        let destination=try directory().appendingPathComponent("output.mov")
        try Data("old video".utf8).write(to:destination)
        let staging=try ExportStaging(destination:destination)
        try Data("new video".utf8).write(to:staging.file)
        try staging.commit(to:destination)
        XCTAssertEqual(try Data(contentsOf:destination),Data("new video".utf8))
    }
    func testAbandonedExportPreservesDestinationAndRemovesStaging() throws {
        let destination=try directory().appendingPathComponent("output.mov")
        try Data("original".utf8).write(to:destination)
        var staging: ExportStaging?=try ExportStaging(destination:destination)
        let temporary=staging!.directory
        try Data("incomplete".utf8).write(to:staging!.file)
        staging=nil
        XCTAssertEqual(try Data(contentsOf:destination),Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:temporary.path))
    }
}
