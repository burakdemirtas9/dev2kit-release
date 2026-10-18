import XCTest
@testable import Dev2KitCore

/// Step 2a kodlayıcı/çözücüler (kullanıcı kararı, 2026-10-19).
final class EncodeToolsTests: XCTestCase {
    private let istanbul = TimeZone(identifier: "Europe/Istanbul")!
    private let now = Date(timeIntervalSince1970: 1_792_352_551) // 2026-10-18 19:42:31 UTC

    // MARK: Base64 / Hex / URL

    func testBase64BothVariantsAndRoundTrip() {
        let data = Data([0xFB, 0xFF, 0x00, 0x41])
        XCTAssertEqual(Base64Codec.encode(data, urlSafe: false), "+/8AQQ==")
        XCTAssertEqual(Base64Codec.encode(data, urlSafe: true), "-_8AQQ")
        XCTAssertEqual(Base64Codec.decode("-_8AQQ"), data, "URL-safe, dolgusuz")
        XCTAssertEqual(Base64Codec.decode("+/8A\nQQ=="), data, "satır sonlu")
        XCTAssertNil(Base64Codec.decode("abcde"), "geçersiz uzunluk")
        XCTAssertEqual(Base64Codec.decode(Base64Codec.encode(Data("şifre: ğüİ".utf8), urlSafe: true)), Data("şifre: ğüİ".utf8))
    }

    func testDecodedBinaryIsShownAsHexNotLost() throws {
        let tool = WorkbenchTools.base64
        XCTAssertEqual(try tool.action(id: "decode").run("ZGV2MmtpdA==", .init()), "dev2kit")
        XCTAssertTrue(try tool.action(id: "decode").run("/w==", .init()).contains("Binary data (1 bytes)"))
    }

    func testHexAcceptsCommonSeparators() throws {
        XCTAssertEqual(HexCodec.encode(Data("dev".utf8)), "646576")
        XCTAssertEqual(try HexCodec.decode("0x64 65:76"), Data("dev".utf8))
        XCTAssertThrowsError(try HexCodec.decode("abc"))
        XCTAssertThrowsError(try HexCodec.decode("zz"))
    }

    func testURLComponentAndFormEncoding() throws {
        XCTAssertEqual(URLCodec.encode("a b&c=ş/?", form: false), "a%20b%26c%3D%C5%9F%2F%3F")
        XCTAssertEqual(URLCodec.encode("a b", form: true), "a+b")
        XCTAssertEqual(try URLCodec.decode("a+b%20c", form: true), "a b c")
        XCTAssertEqual(try URLCodec.decode("a+b", form: false), "a+b")
        XCTAssertThrowsError(try URLCodec.decode("%ZZ", form: false))
    }

    func testEncodersAreTwoWay() throws {
        // Çıktı düzenlenince girdi güncellenir (ters dönüşüm).
        for tool in [WorkbenchTools.base64, WorkbenchTools.url, WorkbenchTools.hex] {
            for action in tool.actions {
                let input = action.id == "decode" ? try tool.action(id: "encode").run("dev2kit ş", .init()) : "dev2kit ş"
                let output = try action.run(input, .init())
                XCTAssertEqual(try action.reverse?(output, input, .init()), input, "\(tool.id) \(action.id)")
            }
        }
    }

    // MARK: JWT

    private func jwt(_ payload: String, header: String = #"{"alg":"RS256","typ":"JWT","kid":"k1"}"#) -> String {
        [header, payload].map { Base64Codec.encode(Data($0.utf8), urlSafe: true) }.joined(separator: ".") + ".c2ln"
    }

    func testJWTDecodeShowsClaimsTimesAndUnverifiedSignature() throws {
        let token = jwt(#"{"sub":"42","roles":["admin"],"exp":1792353931,"iat":1792352131}"#)
        let output = try JWTDecoder.decode("Bearer " + token, now: now, timeZone: istanbul)
        XCTAssertTrue(output.contains(#""roles": ["#), "yük biçimli")
        XCTAssertTrue(output.contains("// exp       2026-10-18 23:05:31 +03:00 · 2026-10-18 20:05:31 UTC · in 23 min"), output)
        XCTAssertTrue(output.contains("// iat       2026-10-18 22:35:31 +03:00 · 2026-10-18 19:35:31 UTC · 7 min ago"), output)
        XCTAssertTrue(output.contains("Signature NOT verified (decode only). Algorithm: RS256"))
    }

    func testExpiredAndUnsignedTokensAreFlagged() throws {
        let expired = try JWTDecoder.decode(jwt(#"{"exp":1792352000}"#), now: now, timeZone: istanbul)
        XCTAssertTrue(expired.contains("EXPIRED"))
        let none = try JWTDecoder.decode(jwt("{}", header: #"{"alg":"none"}"#), now: now, timeZone: istanbul)
        XCTAssertTrue(none.contains("unsigned token"))
    }

    func testJWTStructureErrors() {
        XCTAssertThrowsError(try JWTDecoder.decode("a.b")) { XCTAssertTrue("\($0.localizedDescription)".contains("üç parça")) }
        XCTAssertThrowsError(try JWTDecoder.decode("a.b.c.d.e")) { XCTAssertTrue("\($0.localizedDescription)".contains("JWE")) }
        XCTAssertThrowsError(try JWTDecoder.decode("!!.e30.x"))
        if case .invalid = JWTDecoder.validate("bozuk") {} else { XCTFail() }
        XCTAssertEqual(JWTDecoder.validate(jwt("{}")), .valid)
    }

    // MARK: Zaman damgası

    func testTimestampUnitsAreDetectedByDigits() throws {
        for (input, unit) in [("1792352551", "seconds"), ("1792352551428", "milliseconds"), ("1792352551428000", "microseconds"), ("1792352551428000000", "nanoseconds")] {
            let output = try TimestampConverter.convert(input, now: now, timeZone: istanbul)
            XCTAssertTrue(output.contains("(\(unit))"), input)
            XCTAssertTrue(output.contains("Unix (s)   1792352551"), output)
        }
    }

    func testTimestampDatesAndLocalTime() throws {
        let iso = try TimestampConverter.convert("2026-10-18T19:42:31Z", now: now, timeZone: istanbul)
        XCTAssertTrue(iso.contains("Local      2026-10-18 22:42:31 +03:00 Europe/Istanbul (Sunday)"), iso)
        XCTAssertTrue(iso.contains("Relative   now"))
        // Bölgesiz tarih yerel saat sayılır.
        let local = try TimestampConverter.convert("2026-10-18 22:42:31", now: now, timeZone: istanbul)
        XCTAssertTrue(local.contains("Unix (s)   1792352551"), local)
        XCTAssertThrowsError(try TimestampConverter.convert("dün akşam"))
    }

    func testEmptyInputMeansNowAndMultipleLinesAreConverted() throws {
        XCTAssertTrue(try TimestampConverter.convert("", now: now, timeZone: istanbul).contains("Input      now"))
        XCTAssertEqual(try TimestampConverter.convert("1792352551\n1792352551428", now: now, timeZone: istanbul).components(separatedBy: "Input").count, 3)
    }

    // MARK: UUID

    func testGeneratedUUIDsHaveTheRightVersion() throws {
        let v4 = UUIDTool.generate(version: 4, count: 5).components(separatedBy: "\n")
        XCTAssertEqual(v4.count, 5)
        XCTAssertTrue(v4.allSatisfy { UUID(uuidString: $0) != nil && $0 == $0.lowercased() && Array($0)[14] == "4" })
        let v7 = UUIDTool.generate(version: 7, count: 1, now: now)
        XCTAssertEqual(Array(v7)[14], "7")
        // v7'nin içindeki zaman geri okunur.
        XCTAssertTrue(try UUIDTool.inspect(v7, timeZone: istanbul).contains("2026-10-18 22:42:31 +03:00"))
        XCTAssertEqual(UUIDTool.generate(version: 4, count: 5_000).components(separatedBy: "\n").count, UUIDTool.maxCount)
    }

    func testInspectExplainsEachLine() throws {
        let output = try UUIDTool.inspect("550e8400-e29b-41d4-a716-446655440000\nbozuk")
        XCTAssertTrue(output.contains("v4 (random)"))
        XCTAssertTrue(output.contains("bozuk  — not a valid UUID"))
    }

    func testUUIDGenerateRunsWithoutInput() {
        XCTAssertTrue(WorkbenchTools.uuid.action(id: "v4").runsOnEmptyInput)
        XCTAssertFalse(WorkbenchTools.uuid.action(id: "inspect").runsOnEmptyInput)
    }

    // MARK: Hash / HMAC

    func testKnownDigests() throws {
        XCTAssertEqual(try HashTool.digest("abc", algorithm: .sha256, output: .hex), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try HashTool.digest("abc", algorithm: .md5, output: .hex), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(try HashTool.digest("abc", algorithm: .sha1, output: .hex), "a9993e364706816aba3e25717850c26c9cd0d89d")
        // RFC 4231 test vaka 2.
        XCTAssertEqual(try HashTool.digest("what do ya want for nothing?", algorithm: .hmacSHA256, key: "Jefe", output: .hex),
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        XCTAssertEqual(try HashTool.digest("abc", algorithm: .sha256, output: .base64), "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=")
    }

    func testTrailingNewlineChangesTheHash() throws {
        XCTAssertNotEqual(try HashTool.digest("abc", algorithm: .sha256, output: .hex), try HashTool.digest("abc\n", algorithm: .sha256, output: .hex))
    }

    func testHMACNeedsAKeyAndInsecureAlgorithmsAreLabelled() {
        XCTAssertThrowsError(try HashTool.digest("x", algorithm: .hmacSHA256, output: .hex))
        XCTAssertTrue(WorkbenchTools.hash.action(id: "MD5").title.contains("⚠︎"))
        XCTAssertFalse(WorkbenchTools.hash.action(id: "SHA-256").title.contains("⚠︎"))
    }

    func testEncodeCategoryHasTheSevenTools() {
        XCTAssertEqual(WorkbenchCatalog.all.filter { $0.category == .encode }.map(\.id),
                       ["jwt", "base64", "url-encode", "timestamp", "uuid", "hash", "hex"])
    }

    // MARK: Aşırı değerler (2026-10-19: altı vakanın altısı uygulamayı çökertiyordu)

    func testExtremeTimestampsAreRejectedNotCrashing() {
        for value in [String(repeating: "9", count: 31), String(repeating: "9", count: 400), "-" + String(repeating: "9", count: 31)] {
            XCTAssertThrowsError(try TimestampConverter.convert(value)) { error in
                XCTAssertTrue("\(error.localizedDescription)".contains("aralık dışı"), value)
            }
        }
        // Sınırın içi çalışır: 9999 yılı.
        XCTAssertNoThrow(try TimestampConverter.convert("253402300799"))
    }

    func testExtremeJWTTimesAreShownAsOutOfRange() throws {
        for payload in [#"{"exp":1e300}"#, #"{"exp":"1e400"}"#, #"{"iat":-1e20}"#] {
            let output = try JWTDecoder.decode(jwt(payload), now: now, timeZone: istanbul)
            XCTAssertTrue(output.contains("out of range"), payload)
        }
    }

    func testDurationNeverOverflows() {
        XCTAssertEqual(TimeText.duration(.infinity), "∞")
        XCTAssertFalse(TimeText.duration(1e300).isEmpty)
    }
}
