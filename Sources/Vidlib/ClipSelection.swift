import Foundation
import UniformTypeIdentifiers

struct ClipSelection {
  var ids: Set<UUID> = []
  var focusedID: UUID?
  var anchorID: UUID?

  mutating func select(
    _ id: UUID, orderedIDs: [UUID], extending: Bool = false, toggling: Bool = false
  ) {
    guard let end = orderedIDs.firstIndex(of: id) else { return }
    if extending, let anchorID, let start = orderedIDs.firstIndex(of: anchorID) {
      let range = Set(orderedIDs[min(start, end)...max(start, end)])
      ids = toggling ? ids.union(range) : range
      focusedID = id
    } else if toggling {
      if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
      focusedID = ids.contains(id) ? id : orderedIDs.first { ids.contains($0) }
      anchorID = id
    } else {
      ids = [id]
      focusedID = id
      anchorID = id
    }
  }

  mutating func retain(visibleIDs: [UUID]) {
    ids.formIntersection(visibleIDs)
    if let focusedID, !ids.contains(focusedID) {
      self.focusedID = visibleIDs.first { ids.contains($0) }
    }
    if let anchorID, !visibleIDs.contains(anchorID) { self.anchorID = focusedID }
  }
}

extension UTType {
  static let vidlibClips = UTType(exportedAs: "local.vidlib.clip-selection", conformingTo: .data)
}

struct ClipDragPayload: Codable {
  let ids: [UUID]

  var pasteboardString: String {
    "vidlib-clips:" + ((try? JSONEncoder().encode(self).base64EncodedString()) ?? "")
  }
  init(ids: [UUID]) { self.ids = ids }
  init?(pasteboardString: String) {
    guard pasteboardString.hasPrefix("vidlib-clips:"),
      let data = Data(base64Encoded: String(pasteboardString.dropFirst("vidlib-clips:".count))),
      let payload = try? JSONDecoder().decode(Self.self, from: data), !payload.ids.isEmpty
    else { return nil }
    self = payload
  }
}
