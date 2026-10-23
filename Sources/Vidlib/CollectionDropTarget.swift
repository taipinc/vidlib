import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A native drag destination avoids SwiftUI sidebar/button drop interception.
struct CollectionDropTarget: NSViewRepresentable {
  let name: String
  let count: Int
  let selected: Bool
  let select: () -> Void
  let accepts: (Set<UUID>) -> Bool
  let drop: (Set<UUID>) -> Bool

  func makeNSView(context: Context) -> CollectionDropRow {
    let view = CollectionDropRow()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: CollectionDropRow, context: Context) {
    view.name = name
    view.count = count
    view.selected = selected
    view.select = select
    view.accepts = accepts
    view.drop = drop
    view.setAccessibilityLabel("\(name), \(count) files")
    view.needsDisplay = true
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: CollectionDropRow, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 180, height: 34)
  }
}

final class CollectionDropRow: NSView {
  var name = ""
  var count = 0
  var selected = false
  var select: () -> Void = {}
  var accepts: (Set<UUID>) -> Bool = { _ in false }
  var drop: (Set<UUID>) -> Bool = { _ in false }
  private var targeted = false { didSet { needsDisplay = true } }
  private let pasteboardType = NSPasteboard.PasteboardType(UTType.vidlibClips.identifier)

  init() {
    super.init(frame: .zero)
    registerForDraggedTypes([pasteboardType, .string])
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 34) }
  override func mouseDown(with event: NSEvent) { select() }
  override func accessibilityPerformPress() -> Bool {
    select()
    return true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    if selected || targeted {
      NSColor.controlAccentColor.withAlphaComponent(targeted ? 0.55 : 0.35).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    if targeted {
      NSColor.controlAccentColor.setStroke()
      let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
      outline.lineWidth = 2
      outline.stroke()
    }
    NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))?
      .draw(in: NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16))
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
    ]
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    var titleAttributes = attributes
    titleAttributes[.paragraphStyle] = paragraph
    (name as NSString).draw(
      in: NSRect(x: 32, y: (bounds.height - 18) / 2, width: max(0, bounds.width - 72), height: 18),
      withAttributes: titleAttributes)
    let number = "\(count)" as NSString
    let size = number.size(withAttributes: attributes)
    number.draw(
      at: NSPoint(x: bounds.width - size.width - 8, y: (bounds.height - size.height) / 2),
      withAttributes: attributes)
  }

  private func ids(from sender: NSDraggingInfo) -> Set<UUID>? {
    if let data = sender.draggingPasteboard.data(forType: pasteboardType),
      let payload = try? JSONDecoder().decode(ClipDragPayload.self, from: data),
      !payload.ids.isEmpty
    {
      return Set(payload.ids)
    }
    if let string = sender.draggingPasteboard.string(forType: .string),
      let payload = ClipDragPayload(pasteboardString: string)
    {
      return Set(payload.ids)
    }
    return nil
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    targeted = ids(from: sender).map(accepts) ?? false
    return targeted ? .copy : []
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingEntered(sender)
  }
  override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    ids(from: sender).map(accepts) ?? false
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { targeted = false }
    guard let ids = ids(from: sender), accepts(ids) else { return false }
    return drop(ids)
  }
  override func concludeDragOperation(_ sender: NSDraggingInfo?) { targeted = false }
}
