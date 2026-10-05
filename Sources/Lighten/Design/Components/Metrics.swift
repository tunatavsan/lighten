import LightenKit
import SwiftUI

/// A number with its unit, kept apart so the unit can be set smaller than the number.
struct MetricValue: Equatable, Sendable {
  var number: String
  var unit: String?
  /// The value is a known lower bound.
  var atLeast = false

  static func bytes(_ bytes: Int64?, atLeast: Bool = false) -> MetricValue {
    guard let bytes else { return MetricValue(number: String(localized: "Unknown")) }
    let numberFormatter = ByteCountFormatter()
    numberFormatter.countStyle = .file
    numberFormatter.includesUnit = false
    let unitFormatter = ByteCountFormatter()
    unitFormatter.countStyle = .file
    unitFormatter.includesCount = false
    return MetricValue(
      number: numberFormatter.string(fromByteCount: bytes), unit: unitFormatter.string(fromByteCount: bytes),
      atLeast: atLeast)
  }

  static func aggregate(_ bytes: ByteAggregate?) -> MetricValue {
    guard let bytes else { return MetricValue(number: String(localized: "Unknown")) }
    if let total = bytes.completeTotal { return .bytes(total) }
    if bytes.knownLowerBound > 0 { return .bytes(bytes.knownLowerBound, atLeast: true) }
    return MetricValue(number: String(localized: "Unknown"))
  }

  static func count(_ count: Int, unit: String? = nil) -> MetricValue {
    MetricValue(number: count.formatted(), unit: unit)
  }

  static func text(_ text: String) -> MetricValue { MetricValue(number: text) }

  var accessibilityText: String {
    let value = [number, unit].compactMap(\.self).joined(separator: " ")
    return atLeast ? String(localized: "At least") + " " + value : value
  }
}

/// The one large number at the top of a screen: value, unit and a short caption beneath.
struct HeroMetric: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let value: MetricValue
  let caption: String
  var tone: Tone = .neutral

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
        if value.atLeast {
          Text(String(localized: "At least")).font(Theme.Font.callout).foregroundStyle(Theme.Palette.inkSecondary)
        }
        Text(value.number).font(Theme.Font.hero).monospacedDigit()
          .contentTransition(reduceMotion ? .opacity : .numericText())
        if let unit = value.unit {
          Text(unit).font(Theme.Font.heroUnit)
        }
      }
      .foregroundStyle(tone == .neutral ? Theme.Palette.ink : tone.foreground)
      .lineLimit(1).minimumScaleFactor(0.6)
      Text(caption).font(Theme.Font.callout).foregroundStyle(Theme.Palette.inkSecondary).lineLimit(1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(caption)
    .accessibilityValue(value.accessibilityText)
  }
}

/// A secondary metric: a medium number over a caption.
struct Metric: View {
  let value: MetricValue
  let caption: String
  var tone: Tone = .neutral
  var compact = false

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xxs) {
        if value.atLeast {
          Text(verbatim: "≥").font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
        }
        Text(value.number).monospacedDigit()
        if let unit = value.unit { Text(unit).font(Theme.Font.callout) }
      }
      .font(compact ? Theme.Font.metricSmall : Theme.Font.metric)
      .foregroundStyle(tone == .neutral ? Theme.Palette.ink : tone.foreground)
      .lineLimit(1)
      Text(caption).font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary).lineLimit(1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(caption)
    .accessibilityValue(value.accessibilityText)
  }
}

/// A rounded capacity track with coloured segments, like Storage in System Settings.
struct CapacityBar: View {
  struct Segment: Identifiable {
    let id: String
    let fraction: Double
    let color: Color
  }

  let segments: [Segment]
  var height: CGFloat = Theme.Layout.capacityBarHeight

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: Theme.Space.xxs) {
        ForEach(visibleSegments) { segment in
          Rectangle().fill(segment.color)
            .frame(width: max(Theme.Space.xxs, geometry.size.width * segment.fraction))
        }
        Spacer(minLength: 0)
      }
      .frame(width: geometry.size.width, height: height, alignment: .leading)
      .background(Theme.Palette.well)
      .clipShape(Capsule())
    }
    .frame(height: height)
    .accessibilityHidden(true)
  }

  private var visibleSegments: [Segment] {
    var remaining = 1.0
    return segments.compactMap { segment in
      let fraction = min(max(0, segment.fraction), remaining)
      remaining -= fraction
      return fraction > 0 ? Segment(id: segment.id, fraction: fraction, color: segment.color) : nil
    }
  }
}
