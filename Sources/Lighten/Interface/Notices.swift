import AppKit
import SwiftUI

/// A partial or stopped result, with the way to Full Disk Access when that is what is missing.
struct PartialNotice<Details: View>: View {
  @Environment(\.fullDiskAccessMonitor) private var access
  let reason: String
  var tone: Tone = .warning
  private let details: Details

  init(_ reason: String, tone: Tone = .warning, @ViewBuilder details: () -> Details = { EmptyView() }) {
    self.reason = reason
    self.tone = tone
    self.details = details()
  }

  var body: some View {
    NoticeBar(reason, tone: tone) {
      details
      if access?.state == .notGranted {
        Button(String(localized: "Open Full Disk Access settings")) { access?.openSettings() }
      }
    }
  }
}

/// The Finder button most rows and inspectors offer.
struct ShowInFinderButton: View {
  let path: String
  var compact = false

  var body: some View {
    Button {
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    } label: {
      if compact {
        Image(systemName: "magnifyingglass.circle")
      } else {
        Label(String(localized: "Show in Finder"), systemImage: "folder")
      }
    }
    .help(String(localized: "Show in Finder"))
    .accessibilityLabel(String(localized: "Show in Finder"))
  }
}
