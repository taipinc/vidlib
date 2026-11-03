import SwiftUI

struct AppSettingsView: View {
  var body: some View {
    TabView {
      CacheSettingsView().tabItem { Label("Cache", systemImage: "internaldrive") }
      LibrarySettingsView().tabItem { Label("Library", systemImage: "photo.stack") }
    }.padding(12).frame(width: 650, height: 485)
  }
}

private struct LibrarySettingsView: View {
  @State private var showLUTs = false
  @State private var showFolders = false
  var body: some View {
    Form {
      Section("Catalog Management") {
        LabeledContent("LUTs") { Button("Manage LUTs…") { showLUTs = true } }
        LabeledContent("Source folders") { Button("Manage Folders…") { showFolders = true } }
        Text(
          "Source folders are checked manually with Refresh. Removing a folder removes its catalog entries and collection/project memberships; original files stay in place."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped)
      .sheet(isPresented: $showLUTs) { LUTManagementView() }
      .sheet(isPresented: $showFolders) { FolderManagementView() }
  }
}

struct FolderManagementView: View {
  @EnvironmentObject private var library: LibraryModel
  @Environment(\.dismiss) private var dismiss
  @State private var pendingRemoval: SourceFolder?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Manage Folders").font(.title2.weight(.semibold))
      Text(
        "These are the added folders included in manual Refresh. Separately added folders remain registered when another folder is removed."
      )
      .foregroundStyle(.secondary)
      ScrollView {
        VStack(spacing: 12) {
          ForEach(library.catalog.roots) { root in
            HStack(spacing: 12) {
              Image(systemName: "folder")
              VStack(alignment: .leading, spacing: 4) {
                Text(root.url.lastPathComponent).fontWeight(.medium)
                Text(root.url.path).font(.caption).foregroundStyle(.secondary).textSelection(
                  .enabled)
                Text("\(count(for: root)) catalog entries").font(.caption).foregroundStyle(
                  .secondary)
              }
              Spacer()
              Button("Remove…", role: .destructive) { pendingRemoval = root }.disabled(
                library.importing)
            }.padding(12).background(
              .quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
          }
          if library.catalog.roots.isEmpty {
            Text("No folders added.").foregroundStyle(.secondary).padding()
          }
        }
      }
      if library.importing {
        Text("Wait for the current import to finish before removing folders.").font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack {
        Text(
          "Removing entries also removes their saved catalog edits. Original media is never deleted."
        )
        .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 650, height: 440)
      .alert(
        "Remove Folder from Catalog?",
        isPresented: Binding(
          get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
        presenting: pendingRemoval
      ) { root in
        Button("Cancel", role: .cancel) { pendingRemoval = nil }
        Button("Remove", role: .destructive) {
          library.removeSourceFolder(id: root.id)
          pendingRemoval = nil
        }
      } message: { root in
        Text(
          "Remove “\(root.url.lastPathComponent)” and its \(count(for: root)) entries, including their saved edits and collection/project memberships? This folder will no longer be included in Refresh. Original files stay untouched."
        )
      }
  }
  private func count(for root: SourceFolder) -> Int {
    library.catalog.clips.filter { $0.rootID == root.id }.count
  }
}

struct LUTManagementView: View {
  @EnvironmentObject private var library: LibraryModel
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Manage LUTs").font(.title2.weight(.semibold))
      Text(
        "LUTs are copied into Vidlib’s support folder when imported. Renaming changes their display name and preserves every clip assignment."
      )
      .font(.callout).foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(spacing: 14) {
          ForEach(library.catalog.luts) { LUTNameRow(reference: $0) }
          if library.catalog.luts.isEmpty {
            Text("No LUTs imported yet.").foregroundStyle(.secondary).padding()
          }
        }
      }
      HStack {
        Button("Import LUT…", action: library.importLUTOnly)
        Button("Show Stored LUTs") { NSWorkspace.shared.open(AppPaths.lutDirectory) }
          .disabled(library.catalog.luts.isEmpty)
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 650, height: 420)
  }
}

private struct LUTNameRow: View {
  @EnvironmentObject private var library: LibraryModel
  let reference: LUTReference
  @State private var name = ""
  var body: some View {
    HStack {
      Image(systemName: "camera.filters").foregroundStyle(.secondary)
      TextField("LUT name", text: $name).textFieldStyle(.roundedBorder).onSubmit(rename)
      Button("Rename", action: rename).disabled(
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == reference.name)
    }.onAppear { name = reference.name }
  }
  private func rename() { library.renameLUT(id: reference.id, name: name) }
}

struct AudioWaveformView: View {
  @EnvironmentObject private var library: LibraryModel
  let clip: Clip
  @State private var image: NSImage?
  var body: some View {
    ZStack {
      Color.black
      if let image {
        Image(nsImage: image).resizable().scaledToFit().frame(
          maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
      }
    }.task(id: "\(clip.id)-\(library.cacheGeneration)") {
      image = nil
      let data = await library.thumbnails.thumbnail(clip: clip, lut: nil, lutID: nil)
      guard !Task.isCancelled else { return }
      image = data.flatMap(NSImage.init(data:))
    }
  }
}
