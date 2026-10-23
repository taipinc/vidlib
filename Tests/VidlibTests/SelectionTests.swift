import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import Vidlib

final class SelectionTests: XCTestCase {
  func testNativeStringDragFallbackRoundTripsAndRejectsUnrelatedText() {
    let payload = ClipDragPayload(ids: [UUID(), UUID()])
    XCTAssertEqual(ClipDragPayload(pasteboardString: payload.pasteboardString)?.ids, payload.ids)
    XCTAssertNil(ClipDragPayload(pasteboardString: "unrelated text"))
    XCTAssertNil(ClipDragPayload(pasteboardString: "vidlib-clips:invalid"))
    XCTAssertNil(ClipDragPayload(pasteboardString: ClipDragPayload(ids: []).pasteboardString))
  }
  func testDragPayloadSurvivesNativeItemProviderTransport() async throws {
    let payload = ClipDragPayload(ids: [UUID(), UUID()])
    let encoded = try JSONEncoder().encode(payload)
    let provider = NSItemProvider(
      item: encoded as NSData, typeIdentifier: UTType.vidlibClips.identifier)
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: UTType.vidlibClips.identifier) {
        data, error in
        if let data {
          continuation.resume(returning: data)
        } else {
          continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
        }
      }
    }
    XCTAssertEqual(try JSONDecoder().decode(ClipDragPayload.self, from: data).ids, payload.ids)
  }

  func testShiftRangeFollowsDisplayOrderAndKeepsAnchor() {
    let ids = (0..<6).map { _ in UUID() }
    var selection = ClipSelection()
    selection.select(ids[1], orderedIDs: ids)
    selection.select(ids[4], orderedIDs: ids, extending: true)
    XCTAssertEqual(selection.ids, Set(ids[1...4]))
    selection.select(ids[2], orderedIDs: ids, extending: true)
    XCTAssertEqual(selection.ids, Set(ids[1...2]))
    selection.select(ids[0], orderedIDs: ids, extending: true)
    XCTAssertEqual(selection.ids, Set(ids[0...1]))
  }

  func testCommandToggleAndAdditiveShiftRange() {
    let ids = (0..<6).map { _ in UUID() }
    var selection = ClipSelection()
    selection.select(ids[0], orderedIDs: ids)
    selection.select(ids[3], orderedIDs: ids, toggling: true)
    selection.select(ids[5], orderedIDs: ids, extending: true, toggling: true)
    XCTAssertEqual(selection.ids, [ids[0], ids[3], ids[4], ids[5]])
    selection.select(ids[5], orderedIDs: ids, toggling: true)
    XCTAssertFalse(selection.ids.contains(ids[5]))
    XCTAssertNotNil(selection.focusedID)
  }

  func testFilteringOrChangingCollectionClearsHiddenSelections() {
    let ids = (0..<3).map { _ in UUID() }
    var selection = ClipSelection()
    selection.select(ids[0], orderedIDs: ids)
    selection.select(ids[2], orderedIDs: ids, extending: true)
    selection.retain(visibleIDs: [ids[1]])
    XCTAssertEqual(selection.ids, [ids[1]])
    XCTAssertEqual(selection.focusedID, ids[1])
    selection.retain(visibleIDs: [])
    XCTAssertTrue(selection.ids.isEmpty)
    XCTAssertNil(selection.focusedID)
  }

  @MainActor
  func testBatchEditsAndDropsOnlyAffectSelectedCatalogEntries() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let dbURL = directory.appendingPathComponent("catalog.sqlite")
    let model = LibraryModel(
      catalogURL: dbURL, cacheDirectory: directory.appendingPathComponent("Cache"))
    let root = SourceFolder(url: directory.appendingPathComponent("Footage"))
    var clips = (0..<3).map {
      Clip(url: root.url.appendingPathComponent("\($0).mp4"), rootID: root.id)
    }
    clips[0].tags = ["Original"]
    let collection = ClipCollection(name: "Batch")
    let lut = LUTReference(name: "Test", fileName: "unused.cube")
    model.catalog = CatalogSnapshot(
      clips: clips, roots: [root], collections: [collection], luts: [lut])
    model.gridSelection = ClipSelection(
      ids: [clips[0].id, clips[1].id], focusedID: clips[0].id, anchorID: clips[0].id)
    model.setTags("New, Original, new")
    model.setLUT(lut.id)
    model.addSelected(to: collection.id)
    XCTAssertEqual(model.catalog.clips[0].tags, ["Original", "New"])
    XCTAssertEqual(model.catalog.clips[1].tags, ["New", "Original"])
    XCTAssertEqual(model.catalog.clips[2], clips[2])
    XCTAssertEqual(model.catalog.clips[0].lutID, lut.id)
    XCTAssertEqual(model.catalog.clips[1].lutID, lut.id)
    XCTAssertEqual(model.catalog.collections[0].clipIDs, [clips[0].id, clips[1].id])
    XCTAssertEqual(Set(model.dragPayload(for: clips[0]).ids), model.selectedIDs)
    XCTAssertEqual(model.dragPayload(for: clips[2]).ids, [clips[2].id])
    XCTAssertFalse(model.addClips([UUID()], to: collection.id))
    XCTAssertTrue(model.addClips([clips[2].id, UUID()], to: collection.id))
    XCTAssertEqual(model.catalog.collections[0].clipIDs.count, 3)
    let restored = try CatalogStore(url: dbURL).load()
    XCTAssertEqual(restored.clips[0].lutID, lut.id)
    XCTAssertEqual(restored.clips[2], clips[2])
    model.selection = .collection(UUID())
    XCTAssertTrue(model.selectedIDs.isEmpty)
    XCTAssertNil(model.selectedClip)
  }
}
