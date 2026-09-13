// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BoltDock",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // UI'dan bağımsız çekirdek: modeller, istek motoru, keychain, persistence.
        // Tüm birim testleri bu hedefe yazılır.
        .target(
            name: "BoltDockCore",
            path: "Sources/BoltDockCore"
        ),
        // SwiftUI uygulaması. `swift run BoltDockApp` ile geliştirme modunda açılır.
        .executableTarget(
            name: "BoltDockApp",
            dependencies: ["BoltDockCore"],
            path: "Sources/BoltDockApp",
            // Kaynak görsel ikonu yeniden üretmek, entitlements ise imzalama
            // için repoda durur; ikisi de bundle'a gömülmez.
            exclude: ["Resources/AppIcon.png", "Resources/BoltDock.entitlements"],
            // İkon: .app bundle'ına make-app.sh kopyalar; `swift run` ile
            // bundle olmadan çalışırken Dock ikonu Bundle.module'den yüklenir.
            resources: [.copy("Resources/AppIcon.icns")]
        ),
        .testTarget(
            name: "BoltDockCoreTests",
            dependencies: ["BoltDockCore"],
            path: "Tests/BoltDockCoreTests"
        ),
    ]
)
