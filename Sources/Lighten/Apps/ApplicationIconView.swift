import AppKit
import SwiftUI

struct ApplicationIconView: View {
  let path: String
  var drawRevision = 0
  var onDraw: ((Bool) -> Void)?
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFit()
      } else {
        Image(systemName: "app.fill").font(.system(size: 22)).foregroundStyle(LightenStyle.muted)
      }
    }
    .frame(width: 32, height: 32)
    .background {
      if let onDraw {
        ApplicationIconDrawProbe(iconReady: image != nil, revision: drawRevision, onDraw: onDraw)
          .allowsHitTesting(false)
      }
    }
    .accessibilityHidden(true)
    .task(id: path) {
      image = nil
      let data = await ApplicationIconCache.shared.iconData(for: path)
      guard !Task.isCancelled, let data else { return }
      // The cache supplies one 64px PNG, never a lazy IconServices representation.
      image = NSImage(data: data)
    }
  }
}

/// Draw callbacks exclude LazyVStack's offscreen prefetch and backend publication.
private struct ApplicationIconDrawProbe: NSViewRepresentable {
  let iconReady: Bool
  let revision: Int
  let onDraw: (Bool) -> Void

  func makeNSView(context: Context) -> Probe { Probe() }

  func updateNSView(_ view: Probe, context: Context) {
    view.iconReady = iconReady
    view.onDraw = onDraw
    if view.revision != revision || view.lastDrawnReady != iconReady {
      view.revision = revision
      view.needsDisplay = true
    }
  }

  final class Probe: NSView {
    var iconReady = false
    var revision = -1
    var lastDrawnReady: Bool?
    var onDraw: ((Bool) -> Void)?
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
      guard window != nil, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
      lastDrawnReady = iconReady
      let ready = iconReady
      let callback = onDraw
      DispatchQueue.main.async { callback?(ready) }
    }
  }
}
