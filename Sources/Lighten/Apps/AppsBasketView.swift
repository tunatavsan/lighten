import LightenKit
import SwiftUI

/// The floating basket for Apps: the chosen apps, the data that comes with them, and the review action.
struct AppsBasketView: View {
  let store: AppsStore
  let actions: ActionStore

  var body: some View {
    FloatingBar {
      if !store.selectedAppPaths.isEmpty {
        HStack(spacing: -Theme.Space.s) {
          ForEach(store.basketApplications.sorted { $0.path < $1.path }.prefix(Theme.Layout.basketIconLimit)) { app in
            ApplicationIconView(path: app.path, size: Theme.Layout.basketIcon)
          }
        }
        .accessibilityHidden(true)
        SelectionSummary(
          symbol: "basket",
          title: String.localizedStringWithFormat(
            String(localized: "Basket: %lld"), Int64(store.selectedAppPaths.count)),
          value: MetricValue.aggregate(store.basketLogical))
        basketChip
      }
      if !store.selectedOrphanPaths.isEmpty {
        Chip(
          title: String.localizedStringWithFormat(
            String(localized: "%lld selected"), Int64(store.selectedOrphanPaths.count)),
          symbol: "folder", tone: .accent)
      }
    } actions: {
      if store.preparing || actions.busy { ProgressView().controlSize(.small) }
      if !store.selectedAppPaths.isEmpty {
        Button(String(localized: "Clear basket")) { store.clearBasket(actions: actions) }
          .buttonStyle(.glass)
          .disabled(actions.busy)
        Button(String(localized: "Review removal")) { Task { await store.prepareBasket(actions: actions) } }
          .buttonStyle(.glassProminent)
          .disabled(!store.canReviewBasket(actions: actions))
          .help(store.reviewExplanation(actions: actions))
          .accessibilityIdentifier("apps.review-removal")
      }
      if !store.selectedOrphanPaths.isEmpty {
        if store.selectedAppPaths.isEmpty {
          orphanReview.buttonStyle(.glassProminent)
        } else {
          orphanReview.buttonStyle(.glass)
        }
      }
    }
  }

  private var orphanReview: some View {
    Button(String(localized: "Review selected app data")) { Task { await store.prepareOrphans(actions: actions) } }
      .disabled(store.preparing || store.needsRescan || actions.busy)
  }

  /// What the basket holds, app by app, with each automatically chosen item and its evidence.
  private var basketChip: some View {
    let applications = store.basketApplications.sorted { $0.path < $1.path }
    let automatic = applications.reduce(0) { total, app in
      total + app.related.filter { store.isAutomaticallySelected($0, app: app) }.count
    }
    return DetailChip(
      String.localizedStringWithFormat(String(localized: "App data: %lld"), Int64(store.basketDataCount)),
      symbol: "doc.on.doc", tone: .neutral
    ) {
      VStack(alignment: .leading, spacing: Theme.Space.s) {
        ForEach(applications) { app in
          HStack(spacing: Theme.Space.s) {
            ApplicationIconView(path: app.path, size: Theme.Layout.basketIcon)
            Text(store.displayName(app)).font(Theme.Font.bodyMedium)
            Spacer()
            Button {
              store.removeAppFromBasket(app.path, actions: actions)
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Palette.inkSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(String(localized: "Remove from basket")): \(store.displayName(app))")
            .disabled(actions.busy)
          }
        }
        if automatic > 0 {
          RowDivider()
          Text(
            String.localizedStringWithFormat(
              String(localized: "%lld app data items selected automatically"), Int64(automatic))
          )
          .font(Theme.Font.bodyMedium)
          ForEach(applications) { app in
            ForEach(app.related.filter { store.isAutomaticallySelected($0, app: app) }) { candidate in
              VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("\(store.displayName(app)): \(URL(fileURLWithPath: candidate.path).lastPathComponent)")
                  .lineLimit(1).truncationMode(.middle).help(candidate.path)
                let kinds =
                  candidate.evidenceKinds.isEmpty
                  ? candidate.provenance.map { [$0.kind] } ?? [] : candidate.evidenceKinds
                ForEach(Array(Set(kinds)).sorted { $0.rawValue < $1.rawValue }, id: \.self) { kind in
                  Text(AppsSurfaceText.provenance(kind)).font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.inkSecondary)
                }
              }
            }
          }
        }
        Text(store.reviewExplanation(actions: actions)).font(Theme.Font.caption)
          .foregroundStyle(Theme.Palette.inkSecondary)
      }
    }
  }
}
