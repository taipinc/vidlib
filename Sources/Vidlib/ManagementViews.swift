import SwiftUI

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
