import AppKit
import SwiftUI

// Glass is the system's own Liquid Glass and is used on chrome only: the floating basket,
// the result toast, the menu bar panel and controls laid over content. Content surfaces are
// opaque cards. Glass never samples glass: neighbours share one GlassEffectContainer.

enum GlassRole: Sendable {
  /// Floating chrome: the basket bar, the toast, the menu bar panel.
  case chrome
  /// Chrome that is itself a control.
  case interactive
  /// Chrome that carries the accent, such as a selected floating control.
  case accent

  var glass: Glass {
    switch self {
    case .chrome: .regular.tint(Theme.Palette.glassTintChrome)
    case .interactive: .regular.tint(Theme.Palette.glassTintChrome).interactive()
    case .accent: .regular.tint(Theme.Palette.glassTintAccent).interactive()
    }
  }
}

private struct LightenGlassModifier<S: Shape>: ViewModifier {
  let role: GlassRole
  let shape: S
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    Group {
      if reduceTransparency {
        content.background(shape.fill(Theme.Palette.glassSolid))
      } else {
        content.glassEffect(role.glass, in: shape)
      }
    }
    .overlay {
      if reduceTransparency || contrast == .increased {
        shape.stroke(
          contrast == .increased ? Theme.Palette.hairlineStrong : Theme.Palette.hairline,
          lineWidth: Theme.Stroke.hairline)
      }
    }
  }
}

extension View {
  /// System Liquid Glass in `shape`, an opaque token under Reduce Transparency and a visible edge
  /// under Increase Contrast.
  func lightenGlass(_ role: GlassRole = .chrome, in shape: some Shape = Capsule()) -> some View {
    modifier(LightenGlassModifier(role: role, shape: shape))
  }
}

// MARK: - Window tray and panes

/// The window's tray: one untinted blur of whatever lies behind the window, beneath the sidebar
/// and the content pane, so both float on a single frosted surface with a gap between them. It is
/// how the system frosts the floating sidebar's surroundings (a backdrop layer with a blur filter),
/// stretched across the window. The classes are not public API; when they are missing the window
/// simply has no tray.
struct TrayBlur: NSViewRepresentable {
  func makeNSView(context: Context) -> TrayBlurView { TrayBlurView() }
  func updateNSView(_ view: TrayBlurView, context: Context) {}
}

final class TrayBlurView: NSView {
  /// Low enough that the desktop behind the window stays recognisable.
  static let radius = 2.0

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    setAccessibilityHidden(true)
    guard let layer, let backdrop = Self.makeBackdrop() else { return }
    backdrop.frame = bounds
    backdrop.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    layer.addSublayer(backdrop)
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private static func makeBackdrop() -> CALayer? {
    guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
      let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
      filterClass.responds(to: NSSelectorFromString("filterWithType:")),
      let blur = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
        .takeUnretainedValue() as? NSObject
    else { return nil }
    blur.setValue(radius, forKey: "inputRadius")
    blur.setValue(true, forKey: "inputNormalizeEdges")
    let backdrop = layerClass.init()
    guard backdrop.responds(to: NSSelectorFromString("setWindowServerAware:")) else { return nil }
    backdrop.filters = [blur]
    backdrop.setValue(true, forKey: "windowServerAware")
    return backdrop
  }
}

/// The content pane's glass, made like the native floating sidebar's: one untinted
/// `NSGlassEffectView`. SwiftUI's `glassEffect` over an area this large bends visibly at its seams.
struct PaneGlass: NSViewRepresentable {
  var cornerRadius: CGFloat = Theme.Radius.pane

  func makeNSView(context: Context) -> NSGlassEffectView {
    let view = NSGlassEffectView()
    view.style = .regular
    view.tintColor = nil
    view.cornerRadius = cornerRadius
    view.contentView = NSView()
    view.setAccessibilityHidden(true)
    view.adoptSidebarGlass()
    return view
  }

  func updateNSView(_ view: NSGlassEffectView, context: Context) {
    if view.cornerRadius != cornerRadius { view.cornerRadius = cornerRadius }
  }
}

extension NSGlassEffectView {
  /// The variant the native floating sidebar uses: a panel glass without the lensing a large plain
  /// glass bends across its interior. Not public API, so it is set only while the view answers to it.
  func adoptSidebarGlass() {
    guard responds(to: NSSelectorFromString("set_variant:")) else { return }
    setValue(16, forKey: "_variant")
    if responds(to: NSSelectorFromString("set_adaptiveAppearance:")) { setValue(1, forKey: "_adaptiveAppearance") }
  }
}

/// Clears the hosting window's own background so the tray can sample the desktop.
struct ClearWindowBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { ClearingView() }
  func updateNSView(_ view: NSView, context: Context) {}

  private final class ClearingView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      window.isOpaque = false
      window.backgroundColor = .clear
      window.titlebarAppearsTransparent = true
    }
  }
}

private struct WindowTrayModifier: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    content.background {
      Group {
        if reduceTransparency {
          Theme.Palette.canvas
        } else {
          ZStack {
            ClearWindowBackground()
            TrayBlur()
          }
        }
      }
      .ignoresSafeArea()
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}

private struct ContentPaneModifier: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    content.background {
      Group {
        if reduceTransparency {
          shape.fill(Theme.Palette.glassSolid)
        } else {
          PaneGlass()
        }
      }
      .overlay {
        if contrast == .increased { shape.strokeBorder(Theme.Palette.hairlineStrong, lineWidth: Theme.Stroke.hairline) }
      }
      .padding(Theme.Layout.paneInset)
      // Keeps the split view's horizontal reservation while reaching under the toolbar.
      .ignoresSafeArea(edges: [.top, .bottom])
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.pane, style: .continuous) }
}

extension View {
  /// The frosted tray under the whole window; Reduce Transparency shows the opaque canvas instead.
  func windowTray() -> some View { modifier(WindowTrayModifier()) }

  /// A detail column's own glass pane, inset from the window like the floating sidebar.
  func contentPane() -> some View { modifier(ContentPaneModifier()) }
}
