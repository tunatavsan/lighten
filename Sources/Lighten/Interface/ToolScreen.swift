import SwiftUI

/// Gives every tool the same content alignment and native toolbar placement.
struct ToolScreen<Content: View, Actions: View>: View {
  let title: String
  private let content: Content
  private let actions: Actions

  init(
    _ title: String, @ViewBuilder content: () -> Content,
    @ViewBuilder toolbar: () -> Actions
  ) {
    self.title = title
    self.content = content()
    self.actions = toolbar()
  }

  var body: some View {
    GeometryReader { geometry in
      content
        .frame(width: min(1120, max(0, geometry.size.width - 48)), height: geometry.size.height, alignment: .topLeading)
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
    }
    .background(LightenStyle.canvas)
    .navigationTitle(title)
    .toolbar { ToolbarItemGroup(placement: .automatic) { actions } }
  }
}

struct ToolScanProgress: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let status: String
  let count: Int
  var bytes: Int64? = nil

  var body: some View {
    HStack(spacing: 10) {
      ProgressView().controlSize(.small)
      VStack(alignment: .leading, spacing: 3) {
        Text(status).font(.callout)
        HStack(spacing: 12) {
          Text(String.localizedStringWithFormat(String(localized: "%lld items checked"), count))
          if let bytes {
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
          }
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        .contentTransition(reduceMotion ? .identity : .numericText())
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: count)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: bytes)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

struct PartialResultNotice: View {
  @Environment(\.fullDiskAccessMonitor) private var access
  let reason: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(reason, systemImage: "exclamationmark.triangle")
        .font(.callout).foregroundStyle(LightenStyle.warning)
        .fixedSize(horizontal: false, vertical: true)
      if access?.state == .notGranted {
        Button(String(localized: "Open Full Disk Access settings")) { access?.openSettings() }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
