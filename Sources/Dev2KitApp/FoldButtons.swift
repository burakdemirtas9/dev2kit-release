import SwiftUI
import Dev2KitCore

/// "Tümünü kapat / tümünü aç" düğmeleri.
///
/// Katlanabilir bölge yoksa hiç görünmez: düz metinde ya da tek satırlık
/// JSON'da çalışmayan düğme göstermek kullanıcıyı yanıltır.
///
/// İki ayrı düğme, tek bir geçiş düğmesi değil: elle bazı blokları katlamış
/// kullanıcıda "geçiş" hangi yöne gideceği belirsiz olurdu.
struct FoldButtons: View {
    @ObservedObject var folding: CodeFoldingController

    var body: some View {
        if folding.isAvailable {
            HStack(spacing: 2) {
                Button {
                    folding.collapseAll()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .iconHitTarget(20)
                }
                .help(L10n.t("fold.collapseAll"))
                .accessibilityLabel(L10n.t("fold.collapseAll"))

                Button {
                    folding.expandAll()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .iconHitTarget(20)
                }
                .help(L10n.t("fold.expandAll"))
                .accessibilityLabel(L10n.t("fold.expandAll"))
                .disabled(!folding.hasFolded)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}
