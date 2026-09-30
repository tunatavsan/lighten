import AppKit
import SwiftUI

struct ApplicationIconView: View {
  let path: String
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
    .accessibilityHidden(true)
    .task(id: path) {
      image = nil
      let data = await ApplicationIconCache.shared.iconData(for: path)
      guard !Task.isCancelled, let data else { return }
      image = NSImage(data: data)
    }
  }
}
