import XCTest
@testable import Dev2KitCore

final class OutboundScannerTests: XCTestCase {
    static let files: [(path: String, text: String)] = [
        ("src/main/resources/application.yml", """
        spring:
          application:
            name: fx-bff   # yorum
        partner:
          customer:
            url: https://partner.default.example
          payment-url: ${PAYMENT_URL:https://pay.example.com}
        notification:
          url: "http://notify.local:8081"
        fx:
          rates:
            url: https://rates.default.example
        clients:
          - name: a
            url: https://a.example
        ---
        spring:
          config:
            activate:
              on-profile: test
        partner:
          customer:
            url: https://partner.test.example
        """),
        ("src/main/resources/application-prep.properties", """
        # prep
        partner.customer.url=https://partner.prep.example
        partner.payment-url = https://pay.prep.example
        """),
        ("src/main/java/x/Paths.java", """
        package x;
        public final class Paths {
            public static final String CREATE = "/customers";
        }
        """),
        ("src/main/java/x/CustomerClient.java", """
        package x;
        import org.springframework.cloud.openfeign.FeignClient;
        /** Müşteri servisi. "tırnak" ve // yorum içi metin sayılmaz */
        @FeignClient(name = "partner-customer", url = "${partner.customer.url}", path = "/api")
        public interface CustomerClient {
            @GetMapping("/customers/{id}")
            CustomerDto getCustomer(@PathVariable("id") String id,
                                    @RequestParam(value = "detail", required = false) boolean detail,
                                    @RequestHeader("X-Channel") String channel);

            @PostMapping(value = Paths.CREATE, consumes = MediaType.APPLICATION_JSON_VALUE)
            CustomerDto create(@RequestBody CreateCustomerRequest request);

            @RequestMapping(method = RequestMethod.DELETE, value = "/customers/{id}")
            void delete(@PathVariable String id);

            default String helper() { return "x;y"; }
        }
        """),
        ("src/main/java/x/InventoryClient.java", """
        @FeignClient("inventory-service")
        @RequestMapping("/inventory")
        interface InventoryClient {
            @GetMapping("/stock")
            Stock stock(@RequestParam String sku);
        }
        """),
        ("src/main/java/x/RatesApi.java", """
        @HttpExchange(url = "${fx.rates.url}")
        public interface RatesApi {
            @GetExchange("/rates/{pair}")
            Rate rate(@PathVariable String pair);
        }
        """),
        ("src/main/java/x/CreateCustomerRequest.java", """
        public class CreateCustomerRequest extends BaseRequest {
            private static final long serialVersionUID = 1L;
            private String name;
            @JsonProperty("birth_date")
            private LocalDate birthDate;
            private List<Address> addresses;
            private Status status;
            public String getName() { return name; }
        }
        """),
        ("src/main/java/x/BaseRequest.java", "public abstract class BaseRequest { protected UUID requestId; }"),
        ("src/main/java/x/Address.java", "public record Address(String city, int zip) {}"),
        ("src/main/java/x/Status.java", "public enum Status { ACTIVE, PASSIVE }"),
        ("src/main/java/x/PaymentService.java", """
        @Service
        public class PaymentService {
            private final RestTemplate restTemplate;
            @Value("${partner.payment-url}")
            private String paymentUrl;
            private static final String PAY_PATH = "/payments";

            public void pay(PaymentRequest req, String orderId) {
                restTemplate.postForObject(paymentUrl + PAY_PATH, req, PaymentResult.class);
                restTemplate.exchange(paymentUrl + "/payments/" + orderId, HttpMethod.GET, null, PaymentResult.class);
                restTemplate.getForObject("https://rates.example.com/v2/rates?base=TRY", String.class);
                restTemplate.getForObject(buildUrl(orderId), String.class);
            }
        }
        """),
        ("src/main/java/x/PaymentRequest.java", "public class PaymentRequest { private BigDecimal amount; private String currency; }"),
        ("src/main/java/x/ClientConfig.java", """
        @Configuration
        class ClientConfig {
            @Bean
            WebClient notificationWebClient(@Value("${notification.url}") String url) {
                return WebClient.builder().baseUrl(url).build();
            }
        }
        """),
        ("src/main/java/x/NotificationService.java", """
        @Service
        class NotificationService {
            private final WebClient notificationWebClient;
            void send(String userId, NotifyRequest body) {
                notificationWebClient.post()
                    .uri("/users/{userId}/notify", userId)
                    .contentType(MediaType.APPLICATION_JSON)
                    .bodyValue(body)
                    .retrieve()
                    .bodyToMono(Void.class);
                notificationWebClient.get()
                    .uri(b -> b.path("/templates").queryParam("lang", "tr").build())
                    .retrieve();
            }
        }
        """),
        ("src/main/java/x/NotifyRequest.java", "public record NotifyRequest(String title, List<String> channels) {}"),
        ("src/main/java/x/GeoService.java", """
        class GeoService {
            private final RestClient restClient = RestClient.create("https://geo.example.com");
            String city(String code) {
                return restClient.get().uri("/cities/{code}", code).header("X-Key", "abc").retrieve().body(String.class);
            }
        }
        """),
    ]

    private lazy var result: OutboundScanResult = try! OutboundScanner.scan(files: Self.files, projectName: "fx-bff")

    private func call(_ client: String, _ operation: String, line: Int? = nil) throws -> OutboundCall {
        try XCTUnwrap(result.calls.first { $0.client == client && $0.operation == operation && (line == nil || $0.location.hasSuffix(":\(line!)")) },
                      "\(client).\(operation) yok: \(result.calls.map { "\($0.client).\($0.operation)@\($0.location)" })")
    }

    // MARK: - Spring ayarları

    func testConfigProfilesAndPlaceholders() {
        let config = result.config
        XCTAssertEqual(config.profiles, ["prep", "test"])
        XCTAssertEqual(config.value(for: "partner.customer.url", profile: nil), "https://partner.default.example")
        XCTAssertEqual(config.value(for: "partner.customer.url", profile: "test"), "https://partner.test.example")
        XCTAssertEqual(config.value(for: "partner.customer.url", profile: "prep"), "https://partner.prep.example")
        XCTAssertEqual(config.value(for: "partner.paymentUrl", profile: nil), "https://pay.example.com", "esnek ad + varsayılan değer")
        XCTAssertEqual(config.value(for: "notification.url", profile: nil), "http://notify.local:8081")
        XCTAssertEqual(config.value(for: "clients[0].url", profile: nil), "https://a.example")
        XCTAssertEqual(config.value(for: "spring.application.name", profile: nil), "fx-bff", "satır sonu yorumu atılır")
    }

    // MARK: - Feign

    func testFeignClientWithPropertyURLAndPaths() throws {
        let get = try call("partner-customer", "getCustomer")
        XCTAssertEqual(get.source, .feign)
        XCTAssertEqual(get.method, .get)
        XCTAssertEqual(get.baseVariable, "partner-customer")
        XCTAssertEqual(get.baseOrigin, .property("partner.customer.url"))
        XCTAssertEqual(get.path, "/api/customers/{{id}}")
        XCTAssertEqual(get.query.map(\.key), ["detail"])
        XCTAssertEqual(get.query.map(\.enabled), [false])
        XCTAssertEqual(get.headers.map(\.key), ["X-Channel"])
        XCTAssertTrue(get.isComplete)
        XCTAssertTrue(get.location.hasPrefix("src/main/java/x/CustomerClient.java:"))
    }

    func testFeignBodyFromDTOIncludingInheritanceRecordsAndEnums() throws {
        let create = try call("partner-customer", "create")
        XCTAssertEqual(create.method, .post)
        XCTAssertEqual(create.path, "/api/customers", "yol başka sınıftaki sabitten")
        XCTAssertTrue(create.headers.contains { $0.key == "Content-Type" && $0.value == "application/json" })
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(create.bodySample).utf8)) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "string")
        XCTAssertEqual(json["birth_date"] as? String, "2026-01-01", "@JsonProperty adı")
        XCTAssertEqual(json["status"] as? String, "ACTIVE")
        XCTAssertEqual(json["requestId"] as? String, "00000000-0000-0000-0000-000000000000", "üst sınıf alanı")
        XCTAssertNil(json["serialVersionUID"], "statik alan gövdeye girmez")
        let address = try XCTUnwrap((json["addresses"] as? [[String: Any]])?.first)
        XCTAssertEqual(address["zip"] as? Int, 0)
    }

    func testRequestMappingMethodAndDefaultMethodsAreSkipped() throws {
        XCTAssertEqual(try call("partner-customer", "delete").method, .delete)
        XCTAssertFalse(result.calls.contains { $0.operation == "helper" })
    }

    func testServiceDiscoveryClientHasUnknownBase() throws {
        let stock = try call("inventory-service", "stock")
        XCTAssertEqual(stock.baseOrigin, .unknown)
        XCTAssertEqual(stock.path, "/inventory/stock")
        XCTAssertEqual(stock.query.map(\.key), ["sku"])
        XCTAssertFalse(stock.isComplete)
    }

    func testHTTPInterface() throws {
        let rate = try call("RatesApi", "rate")
        XCTAssertEqual(rate.source, .httpExchange)
        XCTAssertEqual(rate.baseOrigin, .property("fx.rates.url"))
        XCTAssertEqual(rate.path, "/rates/{{pair}}")
    }

    // MARK: - RestTemplate

    func testRestTemplateWithValueFieldAndConstant() throws {
        let post = try call("restTemplate", "postForObject")
        XCTAssertEqual(post.method, .post)
        XCTAssertEqual(post.baseOrigin, .property("partner.payment-url"))
        XCTAssertEqual(post.baseVariable, "partner-payment-url")
        XCTAssertEqual(post.path, "/payments")
        XCTAssertTrue(post.isComplete)
        XCTAssertEqual(post.bodyType, "PaymentRequest")
        XCTAssertNotNil(post.bodySample)
    }

    func testRestTemplateRuntimeValuesBecomePlaceholders() throws {
        let exchange = try call("restTemplate", "exchange")
        XCTAssertEqual(exchange.method, .get)
        XCTAssertEqual(exchange.path, "/payments/{{orderId}}")
        XCTAssertFalse(exchange.isComplete)
    }

    func testAbsoluteLiteralURLBecomesItsOwnVariableAndQuery() throws {
        let rates = try XCTUnwrap(result.calls.first { $0.baseOrigin == .literal("https://rates.example.com") })
        XCTAssertEqual(rates.path, "/v2/rates")
        XCTAssertEqual(rates.query.map(\.key), ["base"])
        XCTAssertEqual(rates.query.map(\.value), ["TRY"])
        XCTAssertTrue(rates.isComplete)
    }

    func testUnresolvableURLIsKeptAndMarkedIncomplete() throws {
        let built = try XCTUnwrap(result.calls.first { $0.client == "restTemplate" && $0.path.contains("{{buildUrl}}") })
        XCTAssertFalse(built.isComplete)
    }

    // MARK: - WebClient / RestClient

    func testWebClientBaseFromBeanInAnotherFile() throws {
        let post = try call("notificationWebClient", "post")
        XCTAssertEqual(post.source, .webClient)
        XCTAssertEqual(post.baseOrigin, .property("notification.url"))
        XCTAssertEqual(post.path, "/users/{{userId}}/notify")
        XCTAssertEqual(post.bodyType, "NotifyRequest")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(post.bodySample).utf8)) as? [String: Any])
        XCTAssertEqual(body["channels"] as? [String], ["string"])
    }

    func testWebClientURIBuilderLambda() throws {
        let get = try call("notificationWebClient", "get")
        XCTAssertEqual(get.path, "/templates")
        XCTAssertEqual(get.query.map(\.key), ["lang"])
    }

    func testRestClientCreateAndHeaders() throws {
        let get = try call("restClient", "get")
        XCTAssertEqual(get.source, .restClient)
        XCTAssertEqual(get.baseOrigin, .literal("https://geo.example.com"))
        XCTAssertEqual(get.path, "/cities/{{code}}")
        XCTAssertEqual(get.headers.first?.key, "X-Key")
    }

    func testTotalCount() {
        XCTAssertEqual(result.calls.count, 12, result.calls.map { "\($0.client).\($0.operation)" }.joined(separator: ", "))
    }

    // MARK: - Koleksiyon

    func testVariablesFollowTheSelectedProfile() throws {
        let test = OutboundCollectionBuilder.variables(for: result, profile: "test")
        XCTAssertEqual(test.first { $0.name == "partner-customer" }?.value, "https://partner.test.example")
        XCTAssertEqual(OutboundCollectionBuilder.variables(for: result, profile: "prep").first { $0.name == "partner-customer" }?.value,
                       "https://partner.prep.example")
        XCTAssertEqual(test.first { $0.name == "partner-payment-url" }?.value, "https://pay.example.com")
        XCTAssertEqual(test.first { $0.name == "notification-url" }?.value, "http://notify.local:8081")
        guard case .missing = try XCTUnwrap(test.first { $0.name == "inventory-service" }).status else {
            return XCTFail("servis keşfi değişkeni boş kalmalı")
        }
    }

    /// qa-engine'deki gerçek kalıp: adres @Value varsayılanından, ayarda yok.
    func testValueDefaultIsUsedWhenConfigHasNoKey() throws {
        let files: [(path: String, text: String)] = [("src/main/java/R.java", """
        @Component
        public class RunnerClient {
            private final WebClient webClient;
            public RunnerClient(WebClient.Builder builder,
                    @Value("${playwright.runner.base-url:http://localhost:3001}") String baseUrl) {
                this.webClient = WebClient.builder().baseUrl(baseUrl).build();
            }
            public Mono<X> run(RunRequest request) {
                return webClient.post().uri("/run-steps").bodyValue(request).retrieve().bodyToMono(X.class);
            }
        }
        """)]
        let scanned = try OutboundScanner.scan(files: files, projectName: "qa")
        let run = try XCTUnwrap(scanned.calls.first)
        XCTAssertEqual(run.baseVariable, "playwright-runner-base-url")
        XCTAssertEqual(run.path, "/run-steps")
        XCTAssertTrue(run.isComplete)
        XCTAssertEqual(OutboundCollectionBuilder.variables(for: scanned, profile: nil).first?.value, "http://localhost:3001")
    }

    /// Gerçek projede çökmeye yol açan kalıplar: argümanında `=` olan annotation'lar,
    /// ilk değerli alanlar, yarım ifadeler.
    func testRealWorldAnnotationsDoNotBreakFieldParsing() throws {
        let files: [(path: String, text: String)] = [
            ("src/main/java/E.java", """
            @Entity @Table(name = "x")
            @JsonIgnoreProperties(ignoreUnknown = true)
            public class OrderDto {
                @Column(name = "order_id", nullable = false)
                private Long id;
                @JsonFormat(shape = JsonFormat.Shape.STRING, pattern = "yyyy-MM-dd")
                private LocalDate day;
                private List<String> tags = new ArrayList<>();
                @JsonProperty(value = "full_name")
                private String name;
            }
            """),
            ("src/main/java/C.java", """
            @FeignClient(name = "orders", url = "http://orders.local")
            interface OrderClient {
                @PostMapping("/orders")
                void save(@RequestBody OrderDto dto);
                @GetMapping("/broken"
            }
            """),
        ]
        let scanned = try OutboundScanner.scan(files: files, projectName: "p")
        let save = try XCTUnwrap(scanned.calls.first { $0.operation == "save" })
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(save.bodySample).utf8)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["id", "day", "tags", "full_name"])
    }

    func testCredentialsInConfigAreNeverCopied() {
        XCTAssertTrue(OutboundCollectionBuilder.isSensitive(key: "partner.client-secret", value: "x"))
        XCTAssertTrue(OutboundCollectionBuilder.isSensitive(key: "partner.url", value: "https://kullanici:parola@a.example"))
        XCTAssertFalse(OutboundCollectionBuilder.isSensitive(key: "partner.url", value: "https://a.example"))
    }

    func testCollectionNamingAndReview() throws {
        let variables = OutboundCollectionBuilder.variables(for: result, profile: nil)
        let outcome = try OutboundCollectionBuilder.makeCollection(from: result, variables: variables, existingNames: [])
        let names = outcome.collection.requests.map(\.name)
        XCTAssertEqual(outcome.collection.name, "fx-bff — Giden İstekler")
        XCTAssertTrue(names.contains("partner-customer / getCustomer"))
        XCTAssertTrue(names.contains("PaymentService / POST /payments"))
        XCTAssertTrue(names.contains("PaymentService / GET /payments/{{orderId}} (eksik)"))
        XCTAssertEqual(Set(names).count, names.count, "adlar benzersiz")
        let create = try XCTUnwrap(outcome.collection.requests.first { $0.name == "partner-customer / create" })
        XCTAssertEqual(create.url, "{{partner-customer}}/api/customers")
        guard case .raw(_, "application/json") = create.body else { return XCTFail("JSON gövde bekleniyordu") }
        XCTAssertTrue(outcome.warnings.contains { $0.contains("{{inventory-service}}") })
        XCTAssertTrue(outcome.warnings.contains { $0.hasPrefix("Eksik: src/main/java/x/PaymentService.java:") })

        // Oluşan koleksiyon diğer içe aktarmalar gibi incelemeden geçer.
        let review = ImportReviewer.review(collection: outcome.collection, notes: outcome.warnings, context: .init(policy: .notConfigured, vaultSecretNames: []))
        let geo = try XCTUnwrap(review.requests.first { $0.request.url.contains("cities") })
        XCTAssertTrue(geo.findings.isEmpty || geo.findings.allSatisfy { $0.severity != .block })
    }

    // MARK: - Klasör taraması

    func testDirectoryScanSkipsTestsBuildOutputAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-scan-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let feign = #"@FeignClient(name = "gercek", url = "https://a.example") interface A { @GetMapping("/x") String x(); }"#
        try write("src/main/java/A.java", feign)
        try write("src/test/java/Sahte.java", feign.replacingOccurrences(of: "gercek", with: "test-sahte"))
        try write("target/generated/B.java", feign.replacingOccurrences(of: "gercek", with: "derlenmis"))
        try write("src/main/kotlin/K.kt", "class K")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-disari-\(UUID().uuidString).java")
        try Data(feign.replacingOccurrences(of: "gercek", with: "disari").utf8).write(to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("src/main/java/Link.java"), withDestinationURL: outside)

        let scanned = try OutboundScanner.scan(directory: root)
        XCTAssertEqual(Set(scanned.calls.map(\.client)), ["gercek"])
        XCTAssertTrue(scanned.notes.contains { $0.contains("1 Kotlin") })
    }
}
