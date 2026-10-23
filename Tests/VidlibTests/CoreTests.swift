import XCTest

@testable import Vidlib

final class CoreTests: XCTestCase {
  private let identity = """
    # Standard red-fastest cube ordering
    TITLE "Identity"
    LUT_3D_SIZE 2
    DOMAIN_MIN 0 0 0
    DOMAIN_MAX 1 1 1
    0 0 0
    1 0 0
    0 1 0
    1 1 0
    0 0 1
    1 0 1
    0 1 1
    1 1 1
    """

  func testCubePreservesColorOrderAndAlpha() throws {
    let lut = try CubeLUT(contents: identity)
    XCTAssertEqual(lut.dimension, 2)
    let values = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    XCTAssertEqual(Array(values[4..<8]), [1, 0, 0, 1])
    XCTAssertEqual(Array(values[16..<20]), [0, 0, 1, 1])
  }

  func testRejectsTruncatedAndNonFiniteLUTs() {
    XCTAssertThrowsError(
      try CubeLUT(
        contents: identity.components(separatedBy: .newlines).dropLast().joined(separator: "\n")))
    XCTAssertThrowsError(
      try CubeLUT(contents: identity.replacingOccurrences(of: "1 0 0", with: "nan 0 0")))
  }

  func testRejectsUnsupportedDomainInsteadOfShowingWrongColors() {
    XCTAssertThrowsError(
      try CubeLUT(
        contents: identity.replacingOccurrences(of: "DOMAIN_MAX 1 1 1", with: "DOMAIN_MAX 2 2 2")))
  }

  func testCatalogRoundTripDoesNotTouchOriginal() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let media = temporary.appendingPathComponent("original.mp4")
    let original = Data("unchanged source".utf8)
    try original.write(to: media)
    let root = SourceFolder(url: temporary)
    var clip = Clip(url: media, rootID: root.id)
    clip.tags = ["Travel", "Family"]
    clip.dateSource = "File creation date (fallback)"
    let collection = ClipCollection(name: "Trip", clipIDs: [clip.id])
    let db = try CatalogStore(url: temporary.appendingPathComponent("catalog.sqlite"))
    try db.save(CatalogSnapshot(clips: [clip], roots: [root], collections: [collection]))
    let restored = try db.load()
    XCTAssertEqual(restored.clips, [clip])
    XCTAssertEqual(restored.collections.first?.clipIDs, [clip.id])
    XCTAssertEqual(try Data(contentsOf: media), original)
  }

  @MainActor
  func testPathOverlapUsesDirectoryBoundaries() {
    XCTAssertTrue(
      LibraryModel.overlaps(
        URL(fileURLWithPath: "/tmp/footage"), URL(fileURLWithPath: "/tmp/footage/cache")))
    XCTAssertFalse(
      LibraryModel.overlaps(
        URL(fileURLWithPath: "/tmp/footage"), URL(fileURLWithPath: "/tmp/footage-other")))
  }
}
