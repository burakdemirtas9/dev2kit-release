# dev2kit

macOS için yerel çalışan, güvenlik öncelikli API istemcisi ve geliştirici araç kutusu.

**Sürüm:** 1.2 (179) · **Platform:** macOS 14+ · **Dil:** Swift / SwiftUI · **Harici bağımlılık:** yok

---

## Ne yapar

dev2kit iki moddan oluşur:

- **API Client** — REST isteklerini hazırlar, gönderir ve yanıtları inceler;
  koleksiyonlar, environment'lar, kayıtlı response örnekleri, geçmiş ve
  kurumsal TLS desteğiyle.
- **Workbench** — biçimlendirme, dönüştürme, kodlama ve karşılaştırma
  araçları. Tamamen çevrimdışı çalışır: girdi makineden çıkmaz, diske
  yazılmaz.

## Neden

- **Yerel öncelikli.** Hesap, bulut senkronu ve telemetri yok. Veriler
  yalnızca kullanıcının makinesinde. Uygulama, kullanıcının istek gönderdiği
  adresler dışında yalnızca kullanıcı açıkça isterse ağa çıkar (Postman
  hesabından içe aktarma, OpenAPI dokümanı indirme).
- **Secret'lar koleksiyonda durmaz.** İsteklerde `{{secret:ad}}` referansı
  bulunur; değer şifreli vault'ta tutulur ve yalnızca gönderim anında
  çözülür. Koleksiyon dosyaları okunabilir JSON'dur ve güvenle paylaşılabilir.
- **Güvenli varsayılanlar.** Gönderim öncesi denetim, yönlendirmede kimlik
  başlıklarının düşürülmesi, https → http düşüşünün engellenmesi, yönetici
  host politikası.

---

## Özellikler

### API Client

- Tüm HTTP metotları; raw (JSON, XML, HTML, JavaScript, metin),
  `x-www-form-urlencoded` ve `multipart/form-data` gövde.
- Kimlik doğrulama: Basic, Bearer, API key, OAuth2 (authorization code + PKCE).
- **Token Factory:** herhangi bir isteğin yanıtından token üretip
  `{{token}}` değişkeni olarak diğer isteklere bağlar; token yalnızca
  bellekte tutulur, süresi dolmadan yenilenir.
- Environment'lar ve değişkenler, `{{` yazınca öneri.
- Koleksiyonlar, sekmeler, sürükle-sırala, arama (⌘F), "son gönderilenden
  farklı" işareti ve o hale dönüş, otomatik kayıt.
- Yanıt: renklendirilmiş ve katlanabilir gövde, başlıklar, yönlendirme
  zinciri, zaman kırılımı (DNS, TCP, TLS, bekleme, indirme), boyut ayrıntısı,
  bağlantı künyesi, HTML / görsel / PDF önizleme (yalıtılmış: JavaScript
  kapalı, dış kaynak yüklenmez).
- **Response örnekleri:** yanıt, onu üreten request ile birlikte isteğin
  altına kaydedilir (istek başına en çok 5); iki tarafı da düzenlenebilir.
- Şifreli istek geçmişi; kimlik bilgileri maskelenerek saklanır.

### Workbench

- **Biçimlendir / doğrula:** JSON, XML, HTML, CSS, SQL, Markdown.
- **Dönüştür:** JSON → CSV / XML / YAML; YAML ↔ Properties; JSON → Java,
  Kotlin, Swift, TypeScript, Python model kodu.
- **Kodla / çöz:** JWT, Base64, URL, Hex; zaman damgası; UUID (v4, v7); hash.
- **Sorgu:** JSONPath.
- **Karşılaştır:** satır bazlı Diff Checker.

### İçe / dışa aktarma

- İçe aktarma: Postman v2.x (dosya ya da hesap), cURL, dev2kit koleksiyonu,
  Swagger / OpenAPI (adres, dosya ya da yapıştırma), Kibana istek logu,
  kaynak koddan giden istekler (Feign, RestTemplate, WebClient, RestClient,
  HTTP Interface).
- Her içe aktarma bir **inceleme ekranından** geçer: şema, host politikası,
  düz metin kimlik bilgisi ve şüpheli adres bulguları gösterilir; kesin
  engelli istekler alınmaz.
- Dışa aktarma: dev2kit koleksiyonu, Postman Collection v2.1, cURL.

### Kurumsal TLS

- **Güven deposu:** kurum CA'ları tüm host'lar için sistem köklerine ek
  güven çıpası olarak.
- **Host profilleri:** belirli host'lar için ek CA, sertifika sabitleme ve
  istemci sertifikası (mTLS).
- TLS hatasında sistemin gerekçesi ve sunucu sertifikasının adları
  gösterilir; benzer profil varsa eklenmesi önerilir (kendiliğinden
  genişletilmez).

---

## Güvenlik modeli

| Konu | Davranış |
|---|---|
| Secret'lar | Şifreli vault'ta; koleksiyonda yalnızca `{{secret:ad}}` referansı |
| Gönderim öncesi denetim | http/https dışı şema, politika dışı host, görünmez karakter ve başlıkta CR/LF **engellenir**; şifresiz kimlik bilgisi, bulut metadata adresi, IDN alan adı, secret'ın yeni bir host'a gitmesi **onay ister** |
| Yönlendirme | Farklı host'a geçişte kimlik başlıkları düşürülür; https → http engellenir |
| Yönetici host politikası | `/Library/Application Support/dev2kit/policy.json` (root'a ait); yalnızca listedeki host'lara istek gönderilir. Bozuk dosyada tüm gönderimler durur. Örnek: `docs/policy/policy.example.json` |
| TLS | Doğrulama her zaman çalışır; kurum CA'sı yalnızca ek çıpadır |
| Geçmiş | Şifreli; kimlik bilgileri maskeli |
| Yanıtlar | Bellekte; kullanıcı kaydetmedikçe diske yazılmaz |
| Workbench | Çevrimdışı; girdi diske yazılmaz, pano kendiliğinden okunmaz |
| Telemetri | Yok |

---

## Gereksinimler

- macOS 14 veya üzeri
- Xcode 26 (Swift 5.9+)

## Derleme ve çalıştırma

```sh
swift build                 # derle
swift test                  # tüm testler
swift run Dev2KitApp        # geliştirme modunda aç
./scripts/make-app.sh       # build/dev2kit.app üret
```

Testler iki arayüz diliyle de çalıştırılabilir:

```sh
DEV2KIT_LANGUAGE=tr swift test
DEV2KIT_LANGUAGE=en swift test
```

Testler kullanıcının gerçek verisine dokunmaz; her test geçici bir veri
dizininde çalışır.

## İmza ve dağıtım

`make-app.sh`, Developer ID sertifikası varsa uygulamayı Hardened Runtime
ile imzalar ve `scripts/notarize.sh` ile notarization'a hazırlar; yoksa
ad-hoc imzalar. Ad-hoc imzalı uygulama yalnızca derlendiği makinede
sorunsuz açılır, başka bir Mac'te Gatekeeper tarafından engellenir.

---

## Veri konumu

```
~/Library/Application Support/dev2kit/     dizinler 0700, dosyalar 0600
├── store/            workspace: koleksiyonlar, örnekler, environment'lar, ayarlar
├── history/          şifreli istek geçmişi
├── backups/          son sağlam workspace kopyaları
├── cacerts/          kullanıcı güven deposu
└── diagnostics/      yerel tanılama (hiçbir yere gönderilmez)
```

Kayıt yalnızca değişen dosyaları yazar; çok dosyalı kayıt günlükle
yapılır, yarıda kalırsa açılışta tamamlanır. Okunamayan dosya silinmez,
karantinaya alınır ve son sağlam yedek yüklenir.

## Proje yapısı

```
Sources/
  Dev2KitCore/   arayüzden bağımsız çekirdek: modeller, ağ, güvenlik,
                 TLS, içe/dışa aktarma, kayıt, Workbench araçları
  Dev2KitApp/    SwiftUI arayüz
Tests/
  Dev2KitCoreTests/
  Dev2KitAppTests/
scripts/
  make-app.sh    .app paketi
  notarize.sh    notarization
```

Davranış kuralları `Dev2KitCore`'da saf tipler olarak yazılır ve testlenir;
arayüz katmanı yalnızca bunları çağırır.
