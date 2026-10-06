import SwiftUI

/// Every tool shares one frame inside the content pane: a top row with the title, a short status, the
/// screen's actions and its search field, then the content. Controls live in the pane, not the window
/// toolbar, so they keep the same margin from the pane's edge as everything else.
struct ToolScreen<Content: View, Actions: View>: View {
  let title: String
  var subtitle: String?
  private let search: Binding<String>?
  private let searchPrompt: String
  private let content: Content
  private let actions: Actions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown = false

  init(
    _ title: String, subtitle: String? = nil, search: Binding<String>? = nil, searchPrompt: String = "",
    @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions
  ) {
    self.title = title
    self.subtitle = subtitle
    self.search = search
    self.searchPrompt = searchPrompt
    self.content = content()
    self.actions = actions()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: Theme.Space.m) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
          Text(title).font(Theme.Font.title).foregroundStyle(Theme.Palette.ink).lineLimit(1)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
          if let subtitle, !subtitle.isEmpty {
            Text(subtitle).font(Theme.Font.callout).foregroundStyle(Theme.Palette.inkSecondary).lineLimit(1)
              .help(subtitle)
          }
        }
        Spacer(minLength: Theme.Space.m)
        GlassEffectContainer(spacing: Theme.Space.s) {
          HStack(spacing: Theme.Space.s) {
            actions
            if let search { SearchField(text: search, prompt: searchPrompt) }
          }
          .buttonStyle(.glass)
          .controlSize(.large)
        }
      }
      .frame(height: Theme.Layout.topBarHeight)
      .padding(.horizontal, Theme.Layout.gutter)
      // The row shares the window's title bar height, level with the window controls.
      .padding(.top, Theme.Layout.topBarInset)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(shown || reduceMotion ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : Theme.Space.s)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .ignoresSafeArea(.container, edges: .top)
    .navigationTitle(title)
    .onAppear {
      withAnimation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion)) { shown = true }
    }
  }
}

extension ToolScreen where Actions == EmptyView {
  init(
    _ title: String, subtitle: String? = nil, search: Binding<String>? = nil, searchPrompt: String = "",
    @ViewBuilder content: () -> Content
  ) {
    self.init(title, subtitle: subtitle, search: search, searchPrompt: searchPrompt, content: content) {
      EmptyView()
    }
  }
}

/// A search field in a glass capsule; ⌘F moves focus into it.
struct SearchField: View {
  @Binding var text: String
  let prompt: String
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: Theme.Space.s) {
      Image(systemName: "magnifyingglass").foregroundStyle(Theme.Palette.inkSecondary).accessibilityHidden(true)
      TextField(prompt, text: $text).textFieldStyle(.plain).focused($focused)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Palette.inkTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Clear search"))
      }
    }
    .font(Theme.Font.body)
    .padding(.horizontal, Theme.Space.m)
    .frame(width: Theme.Layout.searchFieldWidth, height: Theme.Layout.controlHeight)
    .lightenGlass(.interactive, in: Capsule())
    // macOS would otherwise give the window's first text field the focus at launch.
    .onAppear { focused = false }
    .background {
      Button("") { focused = true }.keyboardShortcut("f", modifiers: .command).hidden()
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

/// Menu titles live in a capsule that sizes to its text, so long names are shortened in the middle here.
enum MenuLabel {
  static let maximumLength = 22

  static func short(_ text: String) -> String {
    guard text.count > maximumLength else { return text }
    let half = (maximumLength - 1) / 2
    return String(text.prefix(half)) + "…" + String(text.suffix(half))
  }
}
