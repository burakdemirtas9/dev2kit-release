import SwiftUI
import Dev2KitCore

/// İçe aktarmadan önce bulguları gösterir; kullanıcı aktarır ya da vazgeçer.
/// Kesin engelli istekler her durumda dışarıda kalır.
struct ImportReviewView: View {
    let items: [AppState.PreparedImport]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var importableCount: Int { items.reduce(0) { $0 + $1.review.importableCount } }
    private var blockedCount: Int { items.reduce(0) { $0 + $1.review.blockedCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.t("review.title"), systemImage: "checkmark.shield")
                .font(.title2.bold())
            Text(blockedCount > 0
                 ? L10n.plural("review.subtitle.blocked", count: blockedCount)
                 : L10n.t("review.subtitle"))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        collectionSection(item.review)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Spacer()
                Button(L10n.t("common.cancel"), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.plural("review.import", count: importableCount)) { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(importableCount == 0)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
    }

    private func collectionSection(_ review: CollectionReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(review.collection.name).font(.headline)
                Text(L10n.plural("review.requestCount", count: review.requests.count))
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            }
            let flagged = review.requests
                .filter { !$0.findings.isEmpty }
                .sorted { ($0.worstSeverity?.rawValue ?? 9) < ($1.worstSeverity?.rawValue ?? 9) }
            if flagged.isEmpty {
                Label(L10n.t("review.noIssues"), systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(Theme.up)
            }
            ForEach(flagged) { requestReview in
                requestRow(requestReview)
            }
            ForEach(review.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func requestRow(_ review: RequestReview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(review.request.method.rawValue)
                    .font(.secondaryMono).bold()
                    .foregroundStyle(Theme.purple)
                Text(review.request.name).fontWeight(.medium)
                if review.isBlocked {
                    Text(L10n.t("review.notImported"))
                        .font(.tinyText.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .foregroundStyle(Theme.down)
                        .background(Theme.down.opacity(0.12), in: Capsule())
                }
            }
            ForEach(review.findings, id: \.self) { finding in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: icon(finding.severity))
                        .foregroundStyle(color(finding.severity))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(finding.title).font(.callout)
                        Text(finding.detail)
                            .font(.secondaryText)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(review.worstSeverity ?? .info).opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private func icon(_ severity: ImportFinding.Severity) -> String {
        switch severity {
        case .block: return "xmark.octagon.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(_ severity: ImportFinding.Severity) -> Color {
        switch severity {
        case .block: return Theme.down
        case .warn: return Theme.warning
        case .info: return .secondary
        }
    }
}
