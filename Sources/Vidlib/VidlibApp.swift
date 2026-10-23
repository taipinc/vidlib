import AppKit
import SwiftUI

@main
struct VidlibApp: App {
  @StateObject private var library = LibraryModel()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  var body: some Scene {
    WindowGroup {
      LibraryView().environmentObject(library)
        .frame(minWidth: 1040, minHeight: 660)
        .preferredColorScheme(.dark)
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in library.save() }
    }
    .defaultSize(width: 1380, height: 860)
    .commands {
      CommandGroup(after: .newItem) {
        Button("Add Media Folder…", action: library.addFolder).keyboardShortcut("o")
        Button("Refresh Folders", action: library.rescan).keyboardShortcut("r")
          .disabled(library.importing || library.catalog.roots.isEmpty)
        Button("Import LUT…", action: library.importLUT).keyboardShortcut(
          "l", modifiers: [.command, .shift])
      }
    }
    Settings { AppSettingsView().environmentObject(library) }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
