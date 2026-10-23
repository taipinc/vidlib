import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
  @EnvironmentObject private var library: LibraryModel
  @State private var showCollectionSheet = false
  @State private var collectionName = ""
  @State private var showCache = false
  @State private var showLUTs = false
  private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)]

  var body: some View {
    NavigationSplitView {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 5) {
            SidebarHeading("Library")
            SidebarLink(title: "All Media", image: "photo.stack", destination: .all)
            Button {
              showLUTs = true
            } label: {
              Label("Manage LUTs…", systemImage: "camera.filters").padding(8)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
          }
          VStack(alignment: .leading, spacing: 5) {
            SidebarHeading("Collections")
            ForEach(library.catalog.collections) { collection in
              CollectionRow(collection: collection)
            }
            Button {
              showCollectionSheet = true
            } label: {
              Label("New Collection", systemImage: "plus")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
          }
          VStack(alignment: .leading, spacing: 5) {
            SidebarHeading("Folders")
            ForEach(library.folderTree) { FolderSidebarRow(node: $0) }
            if library.catalog.roots.isEmpty {
              Text("No folders added").font(.caption).foregroundStyle(.secondary)
            }
          }
        }.padding(12)
      }
      .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
      .safeAreaInset(edge: .bottom) {
        VStack(alignment: .leading, spacing: 10) {
          Label("Originals stay untouched", systemImage: "lock.shield")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            Button {
              library.addFolder()
            } label: {
              Label("Add Folder", systemImage: "plus")
            }
            .disabled(library.importing)
            Button(action: library.rescan) { Image(systemName: "arrow.clockwise") }
              .disabled(library.importing || library.catalog.roots.isEmpty)
              .help("Refresh: find new media in all added folders and subfolders")
            Spacer()
            Button {
              showCache = true
            } label: {
              Image(systemName: "gearshape")
            }
            .help("Cache settings")
          }
        }.padding()
      }
    } detail: {
      HSplitView {
        VStack(spacing: 0) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(library.selectionTitle).font(.title2).fontWeight(.semibold)
              Text(
                "\(library.visibleClips.count) files"
                  + (library.selectedIDs.isEmpty ? "" : " · \(library.selectedIDs.count) selected")
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
              Button("Recording date · newest first") { library.sortByDate = true }
              Button("Filename · A–Z") { library.sortByDate = false }
            } label: {
              Image(systemName: "arrow.up.arrow.down")
            }.menuStyle(.borderlessButton).frame(width: 30)
          }.padding(20)
          Divider()
          if library.catalog.clips.isEmpty {
            ContentUnavailableView {
              Label("Your media library", systemImage: "photo.stack")
            } description: {
              Text(
                "Add a folder from your Mac or mounted NAS.\nVideo and audio stay exactly where they are."
              )
            } actions: {
              Button("Add Media Folder…", action: library.addFolder).disabled(library.importing)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if library.visibleClips.isEmpty {
            ContentUnavailableView(
              "No media here", systemImage: "magnifyingglass",
              description: Text(
                "Try a different search, or add files to this collection from All Media.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ScrollView {
              LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(library.visibleClips) { clip in
                  ClipCard(clip: clip, selected: library.selectedIDs.contains(clip.id))
                    .onTapGesture { library.select(clip, modifiers: NSEvent.modifierFlags) }
                    .onDrag {
                      let payload = library.dragPayload(for: clip)
                      let data = (try? JSONEncoder().encode(payload)) ?? Data()
                      let provider = NSItemProvider(object: payload.pasteboardString as NSString)
                      provider.registerDataRepresentation(
                        forTypeIdentifier: UTType.vidlibClips.identifier, visibility: .all
                      ) { completion in
                        completion(data, nil)
                        return nil
                      }
                      return provider
                    } preview: {
                      Label(
                        "\(library.dragPayload(for: clip).ids.count) files",
                        systemImage: "photo.stack"
                      )
                      .padding(12).background(
                        .regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .contextMenu {
                      Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([clip.url])
                      }
                      Menu("Add to Collection") {
                        ForEach(library.catalog.collections) { collection in
                          Button(collection.name) {
                            if !library.selectedIDs.contains(clip.id) { library.select(clip) }
                            library.addSelected(to: collection.id)
                          }
                        }
                      }.disabled(library.catalog.collections.isEmpty)
                    }
                }
              }.padding(20)
            }
          }
          Divider()
          HStack(spacing: 8) {
            if library.importing {
              ProgressView().controlSize(.small)
              Text(library.importStatus).lineLimit(1)
              Spacer()
              Button("Stop", action: library.cancelImport)
            } else {
              Text("\(library.catalog.clips.count) cataloged · Files referenced in place")
              Spacer()
              Button("Refresh", action: library.rescan).disabled(library.catalog.roots.isEmpty)
            }
          }.font(.caption).foregroundStyle(.secondary).padding(12)
        }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        ViewerPane(controller: library.playback)
          .frame(minWidth: 360, idealWidth: 490, maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .navigationTitle(
        ProcessInfo.processInfo.environment["VIDLIB_DATA_DIR"] == nil
          ? "Vidlib" : "Vidlib · Test Catalog"
      )
      .searchable(text: $library.search, prompt: "Search names, tags, folders")
    }
    .sheet(isPresented: $showCollectionSheet) {
      VStack(alignment: .leading, spacing: 16) {
        Text("New Collection").font(.headline)
        TextField("Collection name", text: $collectionName).onSubmit(createCollection)
        HStack {
          Spacer()
          Button("Cancel") { showCollectionSheet = false }.keyboardShortcut(.cancelAction)
          Button("Create", action: createCollection).keyboardShortcut(.defaultAction)
            .disabled(collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }.padding(24).frame(width: 360)
    }
    .sheet(isPresented: $showCache) {
      VStack(alignment: .trailing) {
        CacheSettingsView()
        Button("Done") { showCache = false }.keyboardShortcut(.defaultAction).padding(
          [.horizontal, .bottom], 20)
      }
    }
    .sheet(isPresented: $showLUTs) { LUTManagementView().environmentObject(library) }
    .alert(
      "Vidlib",
      isPresented: Binding(
        get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })
    ) {
      Button("OK") { library.errorMessage = nil }
    } message: {
      Text(library.errorMessage ?? "")
    }
  }
  private func createCollection() {
    library.createCollection(name: collectionName)
    collectionName = ""
    showCollectionSheet = false
  }
}

struct SidebarHeading: View {
  let title: String
  init(_ title: String) { self.title = title }
  var body: some View {
    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
  }
}

struct SidebarLink: View {
  @EnvironmentObject private var library: LibraryModel
  let title: String
  let image: String
  let destination: LibrarySelection
  var body: some View {
    Button {
      library.selection = destination
    } label: {
      Label(title, systemImage: image).lineLimit(1).padding(8).frame(
        maxWidth: .infinity, alignment: .leading
      )
      .contentShape(Rectangle())
    }.buttonStyle(.plain)
      .background(
        library.selection == destination ? Color.accentColor.opacity(0.35) : .clear,
        in: RoundedRectangle(cornerRadius: 6))
  }
}

struct FolderSidebarRow: View {
  let node: FolderNode
  @State private var expanded = false
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 2) {
        if node.children != nil {
          Button {
            expanded.toggle()
          } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(
              width: 12)
          }.buttonStyle(.plain)
        }
        SidebarLink(title: node.name, image: "folder", destination: .folder(node.path)).help(
          node.path)
      }
      if expanded, let children = node.children {
        ForEach(children) { FolderSidebarRow(node: $0) }.padding(.leading, 12)
      }
    }
  }
}

struct CollectionRow: View {
  @EnvironmentObject private var library: LibraryModel
  let collection: ClipCollection
  var body: some View {
    CollectionDropTarget(
      name: collection.name, count: collection.clipIDs.count,
      selected: library.selection == .collection(collection.id),
      select: { library.selection = .collection(collection.id) },
      accepts: { ids in !ids.isDisjoint(with: library.catalog.clips.map(\.id)) },
      drop: { library.addClips($0, to: collection.id) }
    ).frame(maxWidth: .infinity).frame(height: 34)
  }
}

struct ClipCard: View {
  @EnvironmentObject private var library: LibraryModel
  let clip: Clip
  let selected: Bool
  @State private var image: NSImage?
  @State private var finished = false
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ZStack {
        Rectangle().fill(Color.black.opacity(0.45))
        if let image {
          Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
          Image(systemName: clip.isAudio ? "waveform" : finished ? "video.slash" : "film")
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        Text(clip.durationLabel).font(.caption2.monospacedDigit())
          .padding(.horizontal, 5).padding(.vertical, 3).background(
            .black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3)
          ).padding(6)
      }
      .aspectRatio(16 / 9, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 5))
      .overlay(
        RoundedRectangle(cornerRadius: 5).stroke(
          selected ? Color.accentColor : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1))
      HStack(spacing: 4) {
        Text(clip.displayTitle).lineLimit(1).font(.system(size: 12, weight: .medium))
        Spacer(minLength: 0)
        if clip.isAudio {
          Image(systemName: "waveform").font(.caption).foregroundStyle(.secondary)
        } else if clip.lutID != nil {
          Image(systemName: "camera.filters").font(.caption).foregroundStyle(.secondary)
        }
      }
      Text(clip.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Date unknown")
        .font(.caption2).foregroundStyle(.secondary)
    }
    .padding(5)
    .background(
      selected ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7)
    )
    .contentShape(Rectangle())
    .help(clip.url.path)
    .task(id: "\(clip.id)-\(clip.lutID?.uuidString ?? "none")-\(library.cacheGeneration)") {
      finished = false
      let data = await library.thumbnails.thumbnail(
        clip: clip, lut: library.lut(for: clip), lutID: clip.lutID)
      guard !Task.isCancelled else { return }
      image = data.flatMap(NSImage.init(data:))
      finished = true
    }
  }
}

struct ViewerPane: View {
  @EnvironmentObject private var library: LibraryModel
  @ObservedObject var controller: PlaybackController
  @State private var tags = ""
  @State private var title = ""
  @State private var description = ""
  @State private var gainDB: Double = 0
  var body: some View {
    GeometryReader { geometry in
      VStack(alignment: .leading, spacing: 0) {
        if let clip = library.selectedClip {
          HStack {
            Text(clip.displayTitle).font(.headline).lineLimit(1)
            Spacer()
            if library.selectedIDs.count > 1 {
              Text("\(library.selectedIDs.count) selected").font(.caption).foregroundStyle(
                .secondary)
            }
            Button {
              NSWorkspace.shared.activateFileViewerSelecting([clip.url])
            } label: {
              Image(systemName: "arrow.up.right.square")
            }
            .help("Show in Finder")
          }.padding(16)
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              ZStack {
                Color.black
                if clip.isAudio {
                  AudioWaveformView(clip: clip)
                  NativeVideoPlayer(player: controller.player).frame(height: 70).frame(
                    maxHeight: .infinity, alignment: .bottom)
                } else {
                  NativeVideoPlayer(player: controller.player)
                }
                if controller.loading {
                  ProgressView("Opening video…").padding().background(
                    .regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                if let error = controller.error {
                  VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.title)
                    Text(error).font(.callout).multilineTextAlignment(.center)
                    Button("Retry", action: library.updatePlayback)
                  }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(
                    .black.opacity(0.9))
                }
              }
              .frame(width: geometry.size.width, height: geometry.size.width / aspectRatio(clip))
              VStack(alignment: .leading, spacing: 20) {
                if library.selectedIDs.count == 1 {
                  VStack(alignment: .leading, spacing: 10) {
                    Text("Title & Description").font(.headline)
                    TextField("Title (defaults to filename)", text: $title).textFieldStyle(
                      .roundedBorder)
                    TextField("Description", text: $description, axis: .vertical).lineLimit(3...8)
                      .textFieldStyle(.roundedBorder)
                    Button("Save Details") {
                      library.setDetails(title: title, description: description)
                    }
                  }
                  Divider()
                }
                if !library.selectedVideos.isEmpty {
                  VStack(alignment: .leading, spacing: 10) {
                    Text(
                      library.selectedVideos.count > 1
                        ? "LUT · \(library.selectedVideos.count) Selected Videos" : "LUT Preview"
                    ).font(.headline)
                    Picker(
                      "LUT",
                      selection: Binding<String>(
                        get: {
                          library.hasMixedLUTs ? "mixed" : library.commonLUT?.uuidString ?? "none"
                        },
                        set: { value in
                          if value != "mixed" { library.setLUT(UUID(uuidString: value)) }
                        })
                    ) {
                      if library.hasMixedLUTs { Text("Mixed LUTs").tag("mixed") }
                      Text("None · Original").tag("none")
                      ForEach(library.catalog.luts) { Text($0.name).tag($0.id.uuidString) }
                    }.labelsHidden()
                    HStack {
                      Button("Import .cube…", action: library.importLUT)
                      Spacer()
                      Toggle("Bypass Preview", isOn: $library.bypassLUT).toggleStyle(.checkbox)
                        .disabled(clip.lutID == nil).onChange(of: library.bypassLUT) {
                          library.updatePlayback()
                        }
                    }
                    Text(
                      "Choose a LUT matching the recorded gamma and gamut. Camera profile detection is manual in this version."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                  }
                  Divider()
                }
                if !library.selectedAudio.isEmpty {
                  VStack(alignment: .leading, spacing: 10) {
                    Text("Audio Preview Gain").font(.headline)
                    HStack {
                      TextField(
                        "Gain (dB)", value: $gainDB, format: .number.precision(.fractionLength(1))
                      ).textFieldStyle(.roundedBorder).frame(width: 100)
                      Text("dB")
                      Button("Apply Gain") { library.setAudioGain(gainDB) }
                      Button("Reset") {
                        gainDB = 0
                        library.setAudioGain(0)
                      }
                    }
                    HStack {
                      Button(
                        library.analyzingAudio ? "Analyzing…" : "Peak Normalize to −1 dBFS",
                        action: library.normalizeAudio
                      )
                      .disabled(library.analyzingAudio)
                      if library.analyzingAudio { ProgressView().controlSize(.small) }
                    }
                    Text(
                      "Applied to \(library.selectedAudio.count) selected audio file(s). Gain is saved in the catalog and used for playback only. Peak normalization scans the full recording; it is not loudness normalization. Waveforms are scaled to each recording’s own peak."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Text(
                      library.selectedAudio.map {
                        "\($0.displayTitle): \(String(format: "%+.1f", $0.playbackGainDB)) dB"
                      }.joined(separator: "\n")
                    )
                    .font(.caption).foregroundStyle(.secondary).lineLimit(4)
                  }
                  Divider()
                }
                VStack(alignment: .leading, spacing: 10) {
                  Text("Organization").font(.headline)
                  TextField(
                    library.selectedIDs.count > 1
                      ? "Add tags to selected files" : "Tags, separated by commas", text: $tags
                  )
                  .textFieldStyle(.roundedBorder).onSubmit { library.setTags(tags) }
                  HStack {
                    Text(
                      library.selectedIDs.count > 1
                        ? "Adds tags to every selected file" : "Press Return to save tags"
                    ).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { library.setTags(tags) }.controlSize(.small)
                  }
                  Menu(
                    library.selectedIDs.count > 1
                      ? "Add \(library.selectedIDs.count) Files to Collection" : "Add to Collection"
                  ) {
                    ForEach(library.catalog.collections) { collection in
                      Button(collection.name) { library.addSelected(to: collection.id) }
                    }
                  }.disabled(library.catalog.collections.isEmpty)
                  if case .collection(let id) = library.selection,
                    let collection = library.catalog.collections.first(where: { $0.id == id }),
                    !collection.clipIDs.isDisjoint(with: library.selectedIDs)
                  {
                    Button(
                      "Remove from This Collection", action: library.removeSelectedFromCollection)
                  }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                  Text("File Details").font(.headline)
                  LabeledContent("Filename", value: clip.name)
                  if !clip.isAudio {
                    LabeledContent(
                      "Resolution",
                      value: clip.width > 0 ? "\(clip.width) × \(clip.height)" : "Unknown")
                  }
                  LabeledContent("Duration", value: clip.durationLabel)
                  LabeledContent(
                    "Date",
                    value: clip.date.map { $0.formatted(date: .abbreviated, time: .shortened) }
                      ?? "Unknown")
                  Text(clip.dateSource).font(.caption).foregroundStyle(.secondary)
                  Text(clip.url.path).font(.caption).foregroundStyle(.secondary).textSelection(
                    .enabled
                  ).fixedSize(horizontal: false, vertical: true)
                  if let issue = clip.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                }.font(.callout)
              }.padding(20)
            }
          }
        } else {
          ContentUnavailableView(
            "Select a file", systemImage: "play.rectangle",
            description: Text("Preview and organize video or audio here.")
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(Color(nsColor: .underPageBackgroundColor))
      .onChange(of: library.selectedIDs) { refreshTags() }
      .onChange(of: library.selectedID) { refreshTags() }
      .onChange(of: library.selectedClip?.gainDB) {
        gainDB = library.selectedClip?.playbackGainDB ?? 0
      }
      .onAppear { refreshTags() }
    }
  }
  private func refreshTags() {
    tags =
      library.selectedIDs.count == 1 ? library.selectedClip?.tags.joined(separator: ", ") ?? "" : ""
    title = library.selectedClip?.title ?? ""
    description = library.selectedClip?.notes ?? ""
    gainDB = library.selectedClip?.playbackGainDB ?? 0
  }
  private func aspectRatio(_ clip: Clip) -> CGFloat {
    clip.width > 0 && clip.height > 0 ? CGFloat(clip.width) / CGFloat(clip.height) : 16 / 9
  }
}

/// Use AVKit's AppKit view directly. The SwiftUI VideoPlayer bridge crashes
/// during generic class metadata initialization on the development OS/toolchain.
struct NativeVideoPlayer: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .inline
    view.videoGravity = .resizeAspect
    view.allowsPictureInPicturePlayback = false
    view.showsFullScreenToggleButton = true
    view.player = player
    return view
  }

  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== player { view.player = player }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize?
  {
    proposal.replacingUnspecifiedDimensions()
  }

  static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

struct CacheSettingsView: View {
  @EnvironmentObject private var library: LibraryModel
  var body: some View {
    Form {
      Section("Local Cache") {
        LabeledContent("Location") {
          VStack(alignment: .trailing, spacing: 6) {
            Text(library.cacheURL.path).font(.caption).textSelection(.enabled)
            Button("Choose…", action: library.chooseCacheLocation)
          }
        }
        Picker("Disk limit", selection: $library.cacheLimitGB) {
          ForEach([1.0, 2, 5, 10, 20, 50], id: \.self) { Text("\(Int($0)) GB").tag($0) }
        }.onChange(of: library.cacheLimitGB) { library.configureCache() }
        LabeledContent(
          "Thumbnail usage",
          value: ByteCountFormatter.string(fromByteCount: library.cacheBytes, countStyle: .file))
        HStack {
          Button("Refresh Usage", action: library.refreshCacheUsage)
          Spacer()
          Button("Clear Thumbnails", action: library.clearCache)
        }
        Text(
          "Only generated thumbnails are cached in this version. Oldest used thumbnails are removed when the limit is reached. Changing location leaves the old cache in place. Tags, collections, and LUTs are stored separately and are never evicted."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Original Files") {
        Label("Referenced in place · No media copies or proxies", systemImage: "lock.shield")
        Text(
          "NAS folders must be mounted in Finder. Wi-Fi playback depends on your connection; local thumbnails remain available when the NAS is offline."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped).frame(width: 570, height: 430)
      .onAppear { library.refreshCacheUsage() }
  }
}
