import SwiftUI
import Dev2KitCore

/// Bağlantının teknik künyesi: hangi protokolle, nereye bağlanıldı, TLS
/// pazarlığı ne çıktı ve sunucu hangi sertifikayı sundu.
///
/// Neden pano (popover), neden durum çubuğunda değil: yerel ve uzak IP'ler
/// dahili ağ bilgisidir; ekran görüntüsü paylaşılırken varsayılan olarak
/// görünmemeleri daha güvenli. İsteyen tıklayıp görür.
///
/// Kurum CA'sı ve mTLS kullanan bir araçta bu pano ayrıca doğrulama aracıdır:
/// yapılandırdığın TLS profilinin gerçekten devrede olduğunu buradan görürsün.
struct NetworkPopover: View {
    let info: NetworkInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.t("network.title"), systemImage: "network")
                .font(.headline)

            section([
                (L10n.t("network.httpVersion"), info.httpVersion),
                (L10n.t("network.localAddress"), info.localAddress),
                (L10n.t("network.remoteAddress"), info.remoteAddress),
            ])

            let tls = section([
                (L10n.t("network.tlsProtocol"), info.tlsProtocol),
                (L10n.t("network.cipher"), info.cipherName),
                (L10n.t("network.connection"), connectionNote),
            ])
            if hasAny([info.tlsProtocol, info.cipherName, connectionNote]) {
                Divider()
                tls
            }

            if let certificate = info.certificate {
                Divider()
                section([
                    (L10n.t("network.certificateCN"), certificate.commonName),
                    (L10n.t("network.issuerCN"), certificate.issuerCommonName),
                ])
                if let validUntil = certificate.validUntil {
                    row(
                        L10n.t("network.validUntil"),
                        L10n.date(validUntil),
                        warning: certificate.isExpired()
                    )
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    /// "yeniden kullanıldı" bilgisi el sıkışma maliyetinin neden görünmediğini
    /// açıklar; proxy bilgisi kurumsal ağda beklenen ama doğrulanması gereken şey.
    private var connectionNote: String? {
        var parts: [String] = []
        if info.isReusedConnection == true { parts.append(L10n.t("network.reused")) }
        if info.isProxyConnection == true { parts.append(L10n.t("network.viaProxy")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func hasAny(_ values: [String?]) -> Bool {
        values.contains { $0?.isEmpty == false }
    }

    @ViewBuilder
    private func section(_ rows: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.filter { $0.1?.isEmpty == false }, id: \.0) { title, value in
                row(title, value ?? "")
            }
        }
    }

    private func row(_ title: String, _ value: String, warning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.secondaryText)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.secondaryMono)
                .foregroundStyle(warning ? Theme.down : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
