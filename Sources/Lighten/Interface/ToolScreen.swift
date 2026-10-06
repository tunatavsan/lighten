import SwiftUI

/// Every tool shares one frame: its title and a short status at the top of the pane, actions in the
/// window toolbar, content below. The title sits in the pane rather than the toolbar, so toolbar items
/// never squeeze it. A new screen's content rises into place; the toolbar does not move.
struct ToolScreen<Content: View, Toolbar: ToolbarContent>: View {
  let title: String
  var subtitle: String?
  private let content: Content
  private let toolbar: Toolbar
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown = false

  init(
    _ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content,
    @ToolbarContentBuilder toolbar: () -> Toolbar
  ) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
    self.toolbar = toolbar()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
        Text(title).font(Theme.Font.title).foregroundStyle(Theme.Palette.ink)
          .accessibilityAddTraits(.isHeader)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle).font(Theme.Font.callout).foregroundStyle(Theme.Palette.inkSecondary).lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Theme.Layout.gutter)
      .padding(.top, Theme.Space.l)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(shown || reduceMotion ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : Theme.Space.s)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .navigationTitle(title)
    .toolbar(removing: .title)
    .toolbar {
      // Without a title, a flexible gap keeps actions at the trailing edge beside search.
      ToolbarSpacer(.flexible)
      toolbar
    }
    .onAppear {
      withAnimation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion)) { shown = true }
    }
  }
}

/// The top of a tool: its hero metric on the left, secondary metrics and status on the right.
struct ToolHeader<Trailing: View, Status: View>: View {
  let hero: HeroMetric
  private let trailing: Trailing
  private let status: Status

  init(hero: HeroMetric, @ViewBuilder trailing: () -> Trailing, @ViewBuilder status: () -> Status = { EmptyView() }) {
    self.hero = hero
    self.trailing = trailing()
    self.status = status()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.m) {
      HStack(alignment: .bottom, spacing: Theme.Space.xl) {
        hero
        Spacer(minLength: Theme.Space.l)
        trailing
      }
      status
    }
    .padding(.top, Theme.Space.xl)
    .padding(.bottom, Theme.Space.l)
  }
}

/// A screen with no toolbar actions of its own.
struct NoToolbarActions: ToolbarContent {
  var body: some ToolbarContent { ToolbarItemGroup {} }
}

extension ToolScreen where Toolbar == NoToolbarActions {
  init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
    self.toolbar = NoToolbarActions()
  }
}
