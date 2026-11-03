import XCTest

@testable import Vidlib

final class ProjectTests: XCTestCase {
  func testOlderSnapshotDecodesWithoutProjectsOrRotation() throws {
    let clip = Clip(url: URL(fileURLWithPath: "/synthetic/Shot.mov"), rootID: UUID())
    let snapshot = CatalogSnapshot(
      clips: [clip], collections: [ClipCollection(name: "Keep", clipIDs: [clip.id])])
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
    object.removeValue(forKey: "projects")
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(CatalogSnapshot.self, from: data)
    XCTAssertTrue(decoded.editingProjects.isEmpty)
    XCTAssertNil(decoded.clips[0].rotation)
    XCTAssertEqual(decoded.clips[0].id, clip.id)
    XCTAssertEqual(decoded.collections[0].clipIDs, [clip.id])
  }

  @MainActor
  func testProjectsMembershipSearchPersistenceAndSourceRemoval() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = SourceFolder(url: dir.appendingPathComponent("Media"))
    try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
    let original = root.url.appendingPathComponent("Shot.mov")
    let bytes = Data("synthetic source".utf8)
    try bytes.write(to: original)
    let video = Clip(url: original, rootID: root.id)
    let audio = Clip(url: root.url.appendingPathComponent("Sound.wav"), rootID: root.id)
    let proxy = Clip(url: root.url.appendingPathComponent("Proxy/Shot.mov"), rootID: root.id)
    let db = dir.appendingPathComponent("Catalog/catalog.sqlite")
    let model = LibraryModel(catalogURL: db, cacheDirectory: dir.appendingPathComponent("Cache"))
    model.catalog = CatalogSnapshot(clips: [video, audio, proxy], roots: [root])
    model.createProject(name: " Cut ", clipIDs: [video.id, UUID()])
    let id = try XCTUnwrap(model.catalog.editingProjects.first?.id)
    XCTAssertEqual(model.selection, .project(id))
    XCTAssertEqual(model.visibleClips.map(\.id), [video.id])
    XCTAssertEqual(model.selectionTitle, "Cut")
    XCTAssertFalse(model.addClips([UUID()], toProject: id))
    XCTAssertTrue(model.addClips([audio.id, proxy.id, video.id], toProject: id))
    XCTAssertEqual(model.catalog.editingProjects[0].clipIDs.count, 3)
    await model.refreshProxies()
    XCTAssertEqual(model.catalog.editingProjects[0].clipIDs, [video.id, audio.id])
    model.search = "Sound"
    XCTAssertEqual(model.visibleClips.map(\.id), [audio.id])
    model.search = ""
    model.gridSelection = ClipSelection(ids: [video.id], focusedID: video.id)
    model.setRotation(.clockwise90)
    model.playback.show(nil, lut: nil)
    model.rememberResolveTarget("Resolve Cut", projectID: id)
    let saved = try CatalogStore(url: db).load()
    XCTAssertEqual(saved.clips.first?.rotation, .clockwise90)
    XCTAssertEqual(saved.editingProjects[0].resolveProjectName, "Resolve Cut")
    model.gridSelection = ClipSelection(ids: [audio.id], focusedID: audio.id)
    model.setRotation(.halfTurn)
    XCTAssertNil(model.catalog.clips.first { $0.id == audio.id }?.rotation)
    model.removeSelectedFromProject()
    XCTAssertEqual(model.catalog.editingProjects[0].clipIDs, [video.id])
    XCTAssertTrue(model.selectedIDs.isEmpty)
    XCTAssertTrue(model.removeSourceFolder(id: root.id))
    XCTAssertTrue(model.catalog.editingProjects[0].clipIDs.isEmpty)
    XCTAssertEqual(try Data(contentsOf: original), bytes)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.url.path), ["Shot.mov"])
  }

  func testResolveResultParsingReportsPartialFailures() throws {
    XCTAssertEqual(
      try ResolveSendResult.parse("banner\nVIDLIB_RESULT:2:1:3\n"),
      ResolveSendResult(imported: 2, skipped: 1, failed: 3))
    XCTAssertThrowsError(try ResolveSendResult.parse("VIDLIB_ERROR:Wrong project"))
    XCTAssertThrowsError(try ResolveSendResult.parse("interpreter stopped"))
  }

  func testResolveScriptImportsIncrementallyAndRejectsWrongTargetWithoutTouchingResolve() throws {
    let executable =
      "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript"
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      throw XCTSkip("Resolve Lua interpreter is not installed; no real Resolve project is used.")
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("quote\" and \\ slash 日本語.mov")
    try Data("synthetic source".utf8).write(to: url)
    let target = "Cut\"; error('injection') -- 日本語"
    var request = ResolveSendRequest(
      projectID: UUID(), projectName: target,
      targetName: target, createNew: false,
      urls: [url, url, dir.appendingPathComponent("offline.mov")])
    let harness = """
      local clips = {}
      local folder = {
        GetClipList = function() return clips end,
        GetSubFolderList = function() return {} end
      }
      local pool = {
        GetRootFolder = function() return folder end,
        GetCurrentFolder = function() return folder end,
        SetCurrentFolder = function() return true end,
        AddSubFolder = function() return folder end,
        ImportMedia = function(self, paths)
          assert(paths[1] == \(ResolveSendRequest.literal(url.path)))
          local clip = { GetClipProperty = function() return paths[1] end }
          table.insert(clips, clip)
          return {clip}
        end
      }
      local project = {
        GetName = function() return \(ResolveSendRequest.literal(target)) end,
        GetUniqueId = function() return 'synthetic-id' end,
        GetMediaPool = function() return pool end
      }
      local manager = {
        GetCurrentProject = function() return project end,
        CreateProject = function() return nil end
      }
      bmd = {scriptapp = function() return {GetProjectManager = function() return manager end} end}
      """
    var script = harness + "\n" + request.script + "\n" + request.script
    request.targetName = "Wrong project"
    script += "\n" + request.script
    request.createNew = true
    script += "\n" + request.script
    request.targetName = target
    script += """
      \nmanager.CreateProject = function(self, name)
        assert(name == \(ResolveSendRequest.literal(target)))
        clips = {}
        print('VIDLIB_CREATED')
        return project
      end
      """ + "\n" + request.script
    let scriptURL = dir.appendingPathComponent("mock.lua")
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["-l", "lua", scriptURL.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    XCTAssertTrue(output.contains("VIDLIB_RESULT:1:0:1"), output)
    XCTAssertTrue(output.contains("VIDLIB_RESULT:0:1:1"), output)
    XCTAssertTrue(output.contains("Open the named project"), output)
    XCTAssertTrue(output.contains("Could not create project"), output)
    XCTAssertTrue(output.contains("VIDLIB_CREATED"), output)
    XCTAssertEqual(output.components(separatedBy: "VIDLIB_RESULT:1:0:1").count - 1, 2, output)
    XCTAssertFalse(output.contains("injection\n"), output)
    XCTAssertEqual(try Data(contentsOf: url), Data("synthetic source".utf8))
  }
}
