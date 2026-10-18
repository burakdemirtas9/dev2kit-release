import Foundation

/// Satır karşılaştırma: patience + Myers. Diff Checker'ın bütün dilleri bunu
/// paylaşır; dile özgü olan yalnızca karşılaştırmadan önceki normalizasyon.
///
/// - **Patience:** iki tarafta da TEK geçen satırlar sabit nokta olarak eşlenir
///   (en uzun artan alt dizi), aradaki parçalar ayrı ayrı karşılaştırılır.
///   Biçimlendirilmiş JSON'da satırların çoğu tekil (`"id": 123`), bu yüzden
///   binlerce değişiklik bile küçük parçalara bölünür. git'in `--patience`'ı.
/// - **Myers O(ND)** tekil satır kalmayan parçalarda. Geri izleme kaydı her
///   adımda yalnızca o adımın köşegen aralığını tutar (~D² tamsayı).
///   Parçadaki fark `maxEdits`'i aşarsa o parça "tümü silindi + tümü eklendi"
///   olarak sadeleşir ve `isSimplified` işaretlenir: arayüz kilitlenmesin.
///
/// Ölçüm (M4, release, 2026-10-18): yalnızca Myers ile 1 MB JSON'da üç
/// öğeden birinde değer değişince (~6.000 düzenleme) sonuç tamamen
/// sadeleşiyordu; patience ile parça parça ve doğru.
///
/// Patience her zaman EN KÜÇÜK fark sayısını vermez (okunurluk için daha
/// iyi eşleşmeyi seçer); en küçük sonuç testleri `algorithm: .myers` ile.
public enum LineDiff {
    public static let maxEdits = 4_000

    public enum Operation: Equatable, Sendable {
        case equal(left: Int, right: Int)
        case delete(left: Int)
        case insert(right: Int)
    }

    public struct Options: Hashable, Sendable {
        public var ignoreWhitespace: Bool
        public var ignoreCase: Bool

        public init(ignoreWhitespace: Bool = false, ignoreCase: Bool = false) {
            self.ignoreWhitespace = ignoreWhitespace
            self.ignoreCase = ignoreCase
        }
    }

    public struct Result: Equatable, Sendable {
        public let operations: [Operation]
        public let isSimplified: Bool
    }

    enum Algorithm { case patience, myers }

    public static func diff(_ left: [String], _ right: [String], options: Options = .init()) -> Result {
        diff(left, right, options: options, algorithm: .patience)
    }

    static func diff(_ left: [String], _ right: [String], options: Options, algorithm: Algorithm) -> Result {
        // Satırları sayıya çevir: karşılaştırma tamsayı eşitliği olur.
        var ids: [String: Int32] = [:]
        func key(_ line: String) -> Int32 {
            var normalized = line
            if options.ignoreWhitespace { normalized = normalized.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            if options.ignoreCase { normalized = normalized.lowercased() }
            if let id = ids[normalized] { return id }
            let id = Int32(ids.count)
            ids[normalized] = id
            return id
        }
        let a = left.map(key)
        let b = right.map(key)

        var operations: [Operation] = []
        var simplified = false
        compare(a, 0..<a.count, b, 0..<b.count, algorithm: algorithm, into: &operations, simplified: &simplified)
        return Result(operations: operations, isSimplified: simplified)
    }

    /// Aralıkları karşılaştırır: ortak baş/son, sonra patience sabit noktaları
    /// (varsa) ya da Myers.
    private static func compare(
        _ a: [Int32], _ aRange: Range<Int>,
        _ b: [Int32], _ bRange: Range<Int>,
        algorithm: Algorithm,
        into operations: inout [Operation],
        simplified: inout Bool
    ) {
        var aStart = aRange.lowerBound, aEnd = aRange.upperBound
        var bStart = bRange.lowerBound, bEnd = bRange.upperBound
        while aStart < aEnd, bStart < bEnd, a[aStart] == b[bStart] {
            operations.append(.equal(left: aStart, right: bStart))
            aStart += 1; bStart += 1
        }
        var tail: [Operation] = []
        while aStart < aEnd, bStart < bEnd, a[aEnd - 1] == b[bEnd - 1] {
            aEnd -= 1; bEnd -= 1
            tail.append(.equal(left: aEnd, right: bEnd))
        }
        defer { operations.append(contentsOf: tail.reversed()) }

        if algorithm == .patience, let anchors = uniqueAnchors(a, aStart..<aEnd, b, bStart..<bEnd), !anchors.isEmpty {
            var previousA = aStart, previousB = bStart
            for anchor in anchors {
                compare(a, previousA..<anchor.a, b, previousB..<anchor.b, algorithm: algorithm, into: &operations, simplified: &simplified)
                operations.append(.equal(left: anchor.a, right: anchor.b))
                previousA = anchor.a + 1
                previousB = anchor.b + 1
            }
            compare(a, previousA..<aEnd, b, previousB..<bEnd, algorithm: algorithm, into: &operations, simplified: &simplified)
            return
        }

        let middle = myers(Array(a[aStart..<aEnd]), Array(b[bStart..<bEnd]))
        if middle.isSimplified { simplified = true }
        for op in middle.operations {
            switch op {
            case .equal(let l, let r): operations.append(.equal(left: l + aStart, right: r + bStart))
            case .delete(let l): operations.append(.delete(left: l + aStart))
            case .insert(let r): operations.append(.insert(right: r + bStart))
            }
        }
    }

    /// İki aralıkta da tam bir kez geçen satırlardan, sırası iki tarafta da
    /// korunan en uzun eşleşme (patience sıralamasıyla en uzun artan alt dizi).
    private static func uniqueAnchors(
        _ a: [Int32], _ aRange: Range<Int>,
        _ b: [Int32], _ bRange: Range<Int>
    ) -> [(a: Int, b: Int)]? {
        guard !aRange.isEmpty, !bRange.isEmpty else { return nil }
        var countA: [Int32: Int] = [:], countB: [Int32: Int] = [:]
        var positionB: [Int32: Int] = [:]
        for i in aRange { countA[a[i], default: 0] += 1 }
        for j in bRange { countB[b[j], default: 0] += 1; positionB[b[j]] = j }
        let pairs = aRange.compactMap { i -> (a: Int, b: Int)? in
            let line = a[i]
            guard countA[line] == 1, countB[line] == 1, let j = positionB[line] else { return nil }
            return (i, j)
        }
        guard !pairs.isEmpty else { return nil }
        // En uzun artan alt dizi (b konumlarına göre), O(n log n).
        var tails: [Int] = []          // pairs indeksleri
        var parent = [Int](repeating: -1, count: pairs.count)
        for index in pairs.indices {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if pairs[tails[mid]].b < pairs[index].b { low = mid + 1 } else { high = mid }
            }
            if low > 0 { parent[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var result: [(a: Int, b: Int)] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 { result.append(pairs[cursor]); cursor = parent[cursor] }
        return result.reversed()
    }

    /// Klasik Myers; her adımın V dizisi yalnızca [-d, d] aralığını tutar.
    private static func myers(_ a: [Int32], _ b: [Int32]) -> Result {
        let n = a.count, m = b.count
        if n == 0 { return Result(operations: (0..<m).map { .insert(right: $0) }, isSimplified: false) }
        if m == 0 { return Result(operations: (0..<n).map { .delete(left: $0) }, isSimplified: false) }

        let maxD = min(n + m, maxEdits)
        var trace: [[Int32]] = []
        // v[k + d] = k köşegeninde ulaşılan en uzak x (önceki adımın aralığı).
        var previous: [Int32] = [0, 0]  // d = -1 için sanal: v[1] = 0
        var found = false
        var finalD = 0

        for d in 0...maxD {
            var current = [Int32](repeating: 0, count: 2 * d + 1)
            for k in stride(from: -d, through: d, by: 2) {
                func prev(_ k: Int) -> Int32 {
                    // Önceki adımın aralığı [-(d-1), d-1]; d == 0'da sanal dizi.
                    if d == 0 { return 0 }
                    return previous[k + d - 1]
                }
                var x: Int
                if k == -d || (k != d && prev(k - 1) < prev(k + 1)) {
                    x = Int(prev(k + 1))          // aşağı: ekleme
                } else {
                    x = Int(prev(k - 1)) + 1      // sağa: silme
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                current[k + d] = Int32(x)
                if x >= n && y >= m { found = true }
            }
            trace.append(current)
            previous = current
            if found { finalD = d; break }
        }

        guard found else {
            // Çok fazla fark: sadeleştirilmiş sonuç.
            return Result(operations: (0..<n).map { .delete(left: $0) } + (0..<m).map { .insert(right: $0) }, isSimplified: true)
        }

        // Geri izleme.
        var operations: [Operation] = []
        var x = n, y = m
        for d in stride(from: finalD, to: 0, by: -1) {
            let v = trace[d - 1]
            let k = x - y
            func at(_ k: Int) -> Int { Int(v[k + d - 1]) }
            let previousK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1
            let previousX = at(previousK)
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                x -= 1; y -= 1
                operations.append(.equal(left: x, right: y))
            }
            if x == previousX { y -= 1; operations.append(.insert(right: y)) } else { x -= 1; operations.append(.delete(left: x)) }
        }
        while x > 0, y > 0 { x -= 1; y -= 1; operations.append(.equal(left: x, right: y)) }
        return Result(operations: operations.reversed(), isSimplified: false)
    }
}

/// Yan yana gösterim satırı. Karşılıklı silinen/eklenen satırlar aynı hizada
/// "değişti" olarak eşlenir: bir satırdaki değer değişikliği iki ayrı satır
/// (biri kırmızı, biri yeşil, alt alta) yerine yan yana görünsün.
public struct DiffRow: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case equal, changed, removed, added }

    public let id: Int
    public let kind: Kind
    /// Satır numarası (1'den) ve metni; o tarafta karşılığı yoksa nil.
    public let left: (number: Int, text: String)?
    public let right: (number: Int, text: String)?

    public static func == (lhs: DiffRow, rhs: DiffRow) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
            && lhs.left?.number == rhs.left?.number && lhs.left?.text == rhs.left?.text
            && lhs.right?.number == rhs.right?.number && lhs.right?.text == rhs.right?.text
    }

    /// İşlemlerden yan yana satırlar.
    public static func rows(_ operations: [LineDiff.Operation], left: [String], right: [String]) -> [DiffRow] {
        var rows: [DiffRow] = []
        var deletes: [Int] = []
        var inserts: [Int] = []
        func flush() {
            for i in 0..<max(deletes.count, inserts.count) {
                let l = i < deletes.count ? deletes[i] : nil
                let r = i < inserts.count ? inserts[i] : nil
                let kind: Kind = l != nil && r != nil ? .changed : (l != nil ? .removed : .added)
                rows.append(DiffRow(id: rows.count, kind: kind,
                                    left: l.map { ($0 + 1, left[$0]) },
                                    right: r.map { ($0 + 1, right[$0]) }))
            }
            deletes.removeAll()
            inserts.removeAll()
        }
        for op in operations {
            switch op {
            case .delete(let l): deletes.append(l)
            case .insert(let r): inserts.append(r)
            case .equal(let l, let r):
                flush()
                rows.append(DiffRow(id: rows.count, kind: .equal, left: (l + 1, left[l]), right: (r + 1, right[r])))
            }
        }
        flush()
        return rows
    }

    /// Her fark bloğunun ilk satırının kimliği ("sonraki fark" gezintisi).
    public static func changeStarts(_ rows: [DiffRow]) -> [Int] {
        var starts: [Int] = []
        var previousWasChange = false
        for row in rows {
            let isChange = row.kind != .equal
            if isChange && !previousWasChange { starts.append(row.id) }
            previousWasChange = isChange
        }
        return starts
    }
}
