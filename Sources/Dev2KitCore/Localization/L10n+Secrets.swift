// Metinler: anahtar → (Türkçe, English). Bkz. L10n.swift, docs/LOCALIZATION.md.

extension L10nTable {
    static let secrets: [String: L10nEntry] = [
        "secrets.subtitle": L10nEntry("Değerler AES-GCM ile şifrelenmiş yerel vault'ta saklanır; koleksiyon dosyalarına asla düz metin yazılmaz. Request'lerde {{secret:isim}} olarak kullan.", "Values are stored in a local vault encrypted with AES-GCM and are never written to collection files as plain text. Use them in requests as {{secret:name}}."),
        "secrets.name.placeholder": L10nEntry("ad (ör. api_token)", "name (e.g. api_token)"),
    ]
}
