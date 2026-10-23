import AVFoundation
import AppKit
import CoreImage
import CryptoKit

actor MediaScanner {
  static let extensions = ProxyDiscovery.videoExtensions.union(
    MediaKind.audioExtensions)

  func scan(
    root: SourceFolder, known: Set<String>, receive: @escaping @Sendable (Clip) async -> Void
  ) async throws {
    guard
      !root.url.pathComponents.contains(where: {
        $0.caseInsensitiveCompare("Proxy") == .orderedSame
      })
    else { return }
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .creationDateKey]
    var scanError: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: root.url, includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { _, error in
          scanError = error
          return true
        })
    else { throw CocoaError(.fileReadUnknown) }
    // Directory iteration and metadata reads happen off the main actor.
    while let url = enumerator.nextObject() as? URL {
      try Task.checkCancellation()
      if ProxyDiscovery.isProxyDirectory(url),
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      {
        enumerator.skipDescendants()
        continue
      }
      guard Self.extensions.contains(url.pathExtension.lowercased()),
        !known.contains(url.standardizedFileURL.path),
        let resources = try? url.resourceValues(forKeys: Set(keys)), resources.isRegularFile == true
      else { continue }
      var clip = Clip(url: url.standardizedFileURL, rootID: root.id)
      clip.kind =
        MediaKind.audioExtensions.contains(url.pathExtension.lowercased()) ? .audio : .video
      let asset = AVURLAsset(url: url)
      do {
        let duration = try await asset.load(.duration)
        clip.duration = duration.seconds.isFinite ? duration.seconds : 0
        if let track = try await asset.loadTracks(withMediaType: .video).first {
          let size = try await track.load(.naturalSize)
          clip.width = Int(abs(size.width))
          clip.height = Int(abs(size.height))
          clip.kind = .video
        } else if !(try await asset.loadTracks(withMediaType: .audio)).isEmpty {
          clip.kind = .audio
        } else {
          clip.issue = "No playable media track found"
        }
        if let creation = try? await asset.load(.creationDate),
          let date = try? await creation.load(.dateValue)
        {
          clip.date = date
          clip.dateSource = "Embedded recording date (camera clock)"
        }
      } catch {
        clip.issue = "Metadata unavailable: \(error.localizedDescription)"
      }
      if clip.date == nil {
        clip.date = resources.creationDate
        clip.dateSource = clip.date == nil ? "Unknown" : "File creation date (fallback)"
      }
      await receive(clip)
    }
    if let scanError { throw scanError }
  }
}

actor ThumbnailCache {
  private var directory: URL
  private var limit: Int64
  private var lastTrim = Date.distantPast
  private var activeRequests = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private let context = CIContext(options: [
    .workingColorSpace: NSNull(), .cacheIntermediates: false,
  ])
  private let audioAnalyzer = AudioAnalyzer()
  private var pendingAudio: [UUID: Task<AudioAnalysis, Error>] = [:]

  init(directory: URL, limitGB: Double) {
    self.directory = directory.appendingPathComponent("Vidlib-Thumbnails", isDirectory: true)
    limit = Int64(limitGB * 1_000_000_000)
  }

  func configure(directory: URL, limitGB: Double) throws {
    self.directory = directory.appendingPathComponent("Vidlib-Thumbnails", isDirectory: true)
    limit = Int64(limitGB * 1_000_000_000)
    try trim()
  }

  func thumbnail(clip: Clip, lut: CubeLUT?, lutID: UUID?) async -> Data? {
    let key = "\(clip.id)-\(clip.isAudio ? "audio" : lutID?.uuidString ?? "original")-v2"
    let name =
      SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
    let destination = directory.appendingPathComponent(name)
    if let cached = try? Data(contentsOf: destination) {
      try? FileManager.default.setAttributes(
        [.modificationDate: Date()], ofItemAtPath: destination.path)
      return cached
    }
    await acquireSlot()
    defer { releaseSlot() }
    guard !Task.isCancelled else { return nil }
    if clip.isAudio {
      do {
        let analysis = try await audioAnalysis(clip: clip)
        guard let image = analysis.image(),
          let data = NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg, properties: [.compressionFactor: 0.8])
        else { return nil }
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        try trim()
        return data
      } catch { return nil }
    }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 270)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
    do {
      let result = try await withTaskCancellationHandler {
        try await generator.image(
          at: CMTime(seconds: min(1, clip.duration / 2), preferredTimescale: 600))
      } onCancel: {
        generator.cancelAllCGImageGeneration()
      }
      try Task.checkCancellation()
      var cgImage = result.image
      if let lut,
        let adjusted = context.createCGImage(
          lut.apply(to: CIImage(cgImage: cgImage)),
          from: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
      {
        cgImage = adjusted
      }
      let bitmap = NSBitmapImageRep(cgImage: cgImage)
      guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
      else { return nil }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: destination, options: .atomic)
      try trim()
      return data
    } catch { return nil }
  }

  func audioAnalysis(clip: Clip) async throws -> AudioAnalysis {
    let destination = directory.appendingPathComponent("\(clip.id)-waveform-v1.json")
    if let data = try? Data(contentsOf: destination),
      let analysis = try? JSONDecoder().decode(AudioAnalysis.self, from: data)
    {
      try? FileManager.default.setAttributes(
        [.modificationDate: Date()], ofItemAtPath: destination.path)
      return analysis
    }
    if let pending = pendingAudio[clip.id] { return try await pending.value }
    let analyzer = audioAnalyzer
    let pending = Task(priority: .utility) { try await analyzer.analyze(url: clip.url) }
    pendingAudio[clip.id] = pending
    defer { pendingAudio[clip.id] = nil }
    let analysis = try await pending.value
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(analysis).write(to: destination, options: .atomic)
    try trim()
    return analysis
  }

  private func acquireSlot() async {
    if activeRequests < 2 {
      activeRequests += 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }
  private func releaseSlot() {
    if waiters.isEmpty { activeRequests -= 1 } else { waiters.removeFirst().resume() }
  }

  func usage() -> Int64 {
    entries().reduce(0) {
      $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
  }

  func clear() throws {
    // Delete only files in the dedicated generated-thumbnail directory.
    for url in entries() { try FileManager.default.removeItem(at: url) }
  }

  private func entries() -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
      options: .skipsHiddenFiles)) ?? [])
      .filter { ["jpg", "json"].contains($0.pathExtension) }
  }

  private func trim() throws {
    lastTrim = Date()
    let files = entries().map { url -> (URL, Int64, Date) in
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
    }.sorted { $0.2 < $1.2 }
    var total = files.reduce(Int64(0)) { $0 + $1.1 }
    for file in files where total > limit {
      try FileManager.default.removeItem(at: file.0)
      total -= file.1
    }
  }
}

@MainActor
final class PlaybackController: ObservableObject {
  let player = AVPlayer()
  @Published var error: String?
  @Published var loading = false
  @Published var usingProxy = false
  @Published var proxyMessage: String?
  private var task: Task<Void, Never>?
  private var observation: NSKeyValueObservation?
  private var failureObservation: NSObjectProtocol?
  private let proxyDiscovery = ProxyDiscovery()
  private var generation = UUID()
  private let context = CIContext(options: [
    .workingColorSpace: NSNull(), .cacheIntermediates: false,
  ])
  private var currentID: UUID?

  func show(_ clip: Clip?, lut: CubeLUT?, preferProxy: Bool = true) {
    let sameClip = clip?.id == currentID
    let position = sameClip ? player.currentTime() : .zero
    let resume = sameClip && player.rate > 0
    currentID = clip?.id
    generation = UUID()
    let token = generation
    task?.cancel()
    clearObservers()
    player.pause()
    player.replaceCurrentItem(with: nil)
    error = nil
    usingProxy = false
    proxyMessage = nil
    guard let clip else {
      loading = false
      return
    }
    loading = true
    task = Task { [self] in
      do {
        if preferProxy, !clip.isAudio {
          // Check again at playback time: a saved link may have gone offline or become ambiguous.
          let match = try await proxyDiscovery.discover([clip])[clip.id] ?? ProxyMatch()
          try Task.checkCancellation()
          guard token == generation else { return }
          proxyMessage = match.issue
          if let url = match.url {
            do {
              try await open(
                clip, lut: lut, url: url, isProxy: true,
                position: position, resume: resume, token: token)
              return
            } catch is CancellationError { return } catch {
              guard token == generation else { return }
              proxyMessage = "Proxy unavailable or unsupported; using original."
            }
          } else if proxyMessage == nil {
            proxyMessage = "No matching proxy found; using original."
          }
        }
        try await open(
          clip, lut: lut, url: clip.url, isProxy: false,
          position: position, resume: resume, token: token)
      } catch is CancellationError {} catch {
        guard token == generation else { return }
        self.error = error.localizedDescription
        loading = false
      }
    }
  }

  private func clearObservers() {
    observation = nil
    if let failureObservation { NotificationCenter.default.removeObserver(failureObservation) }
    failureObservation = nil
  }

  private func open(
    _ clip: Clip, lut: CubeLUT?, url: URL, isProxy: Bool,
    position: CMTime, resume: Bool, token: UUID
  ) async throws {
    let asset = AVURLAsset(url: url)
    guard try await asset.load(.isPlayable) else {
      throw NSError(
        domain: "Vidlib.Playback", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "This format cannot be played by the current macOS media engine. The file may also be offline."
        ])
    }
    if isProxy, try await asset.loadTracks(withMediaType: .video).isEmpty {
      throw NSError(
        domain: "Vidlib.Playback", code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: "The proxy has no video track."
        ])
    }
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 5
    if clip.isAudio, clip.playbackGainDB != 0 {
      let tracks = try await asset.loadTracks(withMediaType: .audio)
      let mix = AVMutableAudioMix()
      mix.inputParameters = try tracks.map { track in
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = try AudioGainTap.make(db: clip.playbackGainDB)
        return parameters
      }
      item.audioMix = mix
    }
    if let lut, !clip.isAudio {
      let ciContext = context
      item.videoComposition = try await AVVideoComposition.videoComposition(
        with: asset,
        applyingCIFiltersWithHandler: { request in
          let source = request.sourceImage
          request.finish(with: lut.apply(to: source).cropped(to: source.extent), context: ciContext)
        })
    }
    try Task.checkCancellation()
    guard token == generation else { throw CancellationError() }
    clearObservers()
    usingProxy = isProxy
    player.replaceCurrentItem(with: item)
    observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      Task { @MainActor [weak self] in
        guard let self, token == self.generation, self.player.currentItem === item else { return }
        if item.status == .failed {
          self.failed(
            item, clip: clip, lut: lut, isProxy: isProxy,
            initialPosition: position, resume: resume, token: token)
        } else if item.status == .readyToPlay {
          self.loading = false
        }
      }
    }
    failureObservation = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, token == self.generation, self.player.currentItem === item else { return }
        self.failed(
          item, clip: clip, lut: lut, isProxy: isProxy,
          initialPosition: position, resume: resume, token: token)
      }
    }
    if position.isNumeric, position.seconds > 0 { await player.seek(to: position) }
    try Task.checkCancellation()
    guard token == generation, player.currentItem === item else { return }
    if resume { player.play() }
  }

  private func failed(
    _ item: AVPlayerItem, clip: Clip, lut: CubeLUT?, isProxy: Bool,
    initialPosition: CMTime, resume: Bool, token: UUID
  ) {
    guard isProxy else {
      error = item.error?.localizedDescription ?? "Playback failed. Check the NAS connection."
      loading = false
      return
    }
    // Retry exactly once with the canonical original, including failures after playback starts.
    let time = player.currentTime()
    let position = time.isNumeric && time.seconds > 0 ? time : initialPosition
    let shouldResume = player.rate > 0 || (loading && resume)
    clearObservers()
    player.pause()
    player.replaceCurrentItem(with: nil)
    usingProxy = false
    loading = true
    proxyMessage = "Proxy playback failed; using original."
    task?.cancel()
    task = Task { [self] in
      do {
        try await open(
          clip, lut: lut, url: clip.url, isProxy: false,
          position: position, resume: shouldResume, token: token)
      } catch is CancellationError {} catch {
        guard token == generation else { return }
        self.error = error.localizedDescription
        loading = false
      }
    }
  }
}
