// Metinler: anahtar → (Türkçe, English). Bkz. L10n.swift, docs/LOCALIZATION.md.
// Response örnekleri. Kenar çubuğundaki "(e.g.)" göstergesi bilinçli olarak
// burada DEĞİL: iki dilde de aynı kalır (`ResponseExamples.badge`).

extension L10nTable {
    static let examples: [String: L10nEntry] = [
        // Kenar çubuğunda katlama (örnekler varsayılan olarak katlı)
        "example.fold.show": L10nEntry("Örnekleri Göster", "Show Examples"),
        "example.fold.hide": L10nEntry("Örnekleri Gizle", "Hide Examples"),
        "example.count.one": L10nEntry("%1$@ örnek", "%1$@ example"),
        "example.count.other": L10nEntry("%1$@ örnek", "%1$@ examples"),
        // Kaydetme
        "example.save": L10nEntry("Örnek Olarak Kaydet", "Save as Example"),
        "example.save.help": L10nEntry("Bu response'u request'in altına örnek olarak kaydeder", "Saves this response as an example under the request"),
        "example.unavailable.truncated": L10nEntry("Response kesildi; eksik body örnek olarak kaydedilmez.", "The response was truncated; an incomplete body isn’t saved as an example."),
        "example.unavailable.tooLarge": L10nEntry("Body %1$@; örnek en fazla %2$@ olabilir.", "The body is %1$@; an example can be at most %2$@."),
        "example.unavailable.tokenFactory": L10nEntry("Token Factory response'ları token taşıdığı için örnek olarak kaydedilmez.", "Token Factory responses carry tokens, so they aren’t saved as examples."),
        "example.defaultName": L10nEntry("%1$@ response", "%1$@ response"),
        "example.defaultName.noStatus": L10nEntry("Örnek", "Example"),
        "example.sheet.title": L10nEntry("Response'u Örnek Olarak Kaydet", "Save Response as Example"),
        "example.sheet.name": L10nEntry("Ad", "Name"),
        "example.sheet.namePlaceholder": L10nEntry("Örnek adı", "Example name"),
        "example.sheet.masked": L10nEntry("Kimlik bilgisi taşıyan header'lar (Authorization, Set-Cookie…) ve body'deki token/parola alanları maskelenerek kaydedilir.", "Headers that carry credentials (Authorization, Set-Cookie…) and token/password fields in the body are masked when saved."),
        "example.sheet.saved": L10nEntry("Kayıtlı örnekler", "Saved Examples"),
        "example.sheet.count": L10nEntry("%1$@ / %2$@", "%1$@ of %2$@"),
        "example.sheet.snapshotKept": L10nEntry("Kaydedilecek response korunuyor. Bir örneği silince kaydetmeye devam edebilirsin.", "The response to save is kept. Delete an example to continue saving."),

        // Sınır
        "example.limit.title": L10nEntry("Örnek sınırına ulaşıldı", "Example Limit Reached"),
        "example.limit.message": L10nEntry("Bu request için en fazla 5 örnek kaydedebilirsiniz. Yeni bir örnek kaydetmek için mevcut örneklerden birini silin.", "You can save up to 5 examples per request. Delete an existing example to save a new one."),
        "example.limit.manage": L10nEntry("Örnekleri Yönet…", "Manage Examples…"),

        // Yönetim
        "example.rename": L10nEntry("Yeniden Adlandır…", "Rename…"),
        "example.rename.title": L10nEntry("Örneği Yeniden Adlandır", "Rename Example"),
        "example.rename.confirm": L10nEntry("Yeniden Adlandır", "Rename"),
        "example.delete": L10nEntry("Örneği Sil", "Delete Example"),
        "example.delete.title": L10nEntry("“%1$@” örneği silinsin mi?", "Delete the “%1$@” example?"),
        "example.delete.help": L10nEntry("Bu örneği sil", "Delete this example"),

        // Görünüm
        "example.banner.title": L10nEntry("Kayıtlı örnek", "Saved example"),
        "example.banner.detail": L10nEntry("Canlı response değil; %1$@ tarihinde kaydedildi. Request'i göndermek için Dene'ye bas.", "Not a live response; saved on %1$@. Press Try to go back and send the request."),
        "example.parent": L10nEntry("“%1$@” request'inin örneği", "Example of the “%1$@” request"),
        "example.try": L10nEntry("Dene", "Try"),
        "example.try.help": L10nEntry("Request düzenleyicisine döner; hiçbir şey gönderilmez", "Goes back to the request editor; nothing is sent"),
        "example.emptyBody": L10nEntry("Body boş", "Empty body"),
        "example.preparing": L10nEntry("Örnek hazırlanıyor…", "Preparing example…"),
        "example.contentType": L10nEntry("Content-Type: %1$@", "Content-Type: %1$@"),
        "example.accessibility": L10nEntry("Örnek: %1$@, status %2$@", "Example: %1$@, status %2$@"),

        // Request tarafı ve düzenleme
        "example.request.title": L10nEntry("Request", "Request"),
        "example.response.title": L10nEntry("Response", "Response"),
        "example.request.missing": L10nEntry("Bu örnekte request kaydı yok (özellik gelmeden önce kaydedildi). Düzenle ile ekleyebilirsin.", "This example has no request recorded (it was saved before this feature). You can add one with Edit."),
        "example.request.add": L10nEntry("Request Ekle", "Add Request"),
        "example.request.masked": L10nEntry("Kimlik bilgileri maskeli; {{değişken}}ler çözülmemiş haliyle.", "Credentials are masked; {{variables}} are kept unresolved."),
        "example.edit": L10nEntry("Düzenle", "Edit"),
        "example.edit.help": L10nEntry("Örneğin request ve response'unu düzenle; değişiklikler kendiliğinden kaydedilir", "Edit the example’s request and response; changes are saved automatically"),
        "example.edit.done": L10nEntry("Bitti", "Done"),
        "example.status": L10nEntry("Status", "Status"),
        "example.status.placeholder": L10nEntry("ör. 200", "e.g. 200"),
        "example.body.binary": L10nEntry("Body metin değil (%1$@); düzenlenemez, olduğu gibi korunur.", "The body isn’t text (%1$@); it can’t be edited and is kept as is."),
        "example.tab.body": L10nEntry("Body", "Body"),
        "example.tab.headers": L10nEntry("Headers", "Headers"),
        "example.tab.params": L10nEntry("Params", "Params"),

        // Postman dışa aktarma
        "collection.exportPostman": L10nEntry("Postman Olarak Dışa Aktar…", "Export as Postman…"),
        "export.panel.postman": L10nEntry("Koleksiyonu Postman Olarak Dışa Aktar", "Export Collection as Postman"),
        "postmanExport.oauth2": L10nEntry("OAuth2 yapılandırması Postman'e taşınmadı (biçimleri farklı): %1$@", "The OAuth2 configuration wasn’t carried over to Postman (the formats differ): %1$@"),
        "postmanExport.binaryExample": L10nEntry("Metin olmayan örnek body'si taşınmadı (Postman örnekleri metin): %1$@", "A non-text example body wasn’t carried over (Postman examples are text): %1$@"),
        "postmanExport.disabledQuery": L10nEntry("Kapalı query parametreleri taşınmadı (adreste yoklar): %1$@", "Disabled query parameters weren’t carried over (they’re not in the URL): %1$@"),
        "postmanExport.options": L10nEntry("İstek ayarları (zaman aşımı, yönlendirme, çerez) Postman'e taşınmadı: %1$@", "Request settings (timeout, redirects, cookies) weren’t carried over to Postman: %1$@"),
        "postmanExport.more.one": L10nEntry("ve %1$@ tane daha", "and %1$@ more"),
        "postmanExport.more.other": L10nEntry("ve %1$@ tane daha", "and %1$@ more"),

        // İçe / dışa aktarma
        "example.import.invalidBody": L10nEntry("body çözümlenemedi (geçersiz base64)", "the body couldn’t be decoded (invalid base64)"),
        "example.import.skipped": L10nEntry("“%1$@” request'inin “%2$@” örneği alınmadı: %3$@", "The “%2$@” example of the “%1$@” request wasn’t imported: %3$@"),
        "example.import.unreadable.one": L10nEntry("“%2$@” request'inde %1$@ örnek okunamadı (biçimi bozuk); alınmadı.", "%1$@ example of the “%2$@” request couldn’t be read (malformed) and wasn’t imported."),
        "example.import.unreadable.other": L10nEntry("“%2$@” request'inde %1$@ örnek okunamadı (biçimi bozuk); alınmadı.", "%1$@ examples of the “%2$@” request couldn’t be read (malformed) and weren’t imported."),
        "example.import.overLimit.title": L10nEntry("Örnek sınırı aşılıyor", "Too Many Examples"),
        "example.import.overLimit.detail": L10nEntry("Request başına en fazla %1$@ örnek alınabilir. Aşağıdaki request'ler için alınacak örnekleri seç; seçilmeyenler alınmaz.", "Up to %1$@ examples can be imported per request. Choose which examples to import for the requests below; the rest won’t be imported."),
        "example.import.selected": L10nEntry("%1$@ / %2$@ seçili", "%1$@ of %2$@ selected"),
        "example.import.tooMany": L10nEntry("En fazla %1$@ örnek seçebilirsin.", "You can select up to %1$@ examples."),
        "example.export.included.one": L10nEntry("%1$@ response örneği dosyaya eklendi (kimlik bilgileri maskeli).", "%1$@ response example was included (credentials masked)."),
        "example.export.included.other": L10nEntry("%1$@ response örneği dosyaya eklendi (kimlik bilgileri maskeli).", "%1$@ response examples were included (credentials masked)."),
    ]
}
