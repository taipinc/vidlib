// Run after building: swift scripts/install-shortcut.swift [destination-folder]
import Foundation

do {
  let manager = FileManager.default
  let target = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("build/Vidlib.app", isDirectory: true).standardizedFileURL
  let applications =
    CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
  let destination = applications.appendingPathComponent("Vidlib.app")
  guard manager.fileExists(atPath: target.appendingPathComponent("Contents/Info.plist").path) else {
    throw CocoaError(
      .fileNoSuchFile,
      userInfo: [NSLocalizedDescriptionKey: "Build Vidlib before installing its shortcut."])
  }
  try manager.createDirectory(at: applications, withIntermediateDirectories: true)
  if manager.fileExists(atPath: destination.path) {
    let resolved = try? URL(
      resolvingAliasFileAt: destination, options: [.withoutUI, .withoutMounting])
    guard resolved?.standardizedFileURL == target else {
      throw CocoaError(
        .fileWriteFileExists,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Applications already contains a different Vidlib item; it was not replaced."
        ])
    }
  } else {
    let bookmark = try target.bookmarkData(
      options: .suitableForBookmarkFile,
      includingResourceValuesForKeys: nil, relativeTo: nil)
    try URL.writeBookmarkData(bookmark, to: destination)
  }
  let resolved = try URL(
    resolvingAliasFileAt: destination, options: [.withoutUI, .withoutMounting])
  guard resolved.standardizedFileURL == target,
    try destination.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true
  else {
    throw CocoaError(.fileReadCorruptFile)
  }
  print("Finder alias: \(destination.path) → \(resolved.path)")

} catch {
  FileHandle.standardError.write(
    Data(("Could not create shortcut: " + error.localizedDescription + "\n").utf8))
  exit(1)
}
