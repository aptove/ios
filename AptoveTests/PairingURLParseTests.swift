import XCTest
@testable import Aptove

/// Tests for `PairingURL.parse()` — validates URL parsing for all transport
/// types, including Tailscale multi-instance path-prefixed URLs.
final class PairingURLParseTests: XCTestCase {

    // MARK: - Local transport (no path prefix)

    func testLocalPairingURL() throws {
        let result = try PairingURL.parse(
            "https://192.168.1.100:8765/pair/local?code=123456&fp=SHA256%3AABCD1234"
        )
        assertPairingType(result.pairingType, expected: .local)
        XCTAssertEqual(result.code, "123456")
        XCTAssertEqual(result.fingerprint, "SHA256:ABCD1234")
        XCTAssertEqual(result.baseURL.absoluteString, "https://192.168.1.100:8765")
        XCTAssertEqual(result.websocketURL, "wss://192.168.1.100:8765")
    }

    func testLocalPairingURLNoFingerprint() throws {
        let result = try PairingURL.parse(
            "https://192.168.1.100:8765/pair/local?code=999999"
        )
        assertPairingType(result.pairingType, expected: .local)
        XCTAssertEqual(result.code, "999999")
        XCTAssertNil(result.fingerprint)
        XCTAssertEqual(result.baseURL.absoluteString, "https://192.168.1.100:8765")
    }

    // MARK: - Tailscale transport (no path prefix — legacy)

    func testTailscalePairingURLNoPrefix() throws {
        let result = try PairingURL.parse(
            "https://my-laptop.tail1234.ts.net/pair/tailscale?code=847291"
        )
        assertPairingType(result.pairingType, expected: .tailscale)
        XCTAssertEqual(result.code, "847291")
        XCTAssertNil(result.fingerprint)
        XCTAssertEqual(result.baseURL.absoluteString, "https://my-laptop.tail1234.ts.net")
        XCTAssertEqual(result.websocketURL, "wss://my-laptop.tail1234.ts.net")
    }

    // MARK: - Tailscale transport (with path prefix — multi-instance)

    func testTailscalePairingURLWithPathPrefix() throws {
        let result = try PairingURL.parse(
            "https://my-laptop.tail1234.ts.net/dd4830e8/pair/tailscale?code=666526"
        )
        assertPairingType(result.pairingType, expected: .tailscale)
        XCTAssertEqual(result.code, "666526")
        XCTAssertNil(result.fingerprint)
        XCTAssertEqual(result.baseURL.absoluteString, "https://my-laptop.tail1234.ts.net/dd4830e8")
        XCTAssertEqual(result.websocketURL, "wss://my-laptop.tail1234.ts.net/dd4830e8")
    }

    func testTailscalePairingURLPreservesFullURL() throws {
        let urlString = "https://my-laptop.tail1234.ts.net/abc12345/pair/tailscale?code=111111"
        let result = try PairingURL.parse(urlString)
        XCTAssertEqual(result.fullURL.absoluteString, urlString)
    }

    // MARK: - Plugin transport (with path prefix)

    func testPluginPairingURLWithPathPrefix() throws {
        let result = try PairingURL.parse(
            "https://my-laptop.tail1234.ts.net/abc12345/pair/cloudflare?code=222222"
        )
        if case .plugin(let name) = result.pairingType {
            XCTAssertEqual(name, "cloudflare")
        } else {
            XCTFail("Expected .plugin(cloudflare), got \(result.pairingType)")
        }
        XCTAssertEqual(result.baseURL.absoluteString, "https://my-laptop.tail1234.ts.net/abc12345")
    }

    // MARK: - Error cases

    func testMissingPairPathThrows() {
        XCTAssertThrowsError(try PairingURL.parse(
            "https://192.168.1.100:8765/something/else?code=123456"
        )) { error in
            guard case PairingError.invalidURL(let reason) = error else {
                return XCTFail("Expected invalidURL, got \(error)")
            }
            XCTAssert(reason.contains("/pair/"))
        }
    }

    func testMissingCodeThrows() {
        XCTAssertThrowsError(try PairingURL.parse(
            "https://192.168.1.100:8765/pair/local"
        )) { error in
            guard case PairingError.missingCode = error else {
                return XCTFail("Expected missingCode, got \(error)")
            }
        }
    }

    func testEmptyCodeThrows() {
        XCTAssertThrowsError(try PairingURL.parse(
            "https://192.168.1.100:8765/pair/local?code="
        )) { error in
            guard case PairingError.missingCode = error else {
                return XCTFail("Expected missingCode, got \(error)")
            }
        }
    }

    func testInvalidSchemeThrows() {
        XCTAssertThrowsError(try PairingURL.parse(
            "ftp://192.168.1.100:8765/pair/local?code=123456"
        )) { error in
            guard case PairingError.invalidURL = error else {
                return XCTFail("Expected invalidURL, got \(error)")
            }
        }
    }

    // MARK: - WebSocket URL derivation

    func testWebsocketURLLocalHTTPS() throws {
        let result = try PairingURL.parse(
            "https://192.168.1.100:8765/pair/local?code=123456"
        )
        XCTAssertEqual(result.websocketURL, "wss://192.168.1.100:8765")
    }

    func testWebsocketURLLocalHTTP() throws {
        let result = try PairingURL.parse(
            "http://192.168.1.100:8765/pair/local?code=123456"
        )
        XCTAssertEqual(result.websocketURL, "ws://192.168.1.100:8765")
    }

    func testWebsocketURLTailscaleWithPrefix() throws {
        let result = try PairingURL.parse(
            "https://my-laptop.tail1234.ts.net/abc12345/pair/tailscale?code=123456"
        )
        XCTAssertEqual(result.websocketURL, "wss://my-laptop.tail1234.ts.net/abc12345")
    }

    // MARK: - Helpers

    private func assertPairingType(_ actual: PairingType, expected: PairingType, file: StaticString = #file, line: UInt = #line) {
        switch (actual, expected) {
        case (.local, .local):
            break
        case (.tailscale, .tailscale):
            break
        case (.plugin(let a), .plugin(let b)):
            XCTAssertEqual(a, b, file: file, line: line)
        default:
            XCTFail("Expected \(expected), got \(actual)", file: file, line: line)
        }
    }
}
