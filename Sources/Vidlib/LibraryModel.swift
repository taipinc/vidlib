import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LibraryModel: ObservableObject {
  @Published var catalog = CatalogSnapshot()
  @Published var selection: LibrarySelection = .all { didSet { reconcileSelection() } }
  @Published var gridSelection = ClipSelection()
  @Published var search = "" { didSet { reconcileSelection() } }
  @Published var sortByDate = true
  @Published var importing = false
  @Published var importStatus = ""
  @Published var errorMessage: String?
  @Published var cacheURL: URL
  @Published var cacheLimitGB: Double
  @Published var cacheBytes: Int64 = 0
  @Published var cacheGeneration = 0
  @Published var bypassLUT = false
  @Published var analyzingAudio = false
  let thumbnails: ThumbnailCache
  let playback = PlaybackController()
  private var store: CatalogStore?
  private let scanner = MediaScanner()
  private var importTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var activeScopes: [URL] = []
  private var loadedLUTs: [UUID: CubeLUT] = [:]

  init(catalogURL: URL? = nil, cacheDirectory: URL? = nil) {
    let savedPath = UserDefaults.standard.string(forKey: "cachePath")
    let directory =
      cacheDirectory ?? savedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? AppPaths.defaultCache
    let savedLimit = UserDefaults.standard.double(forKey: "cacheLimitGB")
    let limit = savedLimit > 0 ? savedLimit : 5
    cacheURL = directory
    cacheLimitGB = limit
    thumbnails = ThumbnailCache(directory: directory, limitGB: limit)
    do {
      let store = try CatalogStore(
        url: catalogURL ?? AppPaths.support.appendingPathComponent("catalog.sqlite"))
      catalog = try store.load()
      self.store = store
      for index in catalog.roots.indices {
        if let bookmark = catalog.roots[index].bookmark {
          var stale = false
          if let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting], bookmarkDataIsStale: &stale
          ) {
            let old = catalog.roots[index].url
            catalog.roots[index].url = resolved
            if resolved.startAccessingSecurityScopedResource() { activeScopes.append(resolved) }
            if old != resolved {
              for clipIndex in catalog.clips.indices
              where catalog.clips[clipIndex].rootID == catalog.roots[index].id {
                let suffix = String(catalog.clips[clipIndex].url.path.dropFirst(old.path.count))
                catalog.clips[clipIndex].url = URL(fileURLWithPath: resolved.path + suffix)
              }
            }
          }
        }
      }
      for reference in catalog.luts {
        if let text = try? String(
          contentsOf: AppPaths.lutDirectory.appendingPathComponent(reference.fileName),
          encoding: .utf8), let lut = try? CubeLUT(contents: text)
        {
          loadedLUTs[reference.id] = lut
        }
      }
    } catch { errorMessage = "Could not load the catalog: \(error.localizedDescription)" }
    refreshCacheUsage()
  }

  var selectedID: UUID? { gridSelection.focusedID }
  var selectedIDs: Set<UUID> { gridSelection.ids }
  var selectedClips: [Clip] { catalog.clips.filter { selectedIDs.contains($0.id) } }
  var selectedClip: Clip? { catalog.clips.first { $0.id == selectedID } }
  var selectedVideos: [Clip] { selectedClips.filter { !$0.isAudio } }
  var selectedAudio: [Clip] { selectedClips.filter(\.isAudio) }
  var hasMixedLUTs: Bool { Set(selectedVideos.map(\.lutID)).count > 1 }
  var commonLUT: UUID? { hasMixedLUTs ? nil : selectedVideos.first?.lutID }
  var folders: [String] { Array(Set(catalog.clips.map(\.folder))).sorted() }
  var folderTree: [FolderNode] {
    let roots = catalog.roots.map { $0.url.path }
    return roots.filter { path in !roots.contains { path != $0 && path.hasPrefix($0 + "/") } }
      .sorted().map { FolderNode.tree(root: $0, folders: folders) }
  }
  var visibleClips: [Clip] {
    let collectionIDs: Set<UUID>?
    if case .collection(let id) = selection {
      collectionIDs = catalog.collections.first { $0.id == id }?.clipIDs ?? []
    } else {
      collectionIDs = nil
    }
    return catalog.clips.filter { clip in
      if let collectionIDs, !collectionIDs.contains(clip.id) { return false }
      if case .folder(let path) = selection,
        clip.folder != path && !clip.folder.hasPrefix(path + "/")
      {
        return false
      }
      return search.isEmpty
        || ([clip.name, clip.folder, clip.title ?? "", clip.notes ?? ""] + clip.tags).joined(
          separator: " "
        ).localizedCaseInsensitiveContains(search)
    }.sorted {
      if sortByDate, $0.date != $1.date {
        return ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
      }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
  var selectionTitle: String {
    switch selection {
    case .all: return "All Media"
    case .collection(let id): return catalog.collections.first { $0.id == id }?.name ?? "Collection"
    case .folder(let path): return URL(fileURLWithPath: path).lastPathComponent
    }
  }

  func lut(for clip: Clip) -> CubeLUT? {
    clip.isAudio ? nil : clip.lutID.flatMap { loadedLUTs[$0] }
  }

  func select(_ clip: Clip, modifiers: NSEvent.ModifierFlags = []) {
    let previous = selectedID
    let wasBypassed = bypassLUT
    gridSelection.select(
      clip.id, orderedIDs: visibleClips.map(\.id), extending: modifiers.contains(.shift),
      toggling: modifiers.contains(.command))
    bypassLUT = false
    if previous != selectedID || wasBypassed { updatePlayback() }
  }
  func reconcileSelection() {
    let previous = selectedID
    gridSelection.retain(visibleIDs: visibleClips.map(\.id))
    if previous != selectedID {
      bypassLUT = false
      updatePlayback()
    }
  }
  func dragPayload(for clip: Clip) -> ClipDragPayload {
    ClipDragPayload(
      ids: selectedIDs.contains(clip.id)
        ? visibleClips.filter { selectedIDs.contains($0.id) }.map(\.id) : [clip.id])
  }
  func updatePlayback() {
    playback.show(selectedClip, lut: bypassLUT ? nil : selectedClip.flatMap { lut(for: $0) })
  }

  func addFolder() {
    guard !importing, store != nil else { return }
    let panel = NSOpenPanel()
    panel.title = "Add a media folder"
    panel.message =
      "Video and audio stay in place. Refresh checks this folder and all its subfolders for new media."
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Add to Catalog"
    guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
    let protected = [cacheURL, AppPaths.support]
    guard !protected.contains(where: { Self.overlaps(url, $0) }) else {
      errorMessage = "Choose a footage folder separate from Vidlib’s catalog and cache locations."
      return
    }
    let existingRoot = catalog.roots.first { $0.url == url }
    var root = existingRoot ?? SourceFolder(url: url)
    if url.startAccessingSecurityScopedResource() { activeScopes.append(url) }
    root.bookmark = try? url.bookmarkData(
      options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
      includingResourceValuesForKeys: nil, relativeTo: nil)
    if existingRoot == nil {
      catalog.roots.append(root)
    } else if let index = catalog.roots.firstIndex(where: { $0.id == root.id }) {
      catalog.roots[index] = root
    }
    save()
    startScan(root)
  }

  func rescan() {
    guard !importing else { return }
    let roots = catalog.roots
    importing = true
    importStatus = "Checking folders…"
    importTask = Task {
      for root in roots {
        guard !Task.isCancelled else { break }
        await scan(root)
      }
      finishImport()
    }
  }
  private func startScan(_ root: SourceFolder) {
    importing = true
    importStatus = "Reading \(root.url.lastPathComponent)…"
    importTask = Task {
      await scan(root)
      finishImport()
    }
  }
  private func scan(_ root: SourceFolder) async {
    let known = Set(catalog.clips.map { $0.url.standardizedFileURL.path })
    do {
      try await scanner.scan(root: root, known: known) { [weak self] clip in
        await self?.receive(clip)
      }
    } catch is CancellationError {} catch {
      errorMessage =
        "Could not finish scanning \(root.url.lastPathComponent): \(error.localizedDescription)"
    }
  }
  private func receive(_ clip: Clip) {
    guard !catalog.clips.contains(where: { $0.url == clip.url }) else { return }
    catalog.clips.append(clip)
    importStatus = "\(catalog.clips.count) files cataloged · \(clip.name)"
    saveTask?.cancel()
    saveTask = Task {
      try? await Task.sleep(for: .seconds(0.5))
      guard !Task.isCancelled else { return }
      save()
    }
  }
  private func finishImport() {
    importing = false
    importStatus = ""
    saveTask?.cancel()
    save()
  }
  func cancelImport() {
    importTask?.cancel()
    importStatus = "Stopping after the current file…"
  }

  func createCollection(name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let collection = ClipCollection(name: name)
    catalog.collections.append(collection)
    selection = .collection(collection.id)
    save()
  }
  func addSelected(to id: UUID) {
    addClips(selectedIDs, to: id)
  }
  @discardableResult
  func addClips(_ ids: Set<UUID>, to id: UUID) -> Bool {
    guard let index = catalog.collections.firstIndex(where: { $0.id == id }) else { return false }
    let valid = ids.intersection(catalog.clips.map(\.id))
    guard !valid.isEmpty else { return false }
    catalog.collections[index].clipIDs.formUnion(valid)
    save()
    return true
  }
  func removeSelectedFromCollection() {
    guard !selectedIDs.isEmpty, case .collection(let id) = selection,
      let index = catalog.collections.firstIndex(where: { $0.id == id })
    else { return }
    catalog.collections[index].clipIDs.subtract(selectedIDs)
    save()
    reconcileSelection()
  }
  func setTags(_ text: String) {
    guard !selectedIDs.isEmpty else { return }
    var seen = Set<String>()
    let tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    for index in catalog.clips.indices where selectedIDs.contains(catalog.clips[index].id) {
      if selectedIDs.count == 1 {
        catalog.clips[index].tags = tags
      } else {
        let existing = Set(catalog.clips[index].tags.map { $0.lowercased() })
        catalog.clips[index].tags += tags.filter { !existing.contains($0.lowercased()) }
      }
    }
    save()
  }
  func setLUT(_ id: UUID?) {
    guard !selectedIDs.isEmpty, id == nil || catalog.luts.contains(where: { $0.id == id }) else {
      return
    }
    for index in catalog.clips.indices
    where selectedIDs.contains(catalog.clips[index].id) && !catalog.clips[index].isAudio {
      catalog.clips[index].lutID = id
    }
    bypassLUT = false
    save()
    updatePlayback()
  }

  func renameLUT(id: UUID, name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let index = catalog.luts.firstIndex(where: { $0.id == id }) else { return }
    catalog.luts[index].name = name
    save()
  }

  func setDetails(title: String, description: String) {
    guard selectedIDs.count == 1,
      let index = catalog.clips.firstIndex(where: { $0.id == selectedID })
    else { return }
    catalog.clips[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    catalog.clips[index].notes = description
    save()
    reconcileSelection()
  }

  func setAudioGain(_ db: Double) {
    let ids = Set(selectedAudio.map(\.id))
    guard !ids.isEmpty else { return }
    for index in catalog.clips.indices where ids.contains(catalog.clips[index].id) {
      catalog.clips[index].gainDB = AudioGain.clamped(db)
    }
    save()
    if selectedClip?.isAudio == true { updatePlayback() }
  }

  func normalizeAudio() {
    let clips = selectedAudio
    guard !clips.isEmpty, !analyzingAudio else { return }
    analyzingAudio = true
    Task {
      defer { analyzingAudio = false }
      do {
        var gains: [UUID: Double] = [:]
        for clip in clips {
          let analysis = try await thumbnails.audioAnalysis(clip: clip)
          guard let gain = AudioGain.normalizationDB(peak: analysis.peak) else {
            throw NSError(
              domain: "Vidlib.Audio", code: 1,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "\(clip.displayTitle) is silent or has no finite samples; no gains were changed."
              ])
          }
          gains[clip.id] = gain
        }
        for index in catalog.clips.indices {
          if let gain = gains[catalog.clips[index].id] { catalog.clips[index].gainDB = gain }
        }
        save()
        if let selectedID, gains[selectedID] != nil { updatePlayback() }
      } catch { errorMessage = "Audio analysis failed: \(error.localizedDescription)" }
    }
  }
  func importLUT() { importLUT(applyToSelection: true) }
  func importLUTOnly() { importLUT(applyToSelection: false) }
  private func importLUT(applyToSelection: Bool) {
    let panel = NSOpenPanel()
    panel.title = "Import a 3D .cube LUT"
    panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let text = try String(contentsOf: url, encoding: .utf8)
      let lut = try CubeLUT(contents: text)
      let id = UUID()
      let reference = LUTReference(
        id: id, name: url.deletingPathExtension().lastPathComponent, fileName: "\(id).cube")
      try FileManager.default.createDirectory(
        at: AppPaths.lutDirectory, withIntermediateDirectories: true)
      try text.write(
        to: AppPaths.lutDirectory.appendingPathComponent(reference.fileName), atomically: true,
        encoding: .utf8)
      catalog.luts.append(reference)
      loadedLUTs[id] = lut
      save()
      if applyToSelection && selectedID != nil { setLUT(id) }
    } catch { errorMessage = error.localizedDescription }
  }

  func chooseCacheLocation() {
    let panel = NSOpenPanel()
    panel.title = "Choose cache location"
    panel.message =
      "Vidlib creates a dedicated Vidlib-Thumbnails folder here. Existing cache stays at its old location."
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
    guard !catalog.roots.contains(where: { Self.overlaps(url, $0.url) }),
      !Self.overlaps(url, AppPaths.support)
    else {
      errorMessage = "Cache must be separate from footage folders and the catalog."
      return
    }
    cacheURL = url
    UserDefaults.standard.set(url.path, forKey: "cachePath")
    configureCache()
  }
  func configureCache() {
    UserDefaults.standard.set(cacheLimitGB, forKey: "cacheLimitGB")
    let directory = cacheURL
    let limit = cacheLimitGB
    Task {
      do {
        try await thumbnails.configure(directory: directory, limitGB: limit)
        cacheGeneration += 1
        refreshCacheUsage()
      } catch { errorMessage = error.localizedDescription }
    }
  }
  func clearCache() {
    Task {
      do {
        try await thumbnails.clear()
        cacheBytes = await thumbnails.usage()
      } catch { errorMessage = error.localizedDescription }
    }
  }
  func refreshCacheUsage() { Task { cacheBytes = await thumbnails.usage() } }
  func save() {
    guard let store else { return }
    do { try store.save(catalog) } catch {
      errorMessage = "Could not save the catalog: \(error.localizedDescription)"
    }
  }
  static func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
    let a = lhs.resolvingSymlinksInPath().standardizedFileURL.path
    let b = rhs.resolvingSymlinksInPath().standardizedFileURL.path
    return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
  }
}
