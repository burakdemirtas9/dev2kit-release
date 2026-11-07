import AppKit

/// Mac'in kullanıcıdan uzaklaştığı ve geri döndüğü anlar: uyku, ekran uykusu,
/// oturum değişimi (kullanıcı değiştirme), ekran kilidi.
///
/// Ortak (2026-11-07): donma bekçisi bu anlarda alarm vermez (`HangWatchdog`),
/// Mocker uyku ve kilitte kaynak korumak için kendini durdurur (`MockerState`).
enum SystemPresenceEvent: CaseIterable, Sendable {
    case willSleep
    case didWake
    case screensDidSleep
    case screensDidWake
    case sessionResigned
    case sessionActivated
    case screenLocked
    case screenUnlocked

    var notificationName: Notification.Name {
        switch self {
        case .willSleep: return NSWorkspace.willSleepNotification
        case .didWake: return NSWorkspace.didWakeNotification
        case .screensDidSleep: return NSWorkspace.screensDidSleepNotification
        case .screensDidWake: return NSWorkspace.screensDidWakeNotification
        case .sessionResigned: return NSWorkspace.sessionDidResignActiveNotification
        case .sessionActivated: return NSWorkspace.sessionDidBecomeActiveNotification
        // Ekran kilidi için AppKit sabiti yok; sistemin dağıtık bildirimi.
        case .screenLocked: return Notification.Name("com.apple.screenIsLocked")
        case .screenUnlocked: return Notification.Name("com.apple.screenIsUnlocked")
        }
    }

    var center: NotificationCenter {
        switch self {
        case .screenLocked, .screenUnlocked: return DistributedNotificationCenter.default()
        default: return NSWorkspace.shared.notificationCenter
        }
    }
}

/// Olayları dinler. `cancel()` ya da nesnenin bırakılmasıyla dinleme biter.
/// İşleyici bildirimi gönderen iş parçacığında çağrılır.
final class SystemPresenceObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(_ handler: @escaping @Sendable (SystemPresenceEvent) -> Void) {
        for event in SystemPresenceEvent.allCases {
            let token = event.center.addObserver(forName: event.notificationName, object: nil, queue: nil) { _ in
                handler(event)
            }
            tokens.append((event.center, token))
        }
    }

    func cancel() {
        lock.lock()
        let current = tokens
        tokens = []
        lock.unlock()
        for (center, token) in current { center.removeObserver(token) }
    }

    deinit { cancel() }
}
