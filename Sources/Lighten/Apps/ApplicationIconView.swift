import AppKit
import SwiftUI

struct ApplicationIconView: View {
  let path: String
  var isVisible = true
  var size: CGFloat = Theme.Layout.appIcon
  @State private var image: NSImage?
  @State private var loadedPath: String?

  private struct Request: Hashable {
    let path: String
    let visible: Bool
  }

  var body: some View {
    Group {
      if let image, loadedPath == path {
        Image(nsImage: image).resizable().scaledToFit()
      } else {
        Image(systemName: "app.dashed").resizable().scaledToFit().padding(size * 0.12)
          .foregroundStyle(Theme.Palette.inkTertiary)
      }
    }
    .frame(width: size, height: size)
    .preference(
      key: ApplicationRowPreferenceKey.self, value: [path: .init(iconReady: image != nil && loadedPath == path)]
    )
    .accessibilityHidden(true)
    .task(id: Request(path: path, visible: isVisible)) {
      guard isVisible else { return }
      let data = await ApplicationIconCache.shared.iconData(for: path)
      guard !Task.isCancelled, let data else { return }
      // The cache supplies one 64px PNG, never a lazy IconServices representation.
      image = NSImage(data: data)
      loadedPath = path
    }
  }
}

nonisolated struct ApplicationRowPreference {
  var bounds: Anchor<CGRect>?
  var iconReady: Bool?
}

nonisolated struct ApplicationRowPreferenceKey: PreferenceKey {
  nonisolated static var defaultValue: [String: ApplicationRowPreference] { [:] }

  nonisolated static func reduce(
    value: inout [String: ApplicationRowPreference], nextValue: () -> [String: ApplicationRowPreference]
  ) {
    value.merge(nextValue()) { first, next in
      ApplicationRowPreference(bounds: next.bounds ?? first.bounds, iconReady: next.iconReady ?? first.iconReady)
    }
  }
}

/// One geometry snapshot replaces callback accumulation. Unknown row geometry
/// cannot count as a ready icon or establish complete viewport coverage.
nonisolated struct ApplicationViewportSnapshot: Sendable, Equatable {
  struct Row: Sendable, Equatable {
    let frame: CGRect
    let iconReady: Bool
  }
  let visibleRows: [String: Row]
  let coversViewport: Bool
  let listedRowCount: Int
  var visiblePaths: Set<String> { Set(visibleRows.keys) }
  var iconsReady: Bool { coversViewport && !visibleRows.isEmpty && visibleRows.values.allSatisfy(\.iconReady) }

  init(rows: [String: Row], orderedPaths: [String], viewport: CGRect) {
    listedRowCount = orderedPaths.count
    let indices = Dictionary(orderedPaths.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    visibleRows = rows.filter { path, row in
      guard indices[path] != nil else { return false }
      let intersection = row.frame.intersection(viewport)
      return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }
    let visibleIndices = visibleRows.keys.compactMap { indices[$0] }.sorted()
    guard !viewport.isEmpty, let first = visibleIndices.first, let last = visibleIndices.last,
      let firstRow = rows[orderedPaths[first]], let lastRow = rows[orderedPaths[last]]
    else {
      coversViewport = false
      return
    }
    let contiguous = (first...last).allSatisfy { rows[orderedPaths[$0]] != nil }
    let startsAbove =
      firstRow.frame.minY <= viewport.minY
      || first == 0
      || (rows[orderedPaths[first - 1]].map { $0.frame.maxY <= viewport.minY } == true)
    let endsBelow =
      lastRow.frame.maxY >= viewport.maxY
      || last == orderedPaths.count - 1
      || (rows[orderedPaths[last + 1]].map { $0.frame.minY >= viewport.maxY } == true)
    coversViewport = contiguous && startsAbove && endsBelow
  }
}

struct ApplicationListViewport: ViewModifier {
  let orderedPaths: [String]
  let revision: Int
  let visibilityChanged: (Set<String>) -> Void
  let didDraw: (ApplicationViewportSnapshot) -> Void

  func body(content: Content) -> some View {
    content.overlayPreferenceValue(ApplicationRowPreferenceKey.self) { preferences in
      GeometryReader { geometry in
        let rows = preferences.compactMapValues { entry -> ApplicationViewportSnapshot.Row? in
          guard let anchor = entry.bounds else { return nil }
          return .init(frame: geometry[anchor], iconReady: entry.iconReady == true)
        }
        let snapshot = ApplicationViewportSnapshot(
          rows: rows, orderedPaths: orderedPaths, viewport: CGRect(origin: .zero, size: geometry.size))
        ApplicationViewportDrawProbe(snapshot: snapshot, revision: revision, didDraw: didDraw)
          .allowsHitTesting(false)
          .onChange(of: snapshot.visiblePaths, initial: true) { _, paths in visibilityChanged(paths) }
      }
    }
  }
}

/// A single probe draws the resolved viewport snapshot in the same display pass
/// as the rows, then reports it after drawing. Geometry alone is not a timing event.
private struct ApplicationViewportDrawProbe: NSViewRepresentable {
  let snapshot: ApplicationViewportSnapshot
  let revision: Int
  let didDraw: (ApplicationViewportSnapshot) -> Void

  func makeNSView(context: Context) -> Probe { Probe() }

  func updateNSView(_ view: Probe, context: Context) {
    view.didDraw = didDraw
    if view.revision != revision || view.snapshot != snapshot {
      view.revision = revision
      view.snapshot = snapshot
      view.needsDisplay = true
    }
  }

  final class Probe: NSView {
    var snapshot: ApplicationViewportSnapshot?
    var revision = -1
    var didDraw: ((ApplicationViewportSnapshot) -> Void)?
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
      guard window != nil, !isHiddenOrHasHiddenAncestor, let snapshot else { return }
      let callback = didDraw
      DispatchQueue.main.async { callback?(snapshot) }
    }
  }
}
