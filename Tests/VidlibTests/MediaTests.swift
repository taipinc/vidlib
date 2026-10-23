import AVFoundation
import XCTest

@testable import Vidlib

private actor ScannedClips {
  var clips: [Clip] = []
  func add(_ clip: Clip) { clips.append(clip) }
}

final class MediaTests: XCTestCase {
  private func makeFloatAudio(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(
      forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
    buffer.frameLength = 96_000
    let samples = buffer.floatChannelData![0]
    for index in 0..<96_000 {
      samples[index] = index == 70_000 ? 2 : sin(Float(index) * 0.01) * 0.25
    }
    try file.write(from: buffer)
  }

  func testFloatAudioAnalysisPreservesAboveFullScaleSamples() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("Float.wav")
    try makeFloatAudio(at: url)
    let before = try Data(contentsOf: url)
    let analysis = try await AudioAnalyzer().analyze(url: url)
    XCTAssertEqual(analysis.peak, 2, accuracy: 0.00001)
    XCTAssertEqual(analysis.frames, 96_000)
    XCTAssertEqual(analysis.peaks.count, 480)
    XCTAssertNotNil(analysis.image())
    let gain = AudioGain.normalizationDB(peak: analysis.peak)!
    XCTAssertEqual(gain, -7.0205999, accuracy: 0.0001)
    var samples: [Float] = [2, -2, 0.25]
    samples.withUnsafeMutableBufferPointer {
      AudioGain.apply($0.baseAddress!, count: $0.count, db: gain)
    }
    XCTAssertEqual(samples[0], pow(10, -1 / 20), accuracy: 0.00001)
    XCTAssertEqual(samples[1], -samples[0], accuracy: 0.00001)
    XCTAssertEqual(try Data(contentsOf: url), before)
    XCTAssertNoThrow(try AudioGainTap.make(db: gain))
    XCTAssertNil(AudioGain.normalizationDB(peak: 0))
    XCTAssertEqual(AudioGain.clamped(.infinity), 0)
  }

  func testRecursiveRefreshDiscoversNewNestedAudioOnlyOnce() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = dir.appendingPathComponent("2026/Import One/First.WAV")
    try makeFloatAudio(at: first)
    let root = SourceFolder(url: dir)
    let scanner = MediaScanner()
    let initial = ScannedClips()
    try await scanner.scan(root: root, known: []) { await initial.add($0) }
    let clips = await initial.clips
    XCTAssertEqual(clips.count, 1)
    XCTAssertTrue(clips[0].isAudio)
    XCTAssertEqual(clips[0].duration, 2, accuracy: 0.01)
    let second = dir.appendingPathComponent("2026/Import Two/Nested/Second.wav")
    try makeFloatAudio(at: second)
    let additions = ScannedClips()
    try await scanner.scan(root: root, known: Set(clips.map { $0.url.path })) {
      await additions.add($0)
    }
    let newClips = await additions.clips
    XCTAssertEqual(newClips.map(\.name), ["Second.wav"])
    let repeated = ScannedClips()
    try await scanner.scan(root: root, known: Set((clips + newClips).map { $0.url.path })) {
      await repeated.add($0)
    }
    let duplicates = await repeated.clips
    XCTAssertTrue(duplicates.isEmpty)
  }

  func testPlaybackAudioMixAppliesGainBeforeOutput() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("Float.wav")
    try makeFloatAudio(at: url)
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderAudioMixOutput(
      audioTracks: tracks,
      audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
      ])
    let mix = AVMutableAudioMix()
    let parameters = AVMutableAudioMixInputParameters(track: try XCTUnwrap(tracks.first))
    parameters.audioTapProcessor = try AudioGainTap.make(db: -12)
    mix.inputParameters = [parameters]
    output.audioMix = mix
    reader.add(output)
    guard reader.startReading() else {
      XCTFail("Audio reader failed: \(String(describing: reader.error as NSError?))")
      return
    }
    var peak: Float = 0
    while let sample = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      let length = CMBlockBufferGetDataLength(block)
      var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
      let status = values.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(
          block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
      }
      XCTAssertEqual(status, noErr)
      peak = max(peak, values.map(abs).max() ?? 0)
    }
    XCTAssertEqual(
      reader.status, .completed, reader.error?.localizedDescription ?? "Reader did not finish")
    XCTAssertEqual(peak, 2 * AudioGain.linear(-12), accuracy: 0.0001)
  }

  @MainActor
  func testTitlesDescriptionsLUTRenamingAndMixedMediaEdits() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = LibraryModel(
      catalogURL: dir.appendingPathComponent("catalog.sqlite"),
      cacheDirectory: dir.appendingPathComponent("Cache"))
    let root = SourceFolder(url: dir)
    let video = Clip(url: dir.appendingPathComponent("video.mp4"), rootID: root.id)
    let audio = Clip(url: dir.appendingPathComponent("audio.wav"), rootID: root.id)
    let lut = LUTReference(name: "Long Original Name", fileName: "fixed-name.cube")
    model.catalog = CatalogSnapshot(clips: [video, audio], roots: [root], luts: [lut])
    model.gridSelection = ClipSelection(ids: [audio.id], focusedID: audio.id)
    model.setDetails(title: "Field recording", description: "A quiet forest at dawn")
    XCTAssertEqual(model.catalog.clips[1].displayTitle, "Field recording")
    model.search = "forest"
    XCTAssertEqual(model.visibleClips.map(\.id), [audio.id])
    model.search = "Field recording"
    XCTAssertEqual(model.visibleClips.map(\.id), [audio.id])
    model.search = ""
    model.gridSelection = ClipSelection(ids: [video.id, audio.id], focusedID: video.id)
    model.setLUT(lut.id)
    XCTAssertEqual(model.catalog.clips[0].lutID, lut.id)
    XCTAssertNil(model.catalog.clips[1].lutID)
    model.setAudioGain(12)
    XCTAssertEqual(model.catalog.clips[1].gainDB, 12)
    XCTAssertNil(model.catalog.clips[0].gainDB)
    model.renameLUT(id: lut.id, name: "SLog-3 → Rec.709")
    XCTAssertEqual(model.catalog.luts[0].fileName, "fixed-name.cube")
    XCTAssertEqual(model.catalog.luts[0].name, "SLog-3 → Rec.709")
    XCTAssertEqual(model.catalog.clips[0].lutID, lut.id)
    let restored = try CatalogStore(url: dir.appendingPathComponent("catalog.sqlite")).load()
    XCTAssertEqual(restored.clips[1].notes, "A quiet forest at dawn")
    XCTAssertEqual(restored.clips[1].gainDB, 12)
  }

  func testLegacyCatalogGetsBackupAndRetainsAllEntries() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("catalog.sqlite")
    let store = try CatalogStore(url: url)
    let clip = Clip(url: dir.appendingPathComponent("legacy.mp4"), rootID: UUID())
    var old = CatalogSnapshot(clips: [clip])
    old.schemaVersion = nil
    try store.save(old)
    let restored = try store.load()
    XCTAssertEqual(restored.clips, [clip])
    XCTAssertEqual(restored.schemaVersion, 2)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("catalog.before-v2.sqlite").path))
    XCTAssertEqual(restored.clips[0].displayTitle, "legacy.mp4")
  }
}
