import LightenKit
import SwiftUI

struct AppsBasketView: View {
  let store: AppsStore
  let actions: ActionStore
  @State private var showingAutomaticData = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "basket").foregroundStyle(LightenStyle.accent)
        Text("\(String(localized: "Basket")): \(store.selectedAppPaths.count)")
          .font(.system(size: 13, weight: .semibold))
        Text("\(String(localized: "Related data")): \(store.basketDataCount)")
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        Spacer()
        Text(sizeLabel).font(.system(size: 12)).monospacedDigit()
      }
      ScrollView(.horizontal) {
        HStack(spacing: 5) {
          ForEach(store.basketApplications.sorted { $0.path < $1.path }) { app in
            HStack(spacing: 5) {
              Text(store.displayName(app)).lineLimit(1)
              Button {
                store.removeAppFromBasket(app.path, actions: actions)
              } label: {
                Image(systemName: "xmark.circle.fill")
              }
              .buttonStyle(.plain)
              .accessibilityLabel("\(String(localized: "Remove from basket")): \(store.displayName(app))")
              .disabled(actions.busy)
            }
            .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 5)
            .background(LightenStyle.surface, in: Capsule())
          }
        }
      }
      .scrollIndicators(.hidden)
      automaticDataDetails
      HStack(spacing: 12) {
        Text(store.reviewExplanation(actions: actions))
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        Spacer()
        Button(String(localized: "Clear basket")) { store.clearBasket(actions: actions) }
          .disabled(actions.busy)
        Button(String(localized: "Review removal")) { Task { await store.prepareBasket(actions: actions) } }
          .buttonStyle(.borderedProminent).disabled(!store.canReviewBasket(actions: actions))
          .accessibilityIdentifier("apps.review-removal")
      }
    }
    .padding(.top, 10)
  }

  @ViewBuilder private var automaticDataDetails: some View {
    let applications = store.basketApplications.sorted { $0.path < $1.path }
    let count = applications.reduce(0) { total, app in
      total + app.related.filter { store.isAutomaticallySelected($0, app: app) }.count
    }
    if count > 0 {
      DisclosureGroup(isExpanded: $showingAutomaticData) {
        ForEach(applications) { app in
          ForEach(app.related.filter { store.isAutomaticallySelected($0, app: app) }) { candidate in
            VStack(alignment: .leading, spacing: 2) {
              Text("\(store.displayName(app)): \(candidate.path)")
                .font(.system(size: 10)).lineLimit(2).truncationMode(.middle).help(candidate.path)
              let kinds =
                candidate.evidenceKinds.isEmpty ? candidate.provenance.map { [$0.kind] } ?? [] : candidate.evidenceKinds
              ForEach(Array(Set(kinds)).sorted { $0.rawValue < $1.rawValue }, id: \.self) { kind in
                Text(AppsStore.provenanceLabel(kind)).font(.system(size: 10)).foregroundStyle(LightenStyle.muted)
              }
            }
            .padding(.vertical, 3)
          }
        }
      } label: {
        Text(
          String.localizedStringWithFormat(String(localized: "%lld related items selected automatically"), Int64(count))
        )
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      }
    }
  }

  private var sizeLabel: String {
    let size = store.basketLogical
    let value = ByteCountFormatter.string(fromByteCount: size.completeTotal ?? size.knownLowerBound, countStyle: .file)
    return size.completeTotal == nil ? "\(String(localized: "At least")) \(value)" : value
  }
}
