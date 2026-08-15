//
//  OMEMORoundTripTests.swift
//  TigreChatTests
//
//  Pruebas unitarias de la capa OMEMO (XEP-0384) SIN servidor: dos
//  dispositivos simulados en un mismo proceso con Keychain/UserDefaults
//  aislados por servicio (`test-omemo-a` / `test-omemo-b`). Cubren:
//
//  1. Establecimiento de sesión X3DH (prekey message) + avance del ratchet
//     (signal message), en ambas direcciones.
//  2. Persistencia de la sesión en el Keychain compartido (un manager
//     FRESCO sobre el mismo store debe ver la sesión establecida).
//  3. Rechazo de un bundle cuya firma del signed prekey fue manipulada
//     (la verificación XEdDSA del vendor corre dentro de SessionCipher).
//  4. Consumo del one-time prekey usado: el PreKeySignalMessage entrante
//     borra el prekey del store del DESCRIPTOR.
//

import Foundation
import Security
import XCTest
@testable import TigreChat

@MainActor
final class OMEMORoundTripTests: XCTestCase {

    // MARK: - Escenario

    /// JID "falso" (no interviene ningún servidor): ambos dispositivos
    /// pertenecen a la misma cuenta.
    private let jid = "prueba@ejemplo.test"
    private let deviceIdA: UInt32 = 1001
    private let deviceIdB: UInt32 = 1002
    private let serviceA = "test-omemo-a"
    private let serviceB = "test-omemo-b"

    // MARK: - Ciclo de vida

    override func setUp() async throws {
        try await super.setUp()
        // Cada test parte de un Keychain limpio para los dos servicios de
        // prueba: sin sesiones/identidades residuales entre ejecuciones
        // (repetir el suite no debe degradar el escenario .preKey → .signal).
        Self.purgeKeychain(services: [serviceA, serviceB])
    }

    /// Borra los items Keychain que usan `KeyManager` y `OMEMOSignalStore`
    /// (comparten los blobs `identity`/`signedprekey`/`prekey`).
    private static func purgeKeychain(services: [String]) {
        let tags = ["identity", "signedprekey", "prekey"]
            + Self.sessionTags
            + Self.identityTags
        for service in services {
            for tag in tags {
                KeychainBlobs.delete(tag: tag, service: service)
            }
        }
    }

    private static var sessionTags: [String] {
        ["sigsession_prueba@ejemplo.test_1001", "sigsession_prueba@ejemplo.test_1002"]
    }

    private static var identityTags: [String] {
        ["sigidentity_prueba@ejemplo.test_1001", "sigidentity_prueba@ejemplo.test_1002"]
    }

    // MARK: - Helpers

    /// Pareja de dispositivos con almacenamiento aislado. Los servicios de los
    /// KeyManager y de los stores coinciden PARA CADA dispositivo: la capa
    /// Signal lee del MISMO blob `identity` que el KeyManager publica en el
    /// bundle (invariante del diseño compartido).
    private func makeDevicePair() -> (
        kmA: KeyManager, kmB: KeyManager,
        storeA: OMEMOSignalStore, storeB: OMEMOSignalStore,
        managerA: OMEMOSessionManager, managerB: OMEMOSessionManager
    ) {
        let kmA = KeyManager(deviceId: deviceIdA, service: serviceA)
        let kmB = KeyManager(deviceId: deviceIdB, service: serviceB)
        let storeA = OMEMOSignalStore(
            service: serviceA,
            userDefaults: UserDefaults(suiteName: serviceA)!
        )
        let storeB = OMEMOSignalStore(
            service: serviceB,
            userDefaults: UserDefaults(suiteName: serviceB)!
        )
        return (
            kmA, kmB,
            storeA, storeB,
            OMEMOSessionManager(store: storeA),
            OMEMOSessionManager(store: storeB)
        )
    }

    /// Construye el bundle público de un dispositivo tal y como lo serviría
    /// el nodo PEP del servidor (primeros 3 prekeys).
    private func makeBundle(for km: KeyManager) -> OMEMOBundle? {
        guard let identity = km.identityKeyPair, let signedPreKey = km.signedPreKey else { return nil }
        let preKeys = km.preKeys.prefix(3).map { PreKeyPublic(id: $0.id, publicKey: $0.publicKey) }
        return OMEMOBundle(
            deviceId: km.deviceId,
            identityKey: identity.publicKey,
            signedPreKey: SignedPreKeyPublic(
                id: signedPreKey.id,
                publicKey: signedPreKey.publicKey,
                signature: signedPreKey.signature
            ),
            preKeys: preKeys
        )
    }

    /// Session key AES-256 (32 bytes) aleatoria, como la genera el módulo.
    private func randomSessionKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// Copia de `signature` con los 4 primeros bytes volteados.
    private func flippedSignature(_ signature: Data) -> Data {
        var flipped = signature
        for index in 0..<4 {
            flipped[flipped.startIndex + index] ^= 0xFF
        }
        return flipped
    }

    // MARK: - Pruebas

    /// Flujo X3DH/Double Ratchet REAL del wire OMEMO (XEP-0384): A inicia con
    /// un `.preKey` (consumiendo el one-time prekey de B), B responde con
    /// `.signal` usando el ratchet ya establecido, y el `pendingPreKey` de A
    /// (que obliga al wrapper `.preKey`) se limpia SOLO al descifrar la
    /// respuesta (SessionCipher.decrypt: `state.pendingPreKey = nil`).
    /// Recién entonces el segundo mensaje de A viaja como `.signal`.
    func testSessionEstablishmentAndRoundTrip() async throws {
        let pair = makeDevicePair()
        let bundleB = try XCTUnwrap(makeBundle(for: pair.kmB), "B debe tener identidad y signed prekey")
        let sessionKey = randomSessionKey()

        // A → B: primer mensaje, establece X3DH con el bundle publicado por B
        // (SessionBuilder.process deja pendingPreKey → el envío va como .preKey).
        try await pair.managerA.processBundle(bundleB, jid: jid)
        let cipher1 = try await pair.managerA.encryptSessionKey(sessionKey, jid: jid, deviceId: deviceIdB)
        XCTAssertEqual(cipher1.type, .preKey, "El primer mensaje de una sesión nueva debe ser .preKey")

        let decrypted1 = try await pair.managerB.decryptSessionKey(cipher1, jid: jid, deviceId: deviceIdA)
        XCTAssertEqual(decrypted1, sessionKey, "B debe recuperar la session key de A")

        // B → A: B responde SIN gastar prekey de A (el PreKeySignalMessage
        // entrante ya estableció su lado del par; no necesita el bundle de A).
        // El estado de B nace sin pendingPreKey → su primer mensaje es .signal.
        let cipherB1 = try await pair.managerB.encryptSessionKey(sessionKey, jid: jid, deviceId: deviceIdA)
        XCTAssertEqual(cipherB1.type, .signal, "B (lado Bob del par X3DH) responde con .signal sin consumir prekey")

        let decryptedB1 = try await pair.managerA.decryptSessionKey(cipherB1, jid: jid, deviceId: deviceIdB)
        XCTAssertEqual(decryptedB1, sessionKey, "A debe recuperar la session key de B")

        // A → B: con el ACK de B descifrado (pendingPreKey de A ya nulo), el
        // segundo mensaje de A viaja como .signal con el ratchet establecido.
        let cipher2 = try await pair.managerA.encryptSessionKey(sessionKey, jid: jid, deviceId: deviceIdB)
        XCTAssertEqual(cipher2.type, .signal, "El segundo mensaje debe usar el ratchet establecido")

        let decrypted2 = try await pair.managerB.decryptSessionKey(cipher2, jid: jid, deviceId: deviceIdA)
        XCTAssertEqual(decrypted2, sessionKey, "El ratchet avanzado debe descifrar en B")

        // B conserva el ratchet: sus siguientes mensajes siguen siendo .signal.
        let cipherB2 = try await pair.managerB.encryptSessionKey(sessionKey, jid: jid, deviceId: deviceIdA)
        XCTAssertEqual(cipherB2.type, .signal, "B mantiene el ratchet establecido en sus mensajes siguientes")

        let decryptedB2 = try await pair.managerA.decryptSessionKey(cipherB2, jid: jid, deviceId: deviceIdB)
        XCTAssertEqual(decryptedB2, sessionKey, "El segundo mensaje de B debe descifrar en A")
    }

    /// La sesión establecida SOLO entre A y el bundle de B queda persistida en
    /// el Keychain del service A: un manager recién creado sobre el mismo
    /// store la ve sin haber hecho ningún intercambio en memoria.
    func testSessionPersistenceInKeychain() async throws {
        let pair = makeDevicePair()
        let bundleB = try XCTUnwrap(makeBundle(for: pair.kmB), "B debe tener identidad y signed prekey")

        try await pair.managerA.processBundle(bundleB, jid: jid)
        _ = try await pair.managerA.encryptSessionKey(randomSessionKey(), jid: jid, deviceId: deviceIdB)

        // Manager FRESCO + storeA: la sesión debe haber sobrevivido porque el
        // estado vive en el Keychain compartido (blob `sigsession_<jid>_<dev>`).
        let freshManagerA = OMEMOSessionManager(store: pair.storeA)
        let hasSessionAToB = await freshManagerA.hasSession(jid: jid, deviceId: deviceIdB)
        XCTAssertTrue(hasSessionAToB, "La sesión A→B debe persistir en el Keychain del service A")
        // Sanidad: la sesión inversa (que nunca se estableció) NO existe.
        let hasSessionToSelf = await freshManagerA.hasSession(jid: jid, deviceId: deviceIdA)
        XCTAssertFalse(hasSessionToSelf, "No debe existir sesión con el propio dispositivo A")
    }

    /// Un bundle con la firma del signed prekey manipulada se rechaza: la
    /// verificación XEdDSA del vendor (SessionBuilder.process) falla y
    /// `processBundle` mapea el error a `OMEMOError.sessionBuildFailed`.
    /// Además, el rechazo NO deja sesión a medias en el store.
    func testRejectSignedPreKeyWithTamperedSignature() async throws {
        let pair = makeDevicePair()
        let original = try XCTUnwrap(makeBundle(for: pair.kmB), "B debe tener identidad y signed prekey")

        let tampered = OMEMOBundle(
            deviceId: original.deviceId,
            identityKey: original.identityKey,
            signedPreKey: SignedPreKeyPublic(
                id: original.signedPreKey.id,
                publicKey: original.signedPreKey.publicKey,
                signature: flippedSignature(original.signedPreKey.signature)
            ),
            preKeys: original.preKeys
        )

        do {
            try await pair.managerA.processBundle(tampered, jid: jid)
            XCTFail("Un bundle con firma manipulada no debe aceptarse")
        } catch let error as OMEMOError {
            guard case .sessionBuildFailed = error else {
                return XCTFail("Se esperaba OMEMOError.sessionBuildFailed, se obtuvo \(error)")
            }
        } catch {
            XCTFail("Error inesperado: \(error)")
        }

        let hasSessionAfterReject = await pair.managerA.hasSession(jid: jid, deviceId: deviceIdB)
        XCTAssertFalse(hasSessionAfterReject, "El bundle rechazado no debe haber creado sesión")
    }

    /// El one-time prekey usado por el PreKeySignalMessage se CONSUME: tras el
    /// descifrado en B, el store de B ya no contiene ese id (SessionCipher
    /// borra el prekey del descriptor, SessionCipher.swift decrypt).
    func testPreKeyConsumedOnce() async throws {
        let pair = makeDevicePair()
        let bundleB = try XCTUnwrap(makeBundle(for: pair.kmB), "B debe tener identidad y signed prekey")
        let usedPreKeyId = try XCTUnwrap(bundleB.preKeys.first?.id, "El bundle de B debe traer prekeys")

        XCTAssertTrue(
            pair.storeB.preKeyStore.containsPreKey(for: usedPreKeyId),
            "El prekey debe existir antes de consumirse"
        )

        try await pair.managerA.processBundle(bundleB, jid: jid)
        let cipher = try await pair.managerA.encryptSessionKey(randomSessionKey(), jid: jid, deviceId: deviceIdB)
        XCTAssertEqual(cipher.type, .preKey, "El mensaje debe ser .preKey para consumir el prekey")
        _ = try await pair.managerB.decryptSessionKey(cipher, jid: jid, deviceId: deviceIdA)

        XCTAssertFalse(
            pair.storeB.preKeyStore.containsPreKey(for: usedPreKeyId),
            "El prekey usado debe quedar consumido en el store del receptor (B)"
        )
    }
}