// Metinler: anahtar → (Türkçe, English). Bkz. L10n.swift, docs/LOCALIZATION.md.

extension L10nTable {
    static let secrets: [String: L10nEntry] = [
        "secrets.subtitle.keychain": L10nEntry("Değerler macOS Keychain'de saklanır; başka bir uygulama okumak isterse macOS sorar. Koleksiyon dosyalarına asla düz metin yazılmaz. Request'lerde {{secret:isim}} olarak kullan.", "Values are stored in the macOS Keychain; if another app tries to read them, macOS asks first. They’re never written to collection files as plain text. Use them in requests as {{secret:name}}."),
        "secrets.subtitle.file": L10nEntry("Bu derleme imzasız: değerler AES-GCM ile şifreli bir dosyada, anahtarı aynı klasörde durur. Bu, dosyanın paylaşılmasına ve yedeğe gitmesine karşı korur; bu Mac'te senin hesabınla çalışan programlara karşı korumaz. Kurumda imzalı paketi kullan. Koleksiyon dosyalarına asla düz metin yazılmaz. Request'lerde {{secret:isim}} olarak kullan.", "This build is unsigned: values are in an AES-GCM encrypted file with its key in the same folder. That protects against sharing the file and against backups, not against programs running under your account on this Mac. At work, use the signed package. They’re never written to collection files as plain text. Use them in requests as {{secret:name}}."),
        "secrets.name.placeholder": L10nEntry("ad (ör. api_token)", "name (e.g. api_token)"),
    ]
}
