import Foundation

/// Uygulamanın veri dizini.
public enum AppPaths {
    /// ~/Library/Application Support/dev2kit
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("dev2kit")
    }
}
