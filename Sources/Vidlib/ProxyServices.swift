import Foundation

struct ProxyMatch: Equatable {
  var url: URL?
  var issue: String?
}

/// All directory access runs on this actor, never in a view or on the main actor.
/// Listings are shared within a refresh, but discarded afterward so additions/removals are visible.
actor ProxyDiscovery {
  static let videoExtensions: Set<String> = [
    "mp4", "mov", "m4v", "mxf", "mts", "m2ts", "avi", "mkv",
  ]

  static func isProxyDirectory(_ url: URL) -> Bool {
    url.lastPathComponent.caseInsensitiveCompare("Proxy") == .orderedSame
  }

  func discover(_ clips: [Clip]) throws -> [UUID: ProxyMatch] {
    var listings: [URL: Result<[URL], Error>] = [:]
    func listing(_ directory: URL) throws -> [URL] {
      if let saved = listings[directory] { return try saved.get() }
      let result = Result {
        try FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
          options: [.skipsHiddenFiles])
      }
      listings[directory] = result
      return try result.get()
    }
    var matches: [UUID: ProxyMatch] = [:]
    for clip in clips where !clip.isAudio {
      try Task.checkCancellation()
      do {
        let siblings = try listing(clip.url.deletingLastPathComponent())
        let directories = siblings.filter {
          Self.isProxyDirectory($0)
            && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !directories.isEmpty else {
          matches[clip.id] = ProxyMatch()
          continue
        }
        guard directories.count == 1 else {
          matches[clip.id] = ProxyMatch(issue: "Multiple Proxy folders found; using original.")
          continue
        }
        let stem = clip.url.deletingPathExtension().lastPathComponent
        func sameStem(_ url: URL) -> Bool {
          url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(stem) == .orderedSame
        }
        let originals = siblings.filter {
          Self.videoExtensions.contains($0.pathExtension.lowercased()) && sameStem($0)
            && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        let candidates = try listing(directories[0]).filter {
          Self.videoExtensions.contains($0.pathExtension.lowercased()) && sameStem($0)
            && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard !candidates.isEmpty else {
          matches[clip.id] = ProxyMatch()
          continue
        }
        guard originals.count == 1, candidates.count == 1,
          originals[0].standardizedFileURL == clip.url.standardizedFileURL
        else {
          matches[clip.id] = ProxyMatch(
            issue:
              "Ambiguous proxy filename match; using original. Keep one original and one proxy with this filename stem in their respective folders."
          )
          continue
        }
        guard FileManager.default.isReadableFile(atPath: candidates[0].path) else {
          matches[clip.id] = ProxyMatch(issue: "Proxy is unreadable; using original.")
          continue
        }
        matches[clip.id] = ProxyMatch(url: candidates[0].standardizedFileURL)
      } catch {
        matches[clip.id] = ProxyMatch(issue: "Could not check the Proxy folder; using original.")
      }
    }
    return matches
  }
}
