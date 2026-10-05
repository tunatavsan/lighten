import SwiftUI

/// The empty, not-yet-scanned or nothing-found state of a screen: one symbol, one title,
/// at most one line, and the action that moves on.
struct EmptyState<Actions: View>: View {
  let symbol: String
  let title: String
  var message: String?
  var tint: Color = Theme.Palette.accent
  private let actions: Actions

  init(
    symbol: String, title: String, message: String? = nil, tint: Color = Theme.Palette.accent,
    @ViewBuilder actions: () -> Actions = { EmptyView() }
  ) {
    self.symbol = symbol
    self.title = title
    self.message = message
    self.tint = tint
    self.actions = actions()
  }

  var body: some View {
    VStack(spacing: Theme.Space.m) {
      Image(systemName: symbol)
        .font(Theme.Font.emptySymbol)
        .foregroundStyle(tint.gradient)
        .symbolRenderingMode(.hierarchical)
        .accessibilityHidden(true)
      Text(title).font(Theme.Font.title2).foregroundStyle(Theme.Palette.ink)
        .multilineTextAlignment(.center)
      if let message {
        Text(message).font(Theme.Font.body).foregroundStyle(Theme.Palette.inkSecondary)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      }
      actions.padding(.top, Theme.Space.xs)
    }
    .frame(maxWidth: Theme.Layout.emptyStateWidth)
    .padding(Theme.Space.xxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
  }
}

/// A live scan: spinner, what is happening, and how far it got.
struct ScanStatusRow: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let status: String
  var count: Int?
  var bytes: Int64?

  var body: some View {
    HStack(spacing: Theme.Space.s) {
      ProgressView().controlSize(.small)
      Text(status).font(Theme.Font.calloutMedium).foregroundStyle(Theme.Palette.ink).lineLimit(1)
      Group {
        if let count {
          Text(String.localizedStringWithFormat(String(localized: "%lld items checked"), count))
        }
        if let bytes {
          Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
      }
      .font(Theme.Font.monoSmall).foregroundStyle(Theme.Palette.inkSecondary)
      .contentTransition(reduceMotion ? .opacity : .numericText())
      .animation(Theme.Motion.resolve(Theme.Motion.quick, reduceMotion: reduceMotion), value: count)
      .animation(Theme.Motion.resolve(Theme.Motion.quick, reduceMotion: reduceMotion), value: bytes)
    }
    .accessibilityElement(children: .combine)
  }
}

/// A one-line notice above content: a partial scan, a stale result, a missing permission.
/// The full explanation sits behind the chip.
struct NoticeBar<Trailing: View>: View {
  let title: String
  var symbol = "exclamationmark.triangle.fill"
  var tone: Tone = .warning
  private let trailing: Trailing

  init(
    _ title: String, symbol: String = "exclamationmark.triangle.fill", tone: Tone = .warning,
    @ViewBuilder trailing: () -> Trailing = { EmptyView() }
  ) {
    self.title = title
    self.symbol = symbol
    self.tone = tone
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: Theme.Space.s) {
      Image(systemName: symbol).font(Theme.Font.iconSmall).foregroundStyle(tone.foreground)
        .accessibilityHidden(true)
      Text(title).font(Theme.Font.callout).foregroundStyle(Theme.Palette.ink)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: Theme.Space.s)
      trailing.controlSize(.small)
    }
    .padding(.horizontal, Theme.Space.m)
    .padding(.vertical, Theme.Space.s)
    .background(tone.tint, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    .accessibilityElement(children: .contain)
  }
}
