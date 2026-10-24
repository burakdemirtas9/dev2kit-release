import SwiftUI
import Dev2KitCore

/// "Örnek olarak kaydet": ad ve kayıtlı örneklerin yönetimi. Kaydedilecek
/// görüntü akış başında alındı (`PendingExampleSave.snapshot`); burada
/// örnek silmek ona dokunmaz. Sınır doluyken Kaydet kapalı, uyarı görünür;
/// bir örnek silinince açılır. Hiçbir örnek kendiliğinden silinmez.
struct SaveExampleSheet: View {
    @Environment(AppState.self) private var appState
    let pending: AppState.PendingExampleSave

    @State private var name = ""
    @State private var deleteTarget: ResponseExample?
    @FocusState private var nameFocused: Bool

    private var examples: [ResponseExample] {
        appState.request(withID: pending.requestID)?.examples ?? []
    }

    private var isFull: Bool { examples.count >= ResponseExamples.limit }

    private var canSave: Bool {
        !isFull && pending.snapshot != nil && ResponseExamples.normalizedName(name) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.t("example.sheet.title"), systemImage: "bookmark")
                .font(.title3.bold())
            if let snapshot = pending.snapshot {
                snapshotSummary(snapshot)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("example.sheet.name"))
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                TextField(L10n.t("example.sheet.namePlaceholder"), text: $name)
                    .inputLimit(.name)
                    .textFieldStyle(.input)
                    .focused($nameFocused)
                    .onSubmit(save)
                    .disabled(isFull)
            }
            Label(L10n.t("example.sheet.masked"), systemImage: "lock.shield")
                .font(.secondaryText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isFull {
                HStack(alignment: .top, spacing: 6) {
                    MessageIcon(kind: .warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("example.limit.message"))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L10n.t("example.sheet.snapshotKept"))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.secondaryText)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MessageKind.warning.background, in: RoundedRectangle(cornerRadius: 6))
            }

            if !examples.isEmpty {
                savedList
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(L10n.t("common.cancel"), role: .cancel) { appState.cancelSavingExample() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("common.save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .frame(minHeight: 300)
        .onAppear {
            name = pending.snapshot?.name ?? ""
            nameFocused = !isFull
        }
        .onChange(of: isFull) {
            // Yer açıldı: ad alanına dönülsün.
            if !isFull { nameFocused = true }
        }
        .confirmationDialog(
            L10n.t("example.delete.title", deleteTarget?.name ?? ""),
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.t("example.delete"), role: .destructive) {
                if let target = deleteTarget {
                    appState.deleteExample(AppState.ExampleRef(requestID: pending.requestID, exampleID: target.id))
                }
                deleteTarget = nil
            }
            Button(L10n.t("common.cancel"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(L10n.t("common.deletePermanent"))
        }
    }

    private func save() {
        guard canSave else { return }
        appState.commitPendingExample(name: name)
    }

    private func snapshotSummary(_ snapshot: ResponseExample) -> some View {
        HStack(spacing: 10) {
            Text(ResponseExamples.statusLabel(snapshot.statusCode))
                .font(.system(.body, design: .monospaced)).bold()
                .foregroundStyle(Theme.statusColor(snapshot.statusCode))
            if let contentType = snapshot.contentType {
                Text(contentType)
                    .font(.secondaryMono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(TextStats.size(snapshot.bodyData.count))
                .font(.secondaryText)
                .foregroundStyle(.secondary)
        }
    }

    private var savedList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.t("example.sheet.saved"))
                    .font(.secondaryText.weight(.semibold))
                Spacer()
                Text(L10n.t("example.sheet.count", L10n.number(examples.count), L10n.number(ResponseExamples.limit)))
                    .font(.secondaryText.monospacedDigit())
                    .foregroundStyle(isFull ? Theme.warning : .secondary)
            }
            ForEach(examples) { example in
                HStack(spacing: 8) {
                    Text(ResponseExamples.statusLabel(example.statusCode))
                        .font(.secondaryMono)
                        .foregroundStyle(Theme.statusColor(example.statusCode))
                        .frame(width: 32, alignment: .leading)
                    Text(example.name)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        deleteTarget = example
                    } label: {
                        Image(systemName: "trash")
                            .iconHitTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.t("example.delete.help"))
                    .accessibilityLabel(L10n.t("example.delete") + ": " + example.name)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}
