import AppKit
import Foundation
import SwiftUI
import Dev2KitCore

/// Koleksiyon ve environment yönetimi: ekleme, yeniden adlandırma, silme,
/// sıralama ve environment değişkenlerine bağlama.

extension AppState {
    func addCollection() {
        // Açık arama temizlenir: yeni koleksiyonun adı filtreye uymayacağı için
        // oluşturulur ama listede görünmezdi.
        clearSearch()
        workspace.collections.append(CollectionModel())
        persist()
    }

    func renameCollection(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = workspace.collections.firstIndex(id: id),
              workspace.collections[index].isRegular else { return }
        workspace.collections[index].name = trimmed
        persist()
    }

    func deleteCollection(_ id: UUID) {
        // Koleksiyonsuz kap ve Token Factory silinmez; içindeki istekler tek tek silinir.
        guard workspace.collections.first(where: { $0.id == id })?.isRegular == true else { return }
        let removed = workspace.collections.first { $0.id == id }?.requests.map(\.id) ?? []
        workspace.collections.removeAll { $0.id == id }
        removed.forEach(closeTab)
        if let selected = selectedRequestID, removed.contains(selected) { selectedRequestID = nil }
        persist()
    }

    /// Sürükle-bırak canlı sıralama: sürüklenen koleksiyonu hedefin konumuna taşır.
    func moveCollection(_ id: UUID, before targetID: UUID) {
        guard id != targetID,
              let from = workspace.collections.firstIndex(id: id),
              let to = workspace.collections.firstIndex(id: targetID),
              // Koleksiyonsuz kap hep en üstte: ne taşınır ne önüne bir şey konur.
              workspace.collections[from].isRegular,
              workspace.collections[to].isRegular else { return }
        workspace.collections.move(
            fromOffsets: IndexSet(integer: from),
            toOffset: to > from ? to + 1 : to
        )
        persist()
    }

    func addEnvironment() -> UUID {
        let environment = EnvironmentModel()
        workspace.environments.append(environment)
        if workspace.activeEnvironmentID == nil {
            workspace.activeEnvironmentID = environment.id
        }
        persist()
        return environment.id
    }

    func deleteEnvironment(_ id: UUID) {
        workspace.environments.removeAll { $0.id == id }
        if workspace.activeEnvironmentID == id {
            workspace.activeEnvironmentID = workspace.environments.first?.id
        }
        persist()
    }

    // MARK: Tanımsız değişkene değer verme

    /// Değeri verilecek değişken ve hedef environment (`VariableDefinition`).
    struct VariableDefinitionRequest: Equatable {
        let key: String
        let target: VariableDefinition.Target
    }

    /// Alandaki tanımsız `{{ad}}`e tıklanınca: anahtar çıkarılır, hedef
    /// environment belirlenir ve Environment'lar penceresi açılır. Burada
    /// hiçbir şey yazılmaz; yeni değişken kullanıcı kaydedince eklenir.
    func defineVariable(_ name: String) {
        guard let key = VariableDefinition.key(from: name) else { return }
        variableDefinitionRequest = VariableDefinitionRequest(
            key: key,
            target: VariableDefinition.target(activeID: workspace.activeEnvironmentID, environments: workspace.environments)
        )
        environmentsRequest += 1
    }

    func takeVariableDefinitionRequest() -> VariableDefinitionRequest? {
        defer { variableDefinitionRequest = nil }
        return variableDefinitionRequest
    }

    /// Taslağı kaydeder; `environmentID` yoksa yeni environment oluşturulur.
    /// Etkin environment yoksa kaydedilen etkin olur: değer açık istekte
    /// hemen çözülsün. Dönen değer değişkenin yazıldığı environment.
    @discardableResult
    func saveVariable(key: String, value: String, environmentID: UUID?) throws -> UUID {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { throw VariableDefinition.SaveError.emptyKey }
        let id: UUID
        if let environmentID, workspace.environments.contains(where: { $0.id == environmentID }) {
            id = environmentID
        } else {
            let environment = EnvironmentModel(name: "Environment")
            workspace.environments.append(environment)
            id = environment.id
        }
        guard let index = workspace.environments.firstIndex(id: id) else { return id }
        do {
            try VariableDefinition.add(key: key, value: value, to: &workspace.environments[index])
        } catch {
            // Yeni oluşturulan boş environment yarım kalmasın.
            if environmentID == nil { workspace.environments.remove(at: index) }
            throw error
        }
        if activeEnvironment == nil {
            workspace.activeEnvironmentID = id
        }
        persist()
        return id
    }

    func environmentBinding(_ id: UUID) -> Binding<EnvironmentModel>? {
        guard let index = workspace.environments.firstIndex(id: id) else { return nil }
        let fallback = workspace.environments[index]
        return Binding(
            // Index saklanmaz: environment silinince eski index başka kaydı ezerdi.
            get: {
                self.workspace.environments.first { $0.id == id } ?? fallback
            },
            set: { newValue in
                guard let current = self.workspace.environments.firstIndex(id: id) else { return }
                self.workspace.environments[current] = newValue
                self.persistSoon()
            }
        )
    }

    /// Aktif environment'ta bu adda değişken yoksa ekler. Var olanın değeri
    /// değiştirilmez: kullanıcının girdiği adres içe aktarmayla ezilmesin.
    func addVariableToActiveEnvironmentIfMissing(_ name: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = workspace.environments.firstIndex(where: { $0.id == workspace.activeEnvironmentID }),
              !workspace.environments[index].variables.contains(where: { $0.key == name }) else { return }
        workspace.environments[index].variables.append(KeyValueEntry(key: name, value: trimmed))
        persist()
    }
}
