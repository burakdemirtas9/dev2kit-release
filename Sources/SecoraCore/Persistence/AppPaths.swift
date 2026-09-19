import Foundation

/// Uygulamanın veri dizini.
public enum AppPaths {
    /// ~/Library/Application Support/Secora
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Secora")
    }
}
