import XCTest

@testable import Vidlib

final class LibraryManagementTests: XCTestCase {
  @MainActor
  func testMediaFiltersPreserveSearchAndClearHiddenSelection() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = LibraryModel(
      catalogURL: directory.appendingPathComponent("catalog.sqlite"),
      cacheDirectory: directory.appendingPathComponent("Cache"))
    let root = SourceFolder(url: directory)
    var video = Clip(url: directory.appendingPathComponent("video.mp4"), rootID: root.id)
    var audio = Clip(url: directory.appendingPathComponent("audio.wav"), rootID: root.id)
    video.title = "Forest camera"
    audio.title = "Forest sound"
    model.catalog = CatalogSnapshot(clips: [video, audio], roots: [root])
    model.search = "forest"
    model.selection = .video
    XCTAssertEqual(model.visibleClips.map(\.id), [video.id])
    XCTAssertEqual(model.selectionTitle, "Video")
    model.gridSelection = ClipSelection(ids: [video.id], focusedID: video.id)
    model.selection = .audio
    XCTAssertEqual(model.visibleClips.map(\.id), [audio.id])
    XCTAssertEqual(model.selectionTitle, "Audio")
    XCTAssertTrue(model.selectedIDs.isEmpty)
    XCTAssertNil(model.selectedClip)
    model.search = "camera"
    XCTAssertTrue(model.visibleClips.isEmpty)
    model.selection = .all
    XCTAssertEqual(model.visibleClips.map(\.id), [video.id])
  }

  @MainActor
  func testFolderRemovalCleansMembershipAndPreservesOriginalsAndSeparateRoots() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("catalog.sqlite")
    let model = LibraryModel(
      catalogURL: database, cacheDirectory: directory.appendingPathComponent("Cache"))
    let parent = SourceFolder(url: directory.appendingPathComponent("Media"))
    let child = SourceFolder(url: parent.url.appendingPathComponent("Separate"))
    let other = SourceFolder(url: directory.appendingPathComponent("Other"))
    let clips = [
      Clip(url: parent.url.appendingPathComponent("one.mp4"), rootID: parent.id),
      Clip(url: parent.url.appendingPathComponent("Nested/two.mp4"), rootID: parent.id),
      Clip(url: child.url.appendingPathComponent("sound.wav"), rootID: child.id),
      Clip(url: other.url.appendingPathComponent("three.mp4"), rootID: other.id),
    ]
    let original = Data("unchanged media contents".utf8)
    for clip in clips {
      try FileManager.default.createDirectory(
        at: clip.url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try original.write(to: clip.url)
    }
    let collection = ClipCollection(name: "Mixed", clipIDs: Set(clips.map(\.id)))
    model.catalog = CatalogSnapshot(
      clips: clips, roots: [parent, child, other], collections: [collection])
    model.save()
    model.selection = .folder(parent.url.path)
    model.gridSelection = ClipSelection(ids: [clips[0].id], focusedID: clips[0].id)
    model.importing = true
    XCTAssertFalse(model.removeSourceFolder(id: parent.id))
    XCTAssertEqual(model.catalog.clips.count, 4)
    model.importing = false
    XCTAssertTrue(model.removeSourceFolder(id: parent.id))
    XCTAssertEqual(model.catalog.roots.map(\.id), [child.id, other.id])
    XCTAssertEqual(model.catalog.clips, Array(clips[2...3]))
    XCTAssertEqual(model.catalog.collections[0].clipIDs, [clips[2].id, clips[3].id])
    XCTAssertEqual(model.selection, .all)
    XCTAssertTrue(model.selectedIDs.isEmpty)
    XCTAssertFalse(model.removeSourceFolder(id: parent.id))
    let restored = try CatalogStore(url: database).load()
    XCTAssertEqual(restored.clips, Array(clips[2...3]))
    XCTAssertEqual(restored.roots.map(\.id), [child.id, other.id])
    for clip in clips { XCTAssertEqual(try Data(contentsOf: clip.url), original) }
  }
}
