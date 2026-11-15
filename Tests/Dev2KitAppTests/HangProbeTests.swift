import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// GEÇİCİ ölçüm (donma araştırması, 2026-10-31): gerçek ana pencere ekran
/// dışında, çok header'lı isteklerde gezinme. Yalnızca PROBE_LOG verilince çalışır.
@MainActor
final class HangProbeTests: XCTestCase {
    private var logHandle: FileHandle?

    private func log(_ line: String) {
        guard let logHandle else { return }
        logHandle.write((line + "\n").data(using: .utf8)!)
        try? logHandle.synchronize()
    }

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func headers(seed: Int, count: Int) -> [KeyValueEntry] {
        let long = String(repeating: "abcdefghij", count: 200)
        return (0..<count).map { i in
            let value: String
            switch (seed + i) % 6 {
            case 0: value = "Bearer {{token}}"
            case 1: value = "{{host}}/v1/{{id}}/items"
            case 2: value = "{{missing_\(i)}}"
            case 3: value = "{{secret:apiKey}}"
            case 4: value = long + "{{token}}" + long
            default: value = "application/json; charset=utf-8"
            }
            return KeyValueEntry(key: "X-Header-\(i)", value: value)
        }
    }

    func testNavigatingRequestsWithManyHeaders() throws {
        guard let path = ProcessInfo.processInfo.environment["PROBE_LOG"] else {
            throw XCTSkip("yalnızca PROBE_LOG ile")
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        logHandle = FileHandle(forWritingAtPath: path)
        defer { try? logHandle?.close() }

        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let state = harness.state
        let requestCount = Int(ProcessInfo.processInfo.environment["PROBE_REQUESTS"] ?? "") ?? 30
        let headerCount = Int(ProcessInfo.processInfo.environment["PROBE_HEADERS"] ?? "") ?? 40

        _ = state.addEnvironment()
        state.workspace.environments[0].variables = [
            KeyValueEntry(key: "token", value: "abc.def.ghi"),
            KeyValueEntry(key: "host", value: "https://api.example.com"),
            KeyValueEntry(key: "id", value: "42"),
        ]
        var ids: [UUID] = []
        for n in 0..<requestCount {
            let request = harness.addRequest(named: "R\(n)", url: "{{host}}/v1/items/{{id}}?q=\(n)")
            let index = state.workspace.collections[0].requests.firstIndex { $0.id == request.id }!
            state.workspace.collections[0].requests[index].headers = headers(seed: n, count: headerCount)
            state.workspace.collections[0].requests[index].body = .raw(
                content: "{\n  \"name\": \"{{name}}\",\n  \"token\": \"{{token}}\",\n  \"items\": [1, 2, 3]\n}",
                contentType: "application/json"
            )
            ids.append(request.id)
        }
        state.editorTab = .headers

        let workbench = WorkbenchState()
        let host = NSHostingView(rootView: ContentView().environment(state).environment(workbench).frame(width: 1400, height: 900))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        pump(1.0)
        log("start footprint=\(Int(footprintMB()))MB requests=\(requestCount) headers=\(headerCount)")

        let rounds = Int(ProcessInfo.processInfo.environment["PROBE_ROUNDS"] ?? "") ?? 2
        for tab in [EditorTab.headers, .body, .headers] {
            state.editorTab = tab
            for round in 0..<rounds {
                let roundStart = Date()
                var worst = 0.0
                var worstIndex = -1
                for (i, id) in ids.enumerated() {
                    let t0 = Date()
                    autoreleasepool {
                        state.showRequest(id)
                        host.layoutSubtreeIfNeeded()
                    }
                    for _ in 0..<3 { autoreleasepool { pump(0.02) } }
                    let dt = Date().timeIntervalSince(t0)
                    if dt > worst { worst = dt; worstIndex = i }
                    if dt > 2 { log("  SLOW tab=\(tab) round=\(round) i=\(i) \(String(format: "%.2f", dt))s footprint=\(Int(footprintMB()))MB") }
                }
                log("tab=\(tab) round=\(round) total=\(String(format: "%.2f", Date().timeIntervalSince(roundStart)))s worst=\(String(format: "%.2f", worst))s@\(worstIndex) footprint=\(Int(footprintMB()))MB")
            }
        }
        log("done footprint=\(Int(footprintMB()))MB")
    }

    // MARK: - İstek arama maliyeti (2026-11-01)

    func testLookupCost() throws {
        guard let path = ProcessInfo.processInfo.environment["PROBE_LOG"] else { throw XCTSkip("PROBE_LOG") }
        FileManager.default.createFile(atPath: path, contents: nil)
        logHandle = FileHandle(forWritingAtPath: path)
        defer { try? logHandle?.close() }
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let state = harness.state
        // 20 koleksiyon × 100 istek, gövde 20 KB.
        let body = String(repeating: "x", count: 20_000)
        var collections: [CollectionModel] = []
        for c in 0..<20 {
            var collection = CollectionModel(name: "C\(c)")
            collection.requests = (0..<100).map { r in
                var request = RequestModel(name: "R\(c)-\(r)")
                request.body = .raw(content: body, contentType: "text/plain")
                request.headers = (0..<10).map { KeyValueEntry(key: "H\($0)", value: "v") }
                return request
            }
            collections.append(collection)
        }
        state.workspace.collections = collections
        let ids = collections.flatMap { $0.requests.map(\.id) }
        let last = ids[ids.count - 1]
        state.selectedRequestID = last

        func ms(_ n: Int, _ work: () -> Void) -> Double {
            let t0 = Date(); for _ in 0..<n { work() }; return Date().timeIntervalSince(t0) / Double(n) * 1_000_000
        }
        var rng = SystemRandomNumberGenerator()
        let lookup = ms(2_000) { _ = state.request(withID: ids.randomElement(using: &rng)!) }
        let lookupLast = ms(2_000) { _ = state.request(withID: last) }
        let binding = state.selectedRequest!
        let get = ms(2_000) { _ = binding.wrappedValue.name }
        let set = ms(500) { binding.wrappedValue.name = "R-last" }
        log(String(format: "requests=%d lookup(random)=%.1fµs lookup(last)=%.1fµs binding.get=%.1fµs binding.set=%.1fµs", ids.count, lookup, lookupLast, get, set))
    }

    func testTypingCost() throws {
        guard let path = ProcessInfo.processInfo.environment["PROBE_LOG"] else { throw XCTSkip("PROBE_LOG") }
        FileManager.default.createFile(atPath: path, contents: nil)
        logHandle = FileHandle(forWritingAtPath: path)
        defer { try? logHandle?.close() }
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let state = harness.state
        var collections: [CollectionModel] = []
        for c in 0..<20 {
            var collection = CollectionModel(name: "C\(c)")
            collection.requests = (0..<100).map { r in
                var request = RequestModel(name: "R\(c)-\(r)")
                request.headers = (0..<40).map { KeyValueEntry(key: "H\($0)", value: "v\($0)") }
                return request
            }
            collections.append(collection)
        }
        state.workspace.collections = collections
        let target = collections[19].requests[99].id
        state.showRequest(target)
        state.editorTab = .headers
        let workbench = WorkbenchState()
        let host = NSHostingView(rootView: ContentView().environment(state).environment(workbench).frame(width: 1400, height: 900))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<20 { autoreleasepool { pump(0.05) } }
        func cpuMs() -> Double {
            var ts = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
            return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
        }
        var idle: [Double] = []
        for _ in 0..<10 { let c0 = cpuMs(); for _ in 0..<5 { autoreleasepool { pump(0.01) } }; idle.append(cpuMs() - c0) }
        idle.sort()
        var edits: [Double] = []
        let binding = state.selectedRequest!
        let editCount = Int(ProcessInfo.processInfo.environment["PROBE_EDITS"] ?? "") ?? 40
        log("edits starting: \(editCount)")
        for i in 0..<editCount {
            let c0 = cpuMs()
            autoreleasepool { binding.wrappedValue.headers[i % 40].value = "typed-\(i)" }
            for _ in 0..<5 { autoreleasepool { pump(0.01) } }
            edits.append(cpuMs() - c0 - idle[5])
        }
        edits.sort()
        edits = Array(edits.prefix(40))
        log(String(format: "typing: requests=2000 headers=40 editCPU median=%.1fms p90=%.1fms", edits[20], edits[36]))
    }

    // MARK: - Sekme sürükleme gecikmesi (2026-10-31)

    func testTabMoveCost() throws {
        guard let path = ProcessInfo.processInfo.environment["PROBE_LOG"] else {
            throw XCTSkip("yalnızca PROBE_LOG ile")
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        logHandle = FileHandle(forWritingAtPath: path)
        defer { try? logHandle?.close() }

        for (label, requestCount, bodyKB) in [("small", 20, 1), ("large", 300, 100)] {
            let harness = AppStateHarness()
            let state = harness.state
            let body = String(repeating: "{\"k\":\"vvvvvvvvvv\"},\n", count: bodyKB * 1024 / 20)
            var ids: [UUID] = []
            for n in 0..<requestCount {
                let request = harness.addRequest(named: "R\(n)", url: "https://a.test/\(n)")
                let index = state.workspace.collections[0].requests.firstIndex { $0.id == request.id }!
                state.workspace.collections[0].requests[index].headers = (0..<20).map { KeyValueEntry(key: "H\($0)", value: "v\($0)") }
                state.workspace.collections[0].requests[index].body = .raw(content: body + "\(n)a", contentType: "application/json")
                var baseline = state.workspace.collections[0].requests[index]
                // Yarısı kirli: gövde sonda farklı (karşılaştırma tüm gövdeyi okur).
                if n.isMultiple(of: 2) { baseline.body = .raw(content: body + "\(n)b", contentType: "application/json") }
                state.workspace.sentBaselines[request.id.uuidString] = baseline
                ids.append(request.id)
            }
            let tabIDs = Array(ids.prefix(15))
            tabIDs.forEach { state.keepTab($0) }
            state.selectedRequestID = tabIDs[0]

            // 1) Kirlilik hesabı tek başına.
            var t0 = Date()
            for _ in 0..<20 { _ = state.dirtyRequestIDs }
            let dirtyMs = Date().timeIntervalSince(t0) / 20 * 1000

            // 1b) Görünümsüz: moveTab, saveTabs, request(withID:) ayrı ayrı.
            t0 = Date()
            for i in 0..<30 { state.moveTab(tabIDs[i % 15], before: tabIDs[(i + 7) % 15]) }
            let rawMoveMs = Date().timeIntervalSince(t0) / 30 * 1000
            t0 = Date()
            for _ in 0..<30 { state.saveTabs() }
            let saveMs = Date().timeIntervalSince(t0) / 30 * 1000
            t0 = Date()
            for _ in 0..<30 { for id in tabIDs { _ = state.request(withID: id) } }
            let lookupMs = Date().timeIntervalSince(t0) / 30 * 1000
            log("  \(label) raw: moveTab=\(String(format: "%.2f", rawMoveMs))ms saveTabs=\(String(format: "%.2f", saveMs))ms lookup15=\(String(format: "%.2f", lookupMs))ms")

            // 2) Pencerede taşıma + yeniden çizim.
            let workbench = WorkbenchState()
            let onlyBar = ProcessInfo.processInfo.environment["PROBE_ONLY_BAR"] != nil
            let root: AnyView = onlyBar
                ? AnyView(RequestTabBar().environment(state).frame(width: 1400))
                : AnyView(ContentView().environment(state).environment(workbench).frame(width: 1400, height: 900))
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<20 { autoreleasepool { pump(0.05) } }
            func cpuMs() -> Double {
                var ts = timespec()
                clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
                return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
            }
            // Boşta tur: aynı pompalama, değişiklik yok.
            var idle: [Double] = []
            for _ in 0..<10 {
                let c0 = cpuMs()
                for _ in 0..<5 { autoreleasepool { pump(0.01) } }
                idle.append(cpuMs() - c0)
            }
            idle.sort()
            var moves: [Double] = []
            let moveCount = label == "large" ? (Int(ProcessInfo.processInfo.environment["PROBE_MOVES"] ?? "") ?? 30) : 30
            if label == "large" { log("  large moves starting: \(moveCount)") }
            for i in 0..<moveCount {
                let a = tabIDs[i % 15], b = tabIDs[(i + 7) % 15]
                let c0 = cpuMs()
                autoreleasepool { state.moveTab(a, before: b) }
                for _ in 0..<5 { autoreleasepool { pump(0.01) } }
                moves.append(cpuMs() - c0 - idle[5])
            }
            log("  first moves: \(moves.prefix(4).map { String(format: "%.1f", $0) })")
            moves.sort()
            log("\(onlyBar ? "BAR " : "FULL ")\(label): requests=\(requestCount) body=\(bodyKB)KB dirty=\(String(format: "%.1f", dirtyMs))ms idleCPU=\(String(format: "%.1f", idle[5]))ms moveCPU median=\(String(format: "%.1f", moves[15]))ms p90=\(String(format: "%.1f", moves[27]))ms max=\(String(format: "%.1f", moves.last!))ms")
            window.orderOut(nil)
            harness.tearDown()
        }
    }

    // MARK: - Sınırı aşan değer (içe aktarmadan gelebilir)

    func testOversizedHeaderValues() throws {
        guard let path = ProcessInfo.processInfo.environment["PROBE_LOG"] else {
            throw XCTSkip("yalnızca PROBE_LOG ile")
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        logHandle = FileHandle(forWritingAtPath: path)
        defer { try? logHandle?.close() }

        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let state = harness.state
        _ = state.addEnvironment()
        state.workspace.environments[0].variables = [KeyValueEntry(key: "token", value: "t")]
        let normal = harness.addRequest(named: "normal", url: "https://a.test")
        let big = harness.addRequest(named: "big", url: "https://a.test")
        let bigIndex = state.workspace.collections[0].requests.firstIndex { $0.id == big.id }!
        state.editorTab = .headers

        let workbench = WorkbenchState()
        let host = NSHostingView(rootView: ContentView().environment(state).environment(workbench).frame(width: 1400, height: 900))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<10 { autoreleasepool { pump(0.05) } }

        let sizes = (ProcessInfo.processInfo.environment["PROBE_SIZES"] ?? "16384,65536,262144")
            .split(separator: ",").compactMap { Int($0) }
        let kinds = (ProcessInfo.processInfo.environment["PROBE_KINDS"] ?? "plain,variables,multiline")
            .split(separator: ",").map(String.init)
        for kind in kinds {
            for size in sizes {
                let value: String
                switch kind {
                case "variables":
                    // Her 64 karakterde bir değişken: vurgu katmanı çok parça çizer.
                    let chunk = String(repeating: "a", count: 55) + "{{token}}"
                    value = String(String(repeating: chunk, count: size / chunk.count + 1).prefix(size))
                case "multiline":
                    let line = String(repeating: "MIIBszCCAVmgAwIBAgIUQ", count: 3) + "\n"
                    value = String(String(repeating: line, count: size / line.count + 1).prefix(size))
                default:
                    value = String(repeating: "abcdefghij", count: size / 10)
                }
                state.workspace.collections[0].requests[bigIndex].headers = [KeyValueEntry(key: "X-Big", value: value)]
                autoreleasepool { state.showRequest(normal.id); host.layoutSubtreeIfNeeded() }
                for _ in 0..<5 { autoreleasepool { pump(0.02) } }
                let before = footprintMB()
                log("→ \(kind) \(size / 1024)KB: opening…")
                let t0 = Date()
                autoreleasepool { state.showRequest(big.id); host.layoutSubtreeIfNeeded() }
                let layout = Date().timeIntervalSince(t0)
                for _ in 0..<10 { autoreleasepool { pump(0.02) } }
                let total = Date().timeIntervalSince(t0)
                log("  \(kind) \(size / 1024)KB: layout=\(String(format: "%.2f", layout))s settle=\(String(format: "%.2f", total))s footprint \(Int(before))→\(Int(footprintMB()))MB")
            }
        }
        log("done")
    }

    // MARK: - Parça parça: hangi alan geride kalıyor?

    final class Model: ObservableObject { @Published var entries: [KeyValueEntry] = [] }

    enum Variant: String, CaseIterable {
        case textFieldPlain, textFieldLimit, templatePlain, templateVariables, kvPlain, kvVariables
    }

    private struct Rows: View {
        @ObservedObject var model: Model
        let variant: Variant
        var body: some View {
            switch variant {
            case .kvPlain, .kvVariables:
                KeyValueEditor(entries: $model.entries, keyPlaceholder: "k", valuePlaceholder: "v")
            default:
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($model.entries) { $entry in
                            switch variant {
                            case .textFieldPlain: TextField("", text: $entry.value)
                            case .textFieldLimit: TextField("", text: $entry.value).inputLimit(.headerValue)
                            default: TemplateTextField(placeholder: "", text: $entry.value, bordered: false)
                            }
                        }
                    }
                }
            }
        }
    }

    private func allTextFields(_ view: NSView) -> [NSView] {
        var result: [NSView] = []
        if view is NSTextField || view is NSTextView { result.append(view) }
        for sub in view.subviews { result += allTextFields(sub) }
        return result
    }

    func testWhichFieldStaysAlive() throws {
        guard let path = ProcessInfo.processInfo.environment["PROBE_LOG"] else {
            throw XCTSkip("yalnızca PROBE_LOG ile")
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        logHandle = FileHandle(forWritingAtPath: path)
        defer { try? logHandle?.close() }

        let harness = AppStateHarness()
        defer { harness.tearDown() }
        _ = harness.state.addEnvironment()
        harness.state.workspace.environments[0].variables = [KeyValueEntry(key: "token", value: "t")]

        let swaps = 20
        let rows = 40
        for variant in Variant.allCases {
            let model = Model()
            let withVariables = variant == .templateVariables || variant == .kvVariables
            func fresh() -> [KeyValueEntry] {
                (0..<rows).map { KeyValueEntry(key: "K\($0)", value: withVariables ? "Bearer {{token}} {{missing}}" : "plain-value-\($0)") }
            }
            model.entries = fresh()
            let host = NSHostingView(rootView: Rows(model: model, variant: variant).environment(harness.state).frame(width: 900, height: 2400))
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 900, height: 2400), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            pump(0.5)

            let tracked = NSHashTable<NSView>.weakObjects()
            let before = footprintMB()
            // Uygulamada olay döngüsü her turda autorelease havuzunu boşaltır;
            // testte bunu her adımda biz yapıyoruz (yoksa ölçüm yapay şişer).
            for _ in 0..<swaps {
                autoreleasepool {
                    allTextFields(host).forEach { tracked.add($0) }
                }
                autoreleasepool {
                    model.entries = fresh()   // yeni kimlikler: satırlar yeniden kurulur (istek değişimi gibi)
                    host.layoutSubtreeIfNeeded()
                }
                for _ in 0..<5 { autoreleasepool { pump(0.02) } }
            }
            for _ in 0..<20 { autoreleasepool { pump(0.05) } }
            let alive: Int = autoreleasepool {
                let current = Set(allTextFields(host).map(ObjectIdentifier.init))
                return tracked.allObjects.filter { !current.contains(ObjectIdentifier($0)) }.count
            }
            log("\(variant.rawValue): old fields still alive=\(alive) (of ~\(swaps * rows) replaced) footprint +\(Int(footprintMB() - before))MB")
            window.contentView = nil
            window.orderOut(nil)
            pump(0.3)
        }
    }
}
