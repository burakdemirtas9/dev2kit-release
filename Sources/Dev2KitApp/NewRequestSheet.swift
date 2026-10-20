import AppKit
import SwiftUI
import Dev2KitCore

/// İstek seçili değilken sağ panel: yalnızca "yeni bir istek oluştur"
/// yazısı tıklanabilir (marka moru), akışı açar (kullanıcı isteği, 2026-10-20).
struct NoRequestSelectedView: View {
    @State private var creating = false

    var body: some View {
        ContentUnavailableView {
            Label("İstek Seç", systemImage: "paperplane")
        } description: {
            HStack(spacing: 0) {
                Text("Soldan bir istek seç veya ")
                InlineActionLink("yeni bir istek oluştur") { creating = true }
                Text(".")
            }
        }
        .sheet(isPresented: $creating) {
            NewRequestSheet()
        }
    }
}

/// Metin içindeki eylem bağlantısı: gf-purple, üzerine gelince altı çizili
/// ve el imleci, klavye odağında çerçeve; ⏎ ve boşluk tuşuyla çalışır.
struct InlineActionLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(Theme.purple)
                .underline(hovering || focused)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.purple.opacity(hovering ? 0.10 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.purple.opacity(focused ? 0.8 : 0), lineWidth: 1.5)
                        .padding(-2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.return) { action(); return .handled }
        .onKeyPress(.space) { action(); return .handled }
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // İmleç üstündeyken görünüm kalkarsa el imleci takılı kalmasın.
        .onDisappear {
            if hovering { NSCursor.pop() }
            hovering = false
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}

/// Yeni istek akışı: ad, metot ve hedef (varsayılan Koleksiyonsuz).
/// "Oluştur"a basılana kadar hiçbir şey yazılmaz; Vazgeç kayıt bırakmaz.
struct NewRequestSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var method: HTTPMethod = .get
    @State private var destination: Choice = .ungrouped
    @State private var newCollectionName = ""
    @FocusState private var nameFocused: Bool

    enum Choice: Hashable {
        case ungrouped
        case existing(UUID)
        case newCollection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Yeni İstek").font(.title3).bold()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Ad").foregroundStyle(.secondary)
                    TextField(RequestModel().name, text: $name)
                        .inputLimit(.name)
                        .textFieldStyle(.input)
                        .focused($nameFocused)
                        .onSubmit(create)
                }
                GridRow {
                    Text("Metot").foregroundStyle(.secondary)
                    MethodPicker(selection: $method)
                        .frame(width: 110, alignment: .leading)
                }
                GridRow {
                    Text("Ekle").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $destination) {
                            Label(CollectionModel.ungroupedName, systemImage: "tray").tag(Choice.ungrouped)
                            let collections = appState.workspace.regularCollections
                            if !collections.isEmpty {
                                Divider()
                                ForEach(collections) { collection in
                                    Text(collection.name).tag(Choice.existing(collection.id))
                                }
                            }
                            Divider()
                            Label("Yeni koleksiyon…", systemImage: "folder.badge.plus").tag(Choice.newCollection)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240, alignment: .leading)
                        if destination == .newCollection {
                            TextField("Koleksiyon adı", text: $newCollectionName)
                                .inputLimit(.name)
                                .textFieldStyle(.input)
                                .frame(width: 240)
                            if appState.existingCollection(named: newCollectionName) != nil {
                                Text("Bu adla bir koleksiyon var; ona eklenir.")
                                    .font(.tinyText)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Oluştur", action: create)
                    .buttonStyle(PrimaryActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { DispatchQueue.main.async { nameFocused = true } }
    }

    private var canCreate: Bool {
        destination != .newCollection || !newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func create() {
        guard canCreate else { return }
        let target: AppState.CollectionDestination
        switch destination {
        case .ungrouped: target = .ungrouped
        case .existing(let id): target = .existing(id)
        case .newCollection: target = .new(name: newCollectionName)
        }
        if appState.createRequest(name: name, method: method, destination: target) != nil {
            dismiss()
        }
    }
}
