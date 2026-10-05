import SwiftUI

/// Every tool shares one frame: the title and a short status in the window toolbar, actions in
/// the toolbar, content on the glass pane below.
struct ToolScreen<Content: View, Toolbar: ToolbarContent>: View {
  let title: String
  var subtitle: String?
  private let content: Content
  private let toolbar: Toolbar

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
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .navigationTitle(title)
      .navigationSubtitle(subtitle ?? "")
      .toolbar { toolbar }
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
