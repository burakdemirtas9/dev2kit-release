import XCTest
@testable import Dev2KitCore

/// YAML ↔ Properties (Spring yapılandırması, 2026-10-20).
final class PropertiesConverterTests: XCTestCase {
    func testSpringYAMLToProperties() throws {
        let yaml = """
        # yorum
        server:
          port: 8080   # satır sonu yorumu
          servlet.context-path: /api
        spring:
          datasource:
            url: "jdbc:postgresql://db:5432/app?ssl=true"
            password: 'it''s'
          profiles:
            active:
              - dev
              - local
        app:
          map:
            "[x.y]": değer
          empty: []
          nothing: ~
          motd: |
            satır 1
            satır 2
          servers:
          - host: a
            port: 1
          - host: b
            port: 2
          flow: [1, two, { k: v }]
        ---
        spring.config.activate.on-profile: prod
        server.port: 80
        """
        XCTAssertEqual(try PropertiesConverter.fromYAML(yaml), #"""
        server.port=8080
        server.servlet.context-path=/api
        spring.datasource.url=jdbc\:postgresql\://db\:5432/app?ssl=true
        spring.datasource.password=it's
        spring.profiles.active[0]=dev
        spring.profiles.active[1]=local
        app.map[x.y]=de\u011Fer
        app.empty=
        app.nothing=
        app.motd=sat\u0131r 1\nsat\u0131r 2\n
        app.servers[0].host=a
        app.servers[0].port=1
        app.servers[1].host=b
        app.servers[1].port=2
        app.flow[0]=1
        app.flow[1]=two
        app.flow[2].k=v
        #---
        spring.config.activate.on-profile=prod
        server.port=80
        """#.replacingOccurrences(of: #"jdbc\:postgresql\://db\:5432"#, with: "jdbc:postgresql://db:5432"))
    }

    func testPropertiesToSpringYAML() throws {
        let properties = #"""
        # yorum
        ! bu da yorum
        server.port=8080
        server.address = 0.0.0.0
        spring.application.name: demo
        app.country=no
        app.code=012
        app.enabled=true
        app.greeting=Merhaba \u015Fehir
        app.long=bir \
            iki
        app.list[0]=a
        app.list[1]=b
        app.map.[x.y]=z
        app.empty=
        #---
        spring.config.activate.on-profile=prod
        """#
        XCTAssertEqual(try PropertiesConverter.toYAML(properties), """
        server:
          port: 8080
          address: "0.0.0.0"
        spring:
          application:
            name: demo
        app:
          country: "no"
          code: "012"
          enabled: true
          greeting: Merhaba şehir
          long: bir iki
          list:
            - a
            - b
          map:
            x.y: z
          empty: ""
        ---
        spring:
          config:
            activate:
              on-profile: prod
        """)
    }

    func testRoundTripKeepsValues() throws {
        let yaml = "a:\n  b: \"x: y\"\n  c:\n    - 1\n    - 2\n"
        let back = try PropertiesConverter.toYAML(try PropertiesConverter.fromYAML(yaml))
        XCTAssertEqual(back, "a:\n  b: \"x: y\"\n  c:\n    - 1\n    - 2")
    }

    func testConflictsAndLimitsAreReportedWithLine() {
        XCTAssertThrowsError(try PropertiesConverter.toYAML("a=1\na.b=2")) { error in
            XCTAssertEqual((error as? WorkbenchIssue)?.line, 2)
        }
        XCTAssertThrowsError(try PropertiesConverter.toYAML("a.b=1\na=2")) { error in
            XCTAssertEqual((error as? WorkbenchIssue)?.line, 2)
        }
        XCTAssertThrowsError(try PropertiesConverter.toYAML("a[99999999]=1"))
        if case .invalid(let issue) = PropertiesConverter.validate("x=1\ny[=2") { XCTAssertEqual(issue.line, 2) } else { XCTFail() }
    }

    func testYAMLReaderRejectsUnsafeAndInvalid() {
        for (yaml, line) in [
            ("a: &x 1\nb: *x", 1),
            ("a: !!python/object x", 1),
            ("a: 1\na: 2", 2),
            ("a:\n\tb: 1", 2),
            ("a: [1, 2", 1),
        ] {
            guard case .invalid(let issue) = YAMLReader.validate(yaml) else { XCTFail(yaml); continue }
            XCTAssertEqual(issue.line, line, yaml)
        }
        XCTAssertThrowsError(try PropertiesConverter.fromYAML("just a scalar"))
    }

    func testYAMLScalarsAndBlockStyles() throws {
        let docs = try YAMLReader.documents("""
        a: "tab\\there \\u00e7"
        b: >-
          katlanan
          metin

          paragraf
        c: |+
          korunan

        d: plain
          devam
        e: -1.5e3
        f: 0x1F
        """)
        XCTAssertEqual(docs, [.object([
            ("a", .string("tab\there ç")),
            ("b", .string("katlanan metin\nparagraf")),
            ("c", .string("korunan\n\n")),
            ("d", .string("plain devam")),
            ("e", .number("-1.5e3")),
            ("f", .string("0x1F")),
        ])])
    }
}
