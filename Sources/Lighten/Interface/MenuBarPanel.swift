import AppKit
import LightenKit
import SwiftUI

/// The menu bar panel: free space and memory pressure at a glance, and a way into each tool.
struct MenuBarPanel: View {
  let model: LightenModel
  @Bindable var overview: OverviewStore
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.m) {
      HStack(spacing: Theme.Space.s) {
        Image("MenuBarGlyph").renderingMode(.template).foregroundStyle(Theme.Palette.accent)
          .accessibilityHidden(true)
        Text(verbatim: "Lighten").font(Theme.Font.headline)
        Spacer()
        SettingsLink {
          Image(systemName: "gearshape").foregroundStyle(Theme.Palette.inkSecondary)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Settings"))
        .accessibilityLabel(String(localized: "Settings"))
      }
      disk
      memory
      GlassEffectContainer(spacing: Theme.Space.s) {
        HStack(spacing: Theme.Space.s) {
          quickAction(String(localized: "Space"), symbol: "square.grid.3x3.square") {
            open(.space)
            model.space.startScan()
          }
          quickAction(String(localized: "Clean"), symbol: "sparkles") { open(.clean) }
          quickAction(String(localized: "Apps"), symbol: "app.badge.checkmark") { open(.apps) }
        }
      }
      Button {
        open(nil)
      } label: {
        Text(String(localized: "Open Lighten")).frame(maxWidth: .infinity)
      }
      .buttonStyle(.glassProminent)
      .controlSize(.large)
      .keyboardShortcut("0", modifiers: .command)
    }
    .padding(Theme.Space.l)
    .frame(width: Theme.Layout.menuBarWidth)
    .task { await overview.run(rootPath: "/") }
    .onDisappear { overview.stop() }
  }

  private var disk: some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      HStack(alignment: .firstTextBaseline) {
        Label(String(localized: "Free on volume"), systemImage: "internaldrive")
          .font(Theme.Font.captionMedium).foregroundStyle(Theme.Palette.inkSecondary)
        Spacer()
        if let total = overview.volume?.totalBytes {
          Text(
            String.localizedStringWithFormat(
              String(localized: "Free of %@"), ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
          )
          .font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
        }
      }
      let value = MetricValue.bytes(overview.volume?.freeBytes)
      HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
        Text(value.number).font(Theme.Font.metric).monospacedDigit()
        if let unit = value.unit { Text(unit).font(Theme.Font.callout) }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(String(localized: "Free on volume"))
      .accessibilityValue(value.accessibilityText)
      CapacityBar(segments: segments, height: Theme.Layout.meterHeight)
    }
    .cardSurface(padding: Theme.Space.m, radius: Theme.Radius.card)
  }

  private var memory: some View {
    let pressure = overview.system?.pressure ?? .unknown
    return VStack(alignment: .leading, spacing: Theme.Space.s) {
      HStack(alignment: .firstTextBaseline) {
        Label(String(localized: "Memory pressure"), systemImage: "memorychip")
          .font(Theme.Font.captionMedium).foregroundStyle(Theme.Palette.inkSecondary)
        Spacer()
        Text(PressureText.title(pressure)).font(Theme.Font.headline)
          .foregroundStyle(
            PressureText.tone(pressure) == .neutral ? Theme.Palette.ink : PressureText.tone(pressure).foreground)
      }
      .accessibilityElement(children: .combine)
      PressureScale(pressure: pressure)
    }
    .cardSurface(padding: Theme.Space.m, radius: Theme.Radius.card)
  }

  private var segments: [CapacityBar.Segment] {
    guard let total = overview.volume?.totalBytes, total > 0, let used = overview.volume?.usedBytes else { return [] }
    return [.init(id: "used", fraction: Double(used) / Double(total), color: Theme.Palette.indigo)]
  }

  private func quickAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: Theme.Space.xs) {
        Image(systemName: symbol).font(Theme.Font.icon)
        Text(title).font(Theme.Font.caption)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, Theme.Space.s)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .lightenGlass(.interactive, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
  }

  private func open(_ section: LightenSection?) {
    if let section { model.show(section) }
    openWindow(id: LightenRootView.windowID)
    NSApp.activate()
  }
}
