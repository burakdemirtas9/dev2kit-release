import SwiftUI
import Dev2KitCore

/// İçe aktarmadan önce bulguları gösterir; kullanıcı aktarır ya da vazgeçer.
/// Kesin engelli istekler her durumda dışarıda kalır.
struct ImportReviewView: View {
    let items: [AppState.PreparedImport]
    /// Onaylanan haller: örnek sınırını aşan isteklerde kullanıcının seçimi
    /// uygulanmış olarak gelir.
    let onConfirm: ([AppState.PreparedImport]) -> Void
    let onCancel: () -> Void

    /// İnceleme → istek → alınacak örnekler. Başlangıçta dosyadaki ilk
    /// `ResponseExamples.limit` örnek işaretli; kullanıcı görmeden uygulanmaz.
    @State private var exampleSelection: [UUID: [UUID: Set<UUID>]] = [:]

    private var resolvedItems: [AppState.PreparedImport]? {
        var resolved: [AppState.PreparedImport] = []
        for item in items {
            if item.review.requestsOverExampleLimit.isEmpty {
                resolved.append(item)
                continue
            }
            guard let review = item.review.applyingExampleSelection(exampleSelection[item.id] ?? [:]) else { return nil }
            resolved.append(AppState.PreparedImport(review: review, wasRenamed: item.wasRenamed))
        }
        return resolved
    }

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
                Button(L10n.plural("review.import", count: importableCount)) {
                    if let resolvedItems { onConfirm(resolvedItems) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(importableCount == 0 || resolvedItems == nil)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .onAppear {
            guard exampleSelection.isEmpty else { return }
            for item in items {
                let suggested = ResponseExamples.suggestedImportSelection(for: item.review.importableCollection)
                if !suggested.isEmpty { exampleSelection[item.id] = suggested }
            }
        }
    }

    // MARK: Örnek sınırı

    /// Sınırı aşan istekler: hangi örneklerin alınacağı burada seçilir.
    @ViewBuilder
    private func exampleOverflowSection(_ item: AppState.PreparedImport) -> some View {
        let overflowing = item.review.requestsOverExampleLimit
        if !overflowing.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.t("example.import.overLimit.title"), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.warning)
                Text(L10n.t("example.import.overLimit.detail", L10n.number(ResponseExamples.limit)))
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(overflowing) { request in
                    exampleChoices(request, reviewID: item.id)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func exampleChoices(_ request: RequestModel, reviewID: UUID) -> some View {
        let picked = exampleSelection[reviewID]?[request.id] ?? []
        let isFull = picked.count >= ResponseExamples.limit
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(request.method.rawValue)
                    .font(.secondaryMono).bold()
                    .foregroundStyle(Theme.color(for: request.method))
                Text(request.name).fontWeight(.medium)
                Spacer()
                Text(L10n.t("example.import.selected", L10n.number(picked.count), L10n.number(ResponseExamples.limit)))
                    .font(.secondaryText.monospacedDigit())
                    .foregroundStyle(isFull ? Theme.warning : .secondary)
            }
            ForEach(request.examples) { example in
                let isOn = picked.contains(example.id)
                Toggle(isOn: Binding(
                    get: { isOn },
                    set: { setExample(example.id, selected: $0, request: request.id, review: reviewID) }
                )) {
                    HStack(spacing: 6) {
                        Text(ResponseExamples.statusLabel(example.statusCode))
                            .font(.secondaryMono)
                            .foregroundStyle(Theme.statusColor(example.statusCode))
                        Text(example.name)
                            .lineLimit(1)
                    }
                }
                .toggleStyle(.checkbox)
                // Sınır doluyken yeni seçim açılmaz; önce biri bırakılır.
                .disabled(!isOn && isFull)
                .help(!isOn && isFull ? L10n.t("example.import.tooMany", L10n.number(ResponseExamples.limit)) : "")
            }
        }
    }

    private func setExample(_ exampleID: UUID, selected: Bool, request requestID: UUID, review reviewID: UUID) {
        var picked = exampleSelection[reviewID]?[requestID] ?? []
        if selected {
            guard picked.count < ResponseExamples.limit else { return }
            picked.insert(exampleID)
        } else {
            picked.remove(exampleID)
        }
        exampleSelection[reviewID, default: [:]][requestID] = picked
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
            if let item = items.first(where: { $0.id == review.id }) {
                exampleOverflowSection(item)
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
