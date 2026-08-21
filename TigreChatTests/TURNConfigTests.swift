//
//  TURNConfigTests.swift
//  TigreChatTests
//
//  T-VOIPCALLS-051 (RED→GREEN): tests de configuración TURN.
//  REQ-CONFIG-002 (host-only sin crash), REQ-CONFIG-003 (nunca hang).
//

import XCTest
@testable import TigreChat

@MainActor
final class TURNConfigTests: XCTestCase {

    private var store: TURNCredentialStore!
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "TURNConfigTests_\(UUID().uuidString)")!
        store = TURNCredentialStore(defaults: defaults)
        store.clear()
    }

    override func tearDown() {
        store.clear()
    }

    // MARK: - REQ-CONFIG-002: host-only sin crash (rollback limpio)

    func testHostOnlyWithoutCredentials() throws {
        // Sin credenciales → host-only, no crash.
        let config = store.loadConfig()
        XCTAssertEqual(config.status, .hostOnly)
        XCTAssertNil(config.turnURL, "host-only no debe tener TURN URL")
        XCTAssertNotNil(config.stunURL, "STUN URL siempre presente")
    }

    func testClearRemovesAllCredentials() throws {
        store.turnHost = "turn.example.com"
        store.turnPort = 3478
        store.username = "user"
        store.credential = "pass"
        store.clear()

        let config = store.loadConfig()
        XCTAssertEqual(config.status, .hostOnly)
        XCTAssertNil(store.turnHost)
        XCTAssertNil(store.turnPort)
        XCTAssertNil(store.username)
        XCTAssertNil(store.credential)
    }

    // MARK: - REQ-CONFIG-003: credenciales completas → ready

    func testReadyWithCompleteCredentials() throws {
        store.turnHost = "turn.example.com"
        store.turnPort = 3478
        store.username = "user"
        store.credential = "pass"

        let config = store.loadConfig()
        XCTAssertEqual(config.status, .ready)
        XCTAssertEqual(config.turnURL, "turn:turn.example.com:3478")
    }

    // MARK: - Parcial → host-only

    func testPartialCredentialsHostOnly() throws {
        store.turnHost = "turn.example.com"
        // Sin username/credential → host-only.
        let config = store.loadConfig()
        XCTAssertEqual(config.status, .hostOnly)
    }

    // MARK: - Nunca hang (timeout implícito del test)

    func testLoadConfigDoesNotHang() throws {
        let start = Date()
        _ = store.loadConfig()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "loadConfig no debe tardar más de 1s")
    }

    // MARK: - Default host-only

    func testDefaultHostOnlyConfig() throws {
        let config = TURNConfig.defaultHostOnly
        XCTAssertEqual(config.status, .hostOnly)
        XCTAssertEqual(config.stunHost, "stun.l.google.com")
        XCTAssertEqual(config.stunPort, 19302)
    }
}
