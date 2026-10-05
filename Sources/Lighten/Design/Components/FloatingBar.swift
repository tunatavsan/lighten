import SwiftUI

/// The floating glass bar at the bottom of a tool: what is selected, and what to do with it.
struct FloatingBar<Leading: View, Actions: View>: View {
  private let leading: Leading
  private let actions: Actions

  init(@ViewBuilder leading: () -> Leading, @ViewBuilder actions: () -> Actions) {
    self.leading = leading()
    self.actions = actions()
  }

  var body: some View {
    GlassEffectContainer(spacing: Theme.Space.s) {
      HStack(spacing: Theme.Space.m) {
        leading
        Spacer(minLength: Theme.Space.s)
        actions
      }
      .padding(.leading, Theme.Space.l)
      .padding(.trailing, Theme.Space.s)
      .padding(.vertical, Theme.Space.s)
      .frame(maxWidth: Theme.Layout.floatingBarMaximum)
      .lightenGlass(.chrome, in: Capsule())
    }
    .padding(.horizontal, Theme.Layout.gutter)
    .padding(.bottom, Theme.Space.l)
    .accessibilityElement(children: .contain)
  }
}

extension View {
  /// Floats `bar` over the bottom of the screen while `isPresented`, and keeps scrolling content
  /// clear of it.
  func floatingBar<Bar: View>(isPresented: Bool, @ViewBuilder bar: () -> Bar) -> some View {
    modifier(FloatingBarModifier(isPresented: isPresented, bar: bar()))
  }
}

private struct FloatingBarModifier<Bar: View>: ViewModifier {
  let isPresented: Bool
  let bar: Bar
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .safeAreaPadding(.bottom, isPresented ? Theme.Layout.floatingBarClearance : 0)
      .overlay(alignment: .bottom) {
        if isPresented {
          bar.transition(
            Theme.Motion.transition(.move(edge: .bottom).combined(with: .opacity), reduceMotion: reduceMotion))
        }
      }
      .animation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion), value: isPresented)
  }
}

/// The selection summary at the leading edge of a floating bar.
struct SelectionSummary: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let symbol: String
  let title: String
  let value: MetricValue

  var body: some View {
    HStack(spacing: Theme.Space.s) {
      Image(systemName: symbol).font(Theme.Font.icon).foregroundStyle(Theme.Palette.accent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        Text(title).font(Theme.Font.headline).lineLimit(1)
        Text(value.accessibilityText).font(Theme.Font.monoSmall).foregroundStyle(Theme.Palette.inkSecondary)
          .lineLimit(1)
          .contentTransition(reduceMotion ? .opacity : .numericText())
      }
    }
    .accessibilityElement(children: .combine)
  }
}
