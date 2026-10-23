import AVFoundation
import XCTest

@testable import Vidlib

private actor ProxyScannedClips {
  var clips: [Clip] = []
  func add(_ clip: Clip) { clips.append(clip) }
}

final class ProxyTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture, deliberately not playable video".utf8).write(to: url)
  }

  func testNestedDiscoveryExclusionAmbiguityAndSourcePreservation() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = SourceFolder(url: dir)
    let original = dir.appendingPathComponent("Year/Day/Camera/Clip.MP4")
    let proxy = dir.appendingPathComponent("Year/Day/Camera/Proxy/Clip.mov")
    let other = dir.appendingPathComponent("Another/Clip.mp4")
    try write(original)
    try write(proxy)
    try write(other)
    try write(proxy.deletingLastPathComponent().appendingPathComponent("Nested/Hidden.wav"))
    let before = try Data(contentsOf: original)
    let proxyBefore = try Data(contentsOf: proxy)
    let scanner = MediaScanner()
    let found = ProxyScannedClips()
    try await scanner.scan(root: root, known: []) { await found.add($0) }
    let clips = await found.clips
    XCTAssertEqual(Set(clips.map(\.url)), [original, other])
    let clip = try XCTUnwrap(clips.first { $0.url == original })
    let discovery = ProxyDiscovery()
    let matches = try await discovery.discover(clips)
    XCTAssertEqual(matches[clip.id]?.url, proxy)
    XCTAssertNil(matches[clips.first { $0.url == other }!.id]?.url)
    try write(proxy.deletingPathExtension().appendingPathExtension("mp4"))
    let ambiguous = try await discovery.discover([clip])[clip.id]
    XCTAssertNil(ambiguous?.url)
    XCTAssertTrue(ambiguous?.issue?.contains("Ambiguous") == true)
    try FileManager.default.removeItem(
      at: proxy.deletingPathExtension().appendingPathExtension("mp4"))
    try write(original.deletingPathExtension().appendingPathExtension("mov"))
    let duplicateOriginal = try await discovery.discover([clip])[clip.id]
    XCTAssertNil(duplicateOriginal?.url)
    XCTAssertTrue(duplicateOriginal?.issue?.contains("Ambiguous") == true)
    XCTAssertEqual(try Data(contentsOf: original), before)
    XCTAssertEqual(try Data(contentsOf: proxy), proxyBefore)
  }

  func testMissingOriginalDoesNotBorrowAnotherOriginalsProxy() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let missing = Clip(url: dir.appendingPathComponent("Shot.mp4"), rootID: UUID())
    try write(dir.appendingPathComponent("Shot.mov"))
    try write(dir.appendingPathComponent("Proxy/Shot.mov"))
    let match = try await ProxyDiscovery().discover([missing])[missing.id]
    XCTAssertNil(match?.url)
    XCTAssertTrue(match?.issue?.contains("Ambiguous") == true)
  }

  @MainActor
  func testRefreshFindsAddedAndRemovedProxiesAndPreservesCanonicalEdits() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = SourceFolder(url: dir.appendingPathComponent("Media"))
    var clip = Clip(url: root.url.appendingPathComponent("Nested/Shot.mp4"), rootID: root.id)
    clip.title = "My title"
    clip.notes = "My description"
    clip.tags = ["Keep"]
    clip.lutID = UUID()
    clip.width = 3840
    clip.height = 2160
    clip.duration = 123
    try write(clip.url)
    let model = LibraryModel(
      catalogURL: dir.appendingPathComponent("Catalog/catalog.sqlite"),
      cacheDirectory: dir.appendingPathComponent("Cache"))
    let collection = ClipCollection(name: "Keep", clipIDs: [clip.id])
    model.catalog = CatalogSnapshot(clips: [clip], roots: [root], collections: [collection])
    await model.refreshProxies()
    XCTAssertEqual(model.catalog.clips, [clip])
    let proxy = clip.url.deletingLastPathComponent().appendingPathComponent("Proxy/Shot.mov")
    try write(proxy)
    // Exercise the real Refresh entry point, including exclusion of new proxy media.
    model.rescan()
    for _ in 0..<200 where model.importing { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertFalse(model.importing)
    XCTAssertEqual(model.catalog.clips.count, 1)
    XCTAssertEqual(model.catalog.clips[0].proxyURL, proxy)
    var expected = clip
    expected.proxyURL = proxy
    XCTAssertEqual(model.catalog.clips, [expected])
    XCTAssertEqual(model.catalog.collections[0].clipIDs, [clip.id])
    let restored = try CatalogStore(url: dir.appendingPathComponent("Catalog/catalog.sqlite"))
      .load()
    XCTAssertEqual(restored.clips, [expected])
    try FileManager.default.removeItem(at: proxy)
    model.rescan()
    for _ in 0..<200 where model.importing { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertFalse(model.importing)
    XCTAssertEqual(model.catalog.clips, [clip])
  }

  @MainActor
  func testRefreshSummaryCountsAdditionsAndProxiesAndClearsOnInteraction() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = SourceFolder(url: dir.appendingPathComponent("Media"))
    try write(root.url.appendingPathComponent("Shot.mp4"))
    try write(root.url.appendingPathComponent("Sound.wav"))
    try write(root.url.appendingPathComponent("Proxy/Shot.mov"))
    let model = LibraryModel(
      catalogURL: dir.appendingPathComponent("Catalog/catalog.sqlite"),
      cacheDirectory: dir.appendingPathComponent("Cache"))
    model.catalog = CatalogSnapshot(roots: [root])
    model.rescan()
    model.dismissImportSummary()
    XCTAssertTrue(model.importing)
    XCTAssertEqual(model.importStatus, "Checking folders…")
    for _ in 0..<200 where model.importing { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertFalse(model.importing)
    XCTAssertEqual(model.importSummary, "Found 1 proxy · 1 new video · 1 new audio file")
    await Task.yield()
    XCTAssertNotNil(model.importSummary)
    model.rescan()
    XCTAssertNil(model.importSummary)
    for _ in 0..<200 where model.importing { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertFalse(model.importing)
    XCTAssertEqual(model.importSummary, "Found 1 proxy")
    model.selection = .video
    XCTAssertNil(model.importSummary)
    try FileManager.default.removeItem(at: root.url.appendingPathComponent("Proxy/Shot.mov"))
    model.rescan()
    for _ in 0..<200 where model.importing { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertEqual(model.importSummary, "Found 0 proxies")
    model.dismissImportSummary()
    XCTAssertNil(model.importSummary)
  }

  @MainActor
  func testCancelledAndIncompleteScansDoNotReportSuccessfulRefresh() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = LibraryModel(
      catalogURL: dir.appendingPathComponent("Catalog/catalog.sqlite"),
      cacheDirectory: dir.appendingPathComponent("Cache"))
    model.catalog = CatalogSnapshot(roots: [
      SourceFolder(url: dir.appendingPathComponent("Offline"))
    ])
    model.rescan()
    for _ in 0..<200 where model.importing { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertFalse(model.importing)
    XCTAssertTrue(model.importSummary?.contains("incomplete") == true)
    XCTAssertNotNil(model.errorMessage)
    model.rescan()
    model.cancelImport()
    for _ in 0..<200 where model.importing { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertFalse(model.importing)
    XCTAssertEqual(model.importSummary, "Refresh stopped")
  }

  func testUnreadableProxyAndAudioAreNotSelected() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let original = dir.appendingPathComponent("Shot.mp4")
    let proxy = dir.appendingPathComponent("Proxy/Shot.mov")
    try write(original)
    try write(proxy)
    let clip = Clip(url: original, rootID: UUID())
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: proxy.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: proxy.path)
    }
    let discovery = ProxyDiscovery()
    let matches = try await discovery.discover([clip])
    XCTAssertNil(matches[clip.id]?.url)
    XCTAssertTrue(matches[clip.id]?.issue?.contains("unreadable") == true)
    let audio = Clip(url: dir.appendingPathComponent("Shot.wav"), rootID: UUID())
    let audioMatches = try await discovery.discover([audio])
    XCTAssertNil(audioMatches[audio.id])
  }

  @MainActor
  func testRefreshRemovesPreviouslyIndexedProxyEntriesOnlyFromCatalog() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = SourceFolder(url: dir.appendingPathComponent("Media"))
    let original = Clip(url: root.url.appendingPathComponent("Shot.mp4"), rootID: root.id)
    let proxy = Clip(url: root.url.appendingPathComponent("Proxy/Shot.mov"), rootID: root.id)
    try write(original.url)
    try write(proxy.url)
    let bytes = try Data(contentsOf: proxy.url)
    let model = LibraryModel(
      catalogURL: dir.appendingPathComponent("Catalog/catalog.sqlite"),
      cacheDirectory: dir.appendingPathComponent("Cache"))
    model.catalog = CatalogSnapshot(
      clips: [original, proxy], roots: [root],
      collections: [ClipCollection(name: "Both", clipIDs: [original.id, proxy.id])])
    await model.refreshProxies()
    XCTAssertEqual(model.catalog.clips.map(\.id), [original.id])
    XCTAssertEqual(model.catalog.clips[0].proxyURL, proxy.url)
    XCTAssertEqual(model.catalog.collections[0].clipIDs, [original.id])
    XCTAssertEqual(try Data(contentsOf: proxy.url), bytes)
  }

  func testOlderCatalogDecodesWithoutProxyFields() throws {
    let clip = Clip(url: URL(fileURLWithPath: "/synthetic/Shot.mp4"), rootID: UUID())
    let data = try JSONEncoder().encode(clip)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "proxyURL")
    object.removeValue(forKey: "proxyIssue")
    let restored = try JSONDecoder().decode(
      Clip.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(restored, clip)
    XCTAssertNil(restored.proxyURL)
  }

  private func makeVideo(_ url: URL, width: Int) async throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: 48,
      ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: 48,
      ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var pixel: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, 48,
        kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pixel)
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddress(buffer), 100, CVPixelBufferGetDataSize(buffer))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    for frame in 0..<48 {
      var waits = 0
      while !input.isReadyForMoreMediaData, writer.status == .writing, waits < 200 {
        try await Task.sleep(for: .milliseconds(10))
        waits += 1
      }
      guard writer.status == .writing, input.isReadyForMoreMediaData else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
      }
      XCTAssertTrue(
        adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(
      writer.status, .completed, writer.error?.localizedDescription ?? "Video writer failed")
  }

  @MainActor
  private func waitForPlayback(_ controller: PlaybackController) async throws {
    for _ in 0..<400 {
      if !controller.loading { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertFalse(controller.loading)
    XCTAssertNil(controller.error)
    XCTAssertEqual(controller.player.currentItem?.status, .readyToPlay)
  }

  @MainActor
  func testRefreshFallsBackFromProxyDiscoveredOnlyAtPlaybackTime() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let original = dir.appendingPathComponent("Media/Shot.mov")
    let proxy = dir.appendingPathComponent("Media/Proxy/Shot.mov")
    try await makeVideo(original, width: 128)
    try await makeVideo(proxy, width: 64)
    let root = SourceFolder(url: dir.appendingPathComponent("Media"))
    let clip = Clip(url: original, rootID: root.id)
    let model = LibraryModel(
      catalogURL: dir.appendingPathComponent("Catalog/catalog.sqlite"),
      cacheDirectory: dir.appendingPathComponent("Cache"))
    model.catalog = CatalogSnapshot(clips: [clip], roots: [root])
    model.select(clip)
    defer { model.playback.show(nil, lut: nil) }
    try await waitForPlayback(model.playback)
    XCTAssertTrue(model.playback.usingProxy)
    XCTAssertNil(model.selectedClip?.proxyURL)
    try FileManager.default.removeItem(at: proxy)
    await model.refreshProxies()
    try await waitForPlayback(model.playback)
    XCTAssertFalse(model.playback.usingProxy)
    XCTAssertEqual((model.playback.player.currentItem?.asset as? AVURLAsset)?.url, original)
  }

  @MainActor
  func testPlaybackPrefersProxySwitchesAndFallsBackWithoutChangingOriginal() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let original = dir.appendingPathComponent("Shot.mov")
    let proxy = dir.appendingPathComponent("Proxy/Shot.mov")
    try await makeVideo(original, width: 128)
    try await makeVideo(proxy, width: 64)
    let originalBytes = try Data(contentsOf: original)
    let proxyBytes = try Data(contentsOf: proxy)
    let clip = Clip(url: original, rootID: UUID())
    let controller = PlaybackController()
    defer { controller.show(nil, lut: nil) }
    let lut = try CubeLUT(
      contents: """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """)
    controller.show(clip, lut: lut)
    try await waitForPlayback(controller)
    XCTAssertNotNil(controller.player.currentItem?.videoComposition)
    XCTAssertTrue(controller.usingProxy)
    XCTAssertEqual((controller.player.currentItem?.asset as? AVURLAsset)?.url, proxy)
    await controller.player.seek(
      to: CMTime(seconds: 0.5, preferredTimescale: 600),
      toleranceBefore: .zero, toleranceAfter: .zero)
    controller.show(clip, lut: lut, preferProxy: false)
    try await waitForPlayback(controller)
    XCTAssertFalse(controller.usingProxy)
    XCTAssertEqual((controller.player.currentItem?.asset as? AVURLAsset)?.url, original)
    XCTAssertEqual(controller.player.currentTime().seconds, 0.5, accuracy: 0.1)
    controller.show(clip, lut: nil)
    try await waitForPlayback(controller)
    controller.player.play()
    let item = try XCTUnwrap(controller.player.currentItem)
    NotificationCenter.default.post(
      name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
    try await Task.sleep(for: .milliseconds(100))
    try await waitForPlayback(controller)
    XCTAssertFalse(controller.usingProxy)
    XCTAssertEqual((controller.player.currentItem?.asset as? AVURLAsset)?.url, original)
    XCTAssertTrue(controller.proxyMessage?.contains("failed") == true)
    XCTAssertGreaterThan(controller.player.rate, 0)
    controller.player.pause()
    XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    XCTAssertEqual(try Data(contentsOf: proxy), proxyBytes)
    let duplicate = proxy.deletingPathExtension().appendingPathExtension("mp4")
    try write(duplicate)
    controller.show(clip, lut: nil)
    try await waitForPlayback(controller)
    XCTAssertFalse(controller.usingProxy)
    XCTAssertTrue(controller.proxyMessage?.contains("Ambiguous") == true)
    try FileManager.default.removeItem(at: duplicate)
    // An unsupported file, and then a missing file, both fall back to the original.
    try FileManager.default.removeItem(at: proxy)
    try write(proxy)
    controller.show(clip, lut: nil)
    try await waitForPlayback(controller)
    XCTAssertFalse(controller.usingProxy)
    XCTAssertEqual((controller.player.currentItem?.asset as? AVURLAsset)?.url, original)
    try FileManager.default.removeItem(at: proxy)
    controller.show(clip, lut: nil)
    try await waitForPlayback(controller)
    XCTAssertFalse(controller.usingProxy)
    XCTAssertEqual((controller.player.currentItem?.asset as? AVURLAsset)?.url, original)
  }
}
