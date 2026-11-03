import SwiftUI

struct ProjectDraft: Identifiable {
  let id = UUID()
  let ids: Set<UUID>
}

struct NewEditingProjectView: View {
  @EnvironmentObject private var library: LibraryModel
  @Environment(\.dismiss) private var dismiss
  let clipIDs: Set<UUID>
  @State private var name = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Project").font(.headline)
      TextField("Project name", text: $name).onSubmit(create)
      if !clipIDs.isEmpty {
        Text("Add \(clipIDs.count) selected files.").foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Create", action: create).keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 380)
  }
  private func create() {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    library.createProject(name: name, clipIDs: clipIDs)
    dismiss()
  }
}

struct ProjectMembershipMenu: View {
  @EnvironmentObject private var library: LibraryModel
  let ids: Set<UUID>
  var createProject: (() -> Void)? = nil
  @State private var draft: ProjectDraft?
  var body: some View {
    Menu("Add to Project") {
      Button("New Project…") {
        if let createProject { createProject() } else { draft = ProjectDraft(ids: ids) }
      }
      ForEach(library.catalog.editingProjects) { project in
        Button(project.name) { library.addClips(ids, toProject: project.id) }
      }
    }
    .sheet(item: $draft) { NewEditingProjectView(clipIDs: $0.ids) }
  }
}

struct ResolveSendView: View {
  @EnvironmentObject private var library: LibraryModel
  @Environment(\.dismiss) private var dismiss
  let project: EditingProject
  let selectedIDs: Set<UUID>
  @State private var targetName = ""
  @State private var createNew = false
  @State private var selectedOnly = false
  @State private var sending = false
  @State private var result: String?
  @State private var completed = false
  private var clips: [Clip] {
    library.catalog.clips.filter {
      project.clipIDs.contains($0.id) && (!selectedOnly || selectedIDs.contains($0.id))
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Send to Resolve").font(.title2.weight(.semibold))
      Text(project.name).foregroundStyle(.secondary)
      Picker("Destination", selection: $createNew) {
        Text("Currently open project").tag(false)
        Text("Create new project").tag(true)
      }
      TextField("Resolve project name (exact)", text: $targetName).textFieldStyle(.roundedBorder)
      Text(
        createNew
          ? "Creates a project in Resolve’s current project-library folder. Save your current work in Resolve before sending."
          : "Open the destination in Resolve first. Its name must match exactly; Vidlib checks before importing."
      )
      .font(.caption).foregroundStyle(.secondary)
      Picker("Media", selection: $selectedOnly) {
        Text("Entire Vidlib project").tag(false)
        Text("Selected project files").tag(true)
      }
      Text("\(clips.count) originals · existing paths in the Resolve media pool are skipped.")
      Text(
        "Requires Resolve Studio running with Preferences → System → General → External scripting using: Local. Imports media references into a Vidlib bin. Titles, tags, rotation, LUTs, gain, and proxy assignments stay in Vidlib. No ongoing sync."
      )
      .font(.caption).foregroundStyle(.secondary)
      if let result { Text(result).textSelection(.enabled) }
      HStack {
        if sending {
          ProgressView().controlSize(.small)
          Text("Sending…")
        }
        Spacer()
        Button(completed ? "Done" : "Cancel") { dismiss() }.disabled(sending)
          .keyboardShortcut(.cancelAction)
        Button("Send", action: send).disabled(
          sending || completed || clips.isEmpty
            || targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 530)
      .disabled(sending)
      .interactiveDismissDisabled(sending)
      .onAppear {
        targetName = project.resolveProjectName ?? project.name
        selectedOnly = !selectedIDs.intersection(project.clipIDs).isEmpty
      }
  }
  private func send() {
    let name = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
    let request = ResolveSendRequest(
      projectID: project.id, projectName: project.name,
      targetName: name, createNew: createNew, urls: clips.map(\.url))
    sending = true
    result = nil
    Task {
      defer { sending = false }
      do {
        let response = try await ResolveService.send(request)
        library.rememberResolveTarget(name, projectID: project.id)
        result = response.message
        // A partially successful new project must be retried as an existing project.
        createNew = false
        completed = response.failed == 0
      } catch {
        result = error.localizedDescription
        createNew = false
      }
    }
  }
}
