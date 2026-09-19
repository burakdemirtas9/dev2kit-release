// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Secora",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // UI'dan bağımsız çekirdek: modeller, istek motoru, keychain, persistence.
        // Tüm birim testleri bu hedefe yazılır.
        .target(
            name: "SecoraCore",
            path: "Sources/SecoraCore"
        ),
        // SwiftUI uygulaması. `swift run SecoraApp` ile geliştirme modunda açılır.
        .executableTarget(
            name: "SecoraApp",
            dependencies: ["SecoraCore"],
            path: "Sources/SecoraApp",
            // Kaynak görsel ikonu yeniden üretmek, entitlements ise imzalama
            // için repoda durur; ikisi de bundle'a gömülmez.
            exclude: ["Resources/AppIcon.png", "Resources/Secora.entitlements"],
            // İkon: .app bundle'ına make-app.sh kopyalar; `swift run` ile
            // bundle olmadan çalışırken Dock ikonu Bundle.module'den yüklenir.
            resources: [.copy("Resources/AppIcon.icns")]
        ),
        .testTarget(
            name: "SecoraCoreTests",
            dependencies: ["SecoraCore"],
            path: "Tests/SecoraCoreTests"
        ),
    ]
)
