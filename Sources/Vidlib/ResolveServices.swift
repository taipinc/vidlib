import Foundation

struct ResolveSendRequest: Sendable {
  var projectID: UUID
  var projectName: String
  var targetName: String
  var createNew: Bool
  var urls: [URL]

  /// Byte escapes prevent paths and project names from becoming executable Lua.
  static func literal(_ value: String) -> String {
    "\"" + value.utf8.map { String(format: "\\%03d", Int($0)) }.joined() + "\""
  }

  var script: String {
    let paths = Array(Set(urls.map { $0.standardizedFileURL.path })).sorted()
      .map(Self.literal).joined(separator: ",\n")
    return """
      local function send()
        local resolve = bmd.scriptapp('Resolve')
        assert(resolve, 'Open Resolve Studio and enable Preferences > System > General > External scripting using: Local.')
        local manager = resolve:GetProjectManager()
        local target = \(Self.literal(targetName))
        local project
        if \(createNew ? "true" : "false") then
          project = manager:CreateProject(target)
          assert(project, 'Could not create project. The name may already exist in the current Resolve project-library folder.')
        else
          project = manager:GetCurrentProject()
          assert(project and project:GetName() == target, 'Open the named project in Resolve first. Nothing was imported.')
        end
        local pool = project:GetMediaPool()
        local root = pool:GetRootFolder()
        local seen = {}
        local function visit(folder)
          for _, clip in ipairs(folder:GetClipList() or {}) do
            local path = clip:GetClipProperty('File Path')
            if path and path ~= '' then seen[path] = true end
          end
          for _, child in ipairs(folder:GetSubFolderList() or {}) do visit(child) end
        end
        visit(root)
        local binName = \(Self.literal("Vidlib · " + projectName + " [" + projectID.uuidString + "]"))
        local bin
        for _, folder in ipairs(root:GetSubFolderList() or {}) do
          if folder:GetName() == binName then bin = folder; break end
        end
        bin = bin or pool:AddSubFolder(root, binName)
        assert(bin, 'Could not create the Vidlib media bin.')
        local previous = pool:GetCurrentFolder()
        assert(pool:SetCurrentFolder(bin), 'Could not select the Vidlib media bin.')
        local imported, skipped, failed = 0, 0, 0
        local ok, message = pcall(function()
          for _, path in ipairs({\(paths)}) do
            assert(manager:GetCurrentProject():GetUniqueId() == project:GetUniqueId(), 'Resolve project changed during import; stopped.')
            if seen[path] then
              skipped = skipped + 1
            else
              local file = io.open(path, 'rb')
              if file then
                file:close()
                local items = pool:ImportMedia({path})
                if items and #items > 0 then
                  imported = imported + 1
                  seen[path] = true
                else failed = failed + 1 end
              else failed = failed + 1 end
            end
          end
        end)
        if previous then pool:SetCurrentFolder(previous) end
        assert(ok, message)
        print('VIDLIB_RESULT:' .. imported .. ':' .. skipped .. ':' .. failed)
      end
      local ok, message = pcall(send)
      if not ok then print('VIDLIB_ERROR:' .. tostring(message)) end
      """
  }
}

struct ResolveSendResult: Equatable {
  var imported: Int
  var skipped: Int
  var failed: Int
  var message: String {
    "\(imported) imported · \(skipped) already in project · \(failed) unavailable or unsupported. Save your project in Resolve."
  }

  static func parse(_ output: String) throws -> Self {
    for line in output.components(separatedBy: .newlines) {
      if line.hasPrefix("VIDLIB_RESULT:") {
        let values = line.dropFirst("VIDLIB_RESULT:".count).split(separator: ":").compactMap {
          Int($0)
        }
        if values.count == 3 {
          return Self(imported: values[0], skipped: values[1], failed: values[2])
        }
      }
      if line.hasPrefix("VIDLIB_ERROR:") {
        throw ResolveService.failure(String(line.dropFirst("VIDLIB_ERROR:".count)))
      }
    }
    throw ResolveService.failure(
      "Resolve did not return an import result. Open Resolve Studio and enable local external scripting, then retry. Some files may already have imported; retries check for duplicates."
    )
  }
}

enum ResolveService {
  static func failure(_ message: String) -> NSError {
    NSError(domain: "Vidlib.Resolve", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  static func send(_ request: ResolveSendRequest) async throws -> ResolveSendResult {
    try await Task.detached(priority: .userInitiated) {
      let executable = URL(
        fileURLWithPath:
          "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript")
      guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw failure(
          "Resolve’s scripting interpreter was not found. Install DaVinci Resolve Studio in /Applications/DaVinci Resolve."
        )
      }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let script = directory.appendingPathComponent("send.lua")
      try request.script.write(to: script, atomically: true, encoding: .utf8)
      let output = directory.appendingPathComponent("result.txt")
      FileManager.default.createFile(atPath: output.path, contents: nil)
      let handle = try FileHandle(forWritingTo: output)
      defer { try? handle.close() }
      let process = Process()
      process.executableURL = executable
      process.arguments = ["-l", "lua", script.path]
      process.standardOutput = handle
      process.standardError = handle
      try process.run()
      let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
      DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
      process.waitUntilExit()
      timeout.cancel()
      return try ResolveSendResult.parse(String(contentsOf: output, encoding: .utf8))
    }.value
  }
}
