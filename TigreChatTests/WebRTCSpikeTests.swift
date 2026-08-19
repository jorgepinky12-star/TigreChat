//
//  WebRTCSpikeTests.swift
//  TigreChatTests
//
//  SPIKE de toolchain (T-VOIPCALLS-002) — valida que el binario vendorizado
//  de WebRTC (M151) funciona en el simulador arm64: la fábrica instancia,
//  se crea un RTCPeerConnection con configuracion STUN/TURN (eturnal
//  ims-brz.z17.cu:3478), se genera un offer opus y se recolecta al menos
//  un candidato ICE local (typ host).
//
//  NO entra al gate de libros (requiere red para TURN y es un spike de
//  validacion, no una prueba de regresion). Se ejecuta explicitamente:
//    xcodebuild test ... -only-testing:TigreChatTests/WebRTCSpikeTests
//

import XCTest
@preconcurrency import WebRTC

@MainActor
final class WebRTCSpikeTests: XCTestCase {

    /// Recolector thread-safe de candidatos ICE y estado de gathering.
    private final class IceCollector: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _candidates: [RTCIceCandidate] = []
        private var _gatheringComplete = false
        var onGatheringComplete: (() -> Void)?

        var candidates: [RTCIceCandidate] {
            lock.lock(); defer { lock.unlock() }
            return _candidates
        }

        var gatheringComplete: Bool {
            lock.lock(); defer { lock.unlock() }
            return _gatheringComplete
        }

        func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
            lock.lock()
            _candidates.append(candidate)
            lock.unlock()
        }

        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
            if newState == .complete {
                lock.lock()
                _gatheringComplete = true
                lock.unlock()
                onGatheringComplete?()
            }
        }

        // Requeridos por el protocolo; no usados por el spike.
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCSignalingState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
        func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange candidates: [RTCIceCandidate]) {}
    }

    func testToolchainWebRTCGathersHostCandidate() throws {
        // 0. Handoff basico de audio: categoria play-and-record + activacion.
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try audioSession.setActive(true)

        // 1. Fábrica + configuración ICE. STUN apunta al eturnal del cambio
        //    (ims-brz.z17.cu:3478). El TURN real requiere credenciales validas —
        //    se configuran en M4/M5 (TURNConfig); aqui no las hay y WebRTC
        //    rechaza un servidor TURN sin username/password (INVALID_PARAMETER).
        //    El DoD del spike es un candidato ICE *host*: no necesita servidor.
        let factory = RTCPeerConnectionFactory()
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:ims-brz.z17.cu:3478"]),
        ]
        config.sdpSemantics = .unifiedPlan

        // 2. Peer connection con recolector de candidatos.
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let collector = IceCollector()
        let peerConnection = try XCTUnwrap(
            factory.peerConnection(with: config, constraints: constraints, delegate: collector),
            "RTCPeerConnectionFactory no pudo crear el peer connection"
        )
        defer { peerConnection.close() }

        // 3. Track de audio local (m=audio con opus) para forzar gathering.
        let audioSource = factory.audioSource(with: constraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "spike-audio-0")
        peerConnection.add(audioTrack, streamIds: ["spike-stream-0"])

        // 4. Offer + setLocalDescription (arranca el gathering).
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["OfferToReceiveAudio": "true"]
        )
        let offerExpectation = expectation(description: "offer creado")
        var generatedOffer: RTCSessionDescription?
        peerConnection.offer(for: offerConstraints) { sdp, error in
            if let error {
                XCTFail("offer(for:) fallo: \(error)")
            } else if let sdp {
                generatedOffer = sdp
            }
            offerExpectation.fulfill()
        }
        wait(for: [offerExpectation], timeout: 10)
        let offer = try XCTUnwrap(generatedOffer, "No se genero el offer SDP")
        XCTAssertTrue(offer.sdp.contains("opus"), "El SDP del offer no contiene opus: \(offer.sdp.prefix(300))")

        peerConnection.setLocalDescription(offer) { error in
            if let error {
                XCTFail("setLocalDescription fallo: \(error)")
            }
        }

        // 5. Esperar al final del gathering (los candidatos host son locales,
        //    no requieren red; el TURN/STUN solo anade reflexivos/servidor).
        let gatheringDone = expectation(description: "ICE gathering completo")
        collector.onGatheringComplete = { gatheringDone.fulfill() }
        _ = XCTWaiter.wait(for: [gatheringDone], timeout: 15)

        // 6. DoD: al menos un candidato host recolectado.
        let gathered = collector.candidates
        XCTAssertFalse(gathered.isEmpty, "No se recolecto ningun candidato ICE")
        let hostCandidates = gathered.filter { $0.sdp.contains("typ host") }
        XCTAssertFalse(
            hostCandidates.isEmpty,
            "Sin candidatos tipo host — toolchain rota. Recolectados: \(gathered.map(\.sdp))\n"
        )
    }
}