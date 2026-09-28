// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dev2Kit",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // UI'dan bağımsız çekirdek: modeller, istek motoru, keychain, persistence.
        // Tüm birim testleri bu hedefe yazılır.
        .target(
            name: "Dev2KitCore",
            path: "Sources/Dev2KitCore"
        ),
        // SwiftUI uygulaması. `swift run Dev2KitApp` ile geliştirme modunda açılır.
        .executableTarget(
            name: "Dev2KitApp",
            dependencies: ["Dev2KitCore"],
            path: "Sources/Dev2KitApp",
            // Kaynak görsel ikonu yeniden üretmek, entitlements ise imzalama
            // için repoda durur; ikisi de bundle'a gömülmez.
            exclude: ["Resources/AppIcon.png", "Resources/Dev2Kit.entitlements"],
            // İkon: .app bundle'ına make-app.sh kopyalar; `swift run` ile
            // bundle olmadan çalışırken Dock ikonu Bundle.module'den yüklenir.
            resources: [.copy("Resources/AppIcon.icns")]
        ),
        .testTarget(
            name: "Dev2KitCoreTests",
            dependencies: ["Dev2KitCore"],
            path: "Tests/Dev2KitCoreTests"
        ),
        // Arayüz katmanı testleri. `AppState` uzun süre test edilmiyordu ve
        // bunun bedeli ödendi: bir refactor uygulamayı açılışta çökertti,
        // Core'daki 488 testin hiçbiri yakalamadı.
        .testTarget(
            name: "Dev2KitAppTests",
            dependencies: ["Dev2KitApp", "Dev2KitCore"],
            path: "Tests/Dev2KitAppTests"
        ),
    ]
)
