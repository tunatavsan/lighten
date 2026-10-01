import AppKit
import SwiftUI

struct FailureReasonView: View {
  let presentation: FailurePresentation
  var path: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(presentation.primaryReason)
      if !presentation.additionalReasons.isEmpty {
        DisclosureGroup(FailureText.additionalReasonLabel(presentation.additionalReasons.count)) {
          ForEach(presentation.additionalReasons, id: \.self) { reason in
            Text(reason)
          }
        }
      }
      Text(presentation.nextStep).foregroundStyle(LightenStyle.muted)
      if let path {
        Text(path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        Button(String(localized: "Show in Finder")) {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }.buttonStyle(.plain)
      }
    }
    .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
  }
}
