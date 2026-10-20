import AppKit
import SwiftUI
import Dev2KitCore

/// Mesaj türlerinin görünümü (docs/TASARIM.md "Mesaj tipleri"). Renk tek
/// başına taşımaz: her türün ikon şekli ayrı ve ekran okuyucuya adı söylenir.
/// Mor yalnızca marka vurgusu ve birincil eylem; hata ya da uyarı değil.
extension MessageKind {
    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: return Theme.accent
        case .success: return Theme.up
        case .warning: return Theme.warning
        case .error: return Theme.down
        }
    }

    /// Satır ve şerit zemini: bilgi nötr, uyarı ve hata hafif tonlu.
    var background: Color {
        switch self {
        case .info, .success: return Color.primary.opacity(0.05)
        case .warning: return Theme.warning.opacity(0.12)
        case .error: return Theme.down.opacity(0.10)
        }
    }

    var accessibilityName: String {
        switch self {
        case .info: return "Bilgi"
        case .success: return "Başarılı"
        case .warning: return "Uyarı"
        case .error: return "Hata"
        }
    }
}

/// Tür ikonu (erişilebilirlik adıyla).
struct MessageIcon: View {
    let kind: MessageKind

    var body: some View {
        Image(systemName: kind.symbol)
            .foregroundStyle(kind.tint)
            .accessibilityLabel(kind.accessibilityName)
    }
}

/// İşlem sonucu penceresi (içe/dışa aktarma, açılış uyarısı). Sistem
/// alert'i türe göre ikon/renk alamadığı için bilgi, başarı ve uyarı burada;
/// gerçek hatalar sistem alert'inde kalır (`ContentView`).
struct ResultSheet: View {
    let message: ResultMessage
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                MessageIcon(kind: message.kind)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = message.message {
                        Text(detail)
                            .font(.secondaryText)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !message.lines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(message.lines.enumerated()), id: \.offset) { _, line in
                            MessageLineRow(line: line)
                        }
                    }
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if let url = message.revealURL {
                    Button("Finder'da Göster") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Button("Tamam", action: onDismiss)
                    .buttonStyle(PrimaryActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onExitCommand(perform: onDismiss)
    }
}

/// Sonuç penceresinin bir satırı.
struct MessageLineRow: View {
    let line: MessageLine

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            MessageIcon(kind: line.kind)
                .font(.secondaryText)
            Text(line.text)
                .font(.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(line.kind.background, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

/// Satır içi şerit: tür ikonu, kısa başlık, açıklama, türlü alt satırlar ve
/// eylemler. TLS önerisi, token yenileme önerisi bunu kullanır.
struct MessageBanner<Actions: View>: View {
    let kind: MessageKind
    let title: String
    var message: String?
    var lines: [MessageLine] = []
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MessageIcon(kind: kind)
                Text(title)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let message {
                    Text(message)
                        .font(.secondaryText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        MessageIcon(kind: line.kind)
                        Text(line.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.secondaryText)
                    .accessibilityElement(children: .combine)
                }
                HStack(spacing: 8) { actions }
                    .padding(.top, 2)
            }
            .padding(.leading, 24)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}
