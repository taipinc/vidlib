import Foundation

struct Clip: Identifiable, Codable, Equatable {
  var id = UUID()
  var url: URL
  var rootID: UUID
  var duration: Double = 0
  var width: Int = 0
  var height: Int = 0
  var date: Date?
  var dateSource = "Unknown"
  var tags: [String] = []
  var lutID: UUID?
  var issue: String?
  // Optional additions keep catalogs written by earlier versions decodable.
  var title: String?
  var notes: String?
  var kind: MediaKind?
  var gainDB: Double?
  var proxyURL: URL?
  var proxyIssue: String?
  var rotation: VideoRotation?
  var name: String { url.lastPathComponent }
  var displayTitle: String {
    let text = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.isEmpty ? name : text
  }
  var isAudio: Bool {
    kind == .audio
      || (kind == nil && MediaKind.audioExtensions.contains(url.pathExtension.lowercased()))
  }
  var playbackGainDB: Double { AudioGain.clamped(gainDB ?? 0) }
  var folder: String { url.deletingLastPathComponent().path }
  var durationLabel: String {
    guard duration.isFinite, duration > 0 else { return "—" }
    let seconds = Int(duration)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

/// Correction applied after the file's embedded orientation, without changing the file.
enum VideoRotation: Int, Codable, CaseIterable {
  case clockwise90 = 90
  case halfTurn = 180
  case counterclockwise90 = 270
  var label: String {
    switch self {
    case .clockwise90: return "90° clockwise"
    case .halfTurn: return "180°"
    case .counterclockwise90: return "90° counterclockwise"
    }
  }
  var swapsDimensions: Bool { self != .halfTurn }
}

struct EditingProject: Identifiable, Codable {
  var id = UUID()
  var name: String
  var clipIDs: Set<UUID> = []
  var resolveProjectName: String?
}

enum MediaKind: String, Codable {
  case video, audio
  static let audioExtensions: Set<String> = [
    "wav", "wave", "aif", "aiff", "aifc", "caf", "m4a", "mp3", "aac", "flac", "alac",
  ]
}

struct SourceFolder: Identifiable, Codable {
  var id = UUID()
  var url: URL
  var bookmark: Data?
}

struct ClipCollection: Identifiable, Codable {
  var id = UUID()
  var name: String
  var clipIDs: Set<UUID> = []
}

struct LUTReference: Identifiable, Codable {
  var id = UUID()
  var name: String
  var fileName: String
}

struct CatalogSnapshot: Codable {
  var clips: [Clip] = []
  var roots: [SourceFolder] = []
  var collections: [ClipCollection] = []
  var luts: [LUTReference] = []
  var schemaVersion: Int? = 2
  // Optional storage preserves decoding of every earlier catalog snapshot.
  var projects: [EditingProject]?
  var editingProjects: [EditingProject] {
    get { projects ?? [] }
    set { projects = newValue }
  }
}

enum LibrarySelection: Hashable {
  case all
  case video
  case audio
  case collection(UUID)
  case project(UUID)
  case folder(String)
}

struct FolderNode: Identifiable {
  var path: String
  var children: [FolderNode]?
  var id: String { path }
  var name: String { URL(fileURLWithPath: path).lastPathComponent }

  static func tree(root: String, folders: [String]) -> FolderNode {
    let prefix = root.hasSuffix("/") ? root : root + "/"
    let names = Set(
      folders.filter { $0.hasPrefix(prefix) }.compactMap { path in
        path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
      }
    ).sorted()
    let children = names.map { tree(root: prefix + $0, folders: folders) }
    return FolderNode(path: root, children: children.isEmpty ? nil : children)
  }
}

enum AppPaths {
  static var support: URL {
    if let path = ProcessInfo.processInfo.environment["VIDLIB_DATA_DIR"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Vidlib", isDirectory: true)
  }
  static var defaultCache: URL {
    if let path = ProcessInfo.processInfo.environment["VIDLIB_CACHE_DIR"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Vidlib", isDirectory: true)
  }
  static var lutDirectory: URL { support.appendingPathComponent("LUTs", isDirectory: true) }
}
