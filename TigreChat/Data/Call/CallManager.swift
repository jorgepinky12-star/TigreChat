import Foundation
import CallKit
import PushKit
import AVFoundation

@MainActor
final class CallManager: NSObject {
    static let shared = CallManager()

    let provider: CXProvider
    let callController = CXCallController()
    private let pushRegistry = PKPushRegistry(queue: .main)

    var onAnswer: ((UUID) -> Void)?
    var onEnd: ((UUID) -> Void)?
    var onMute: ((UUID, Bool) -> Void)?
    var onStartCall: ((UUID, String) -> Void)?

    var hasPendingCall: Bool { activeCallUUID != nil }
    internal var activeCallUUID: UUID?
    private var callCompletion: ((Bool) -> Void)?

    override init() {
        let config = CXProviderConfiguration(localizedName: "TigreChat")
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 2
        config.supportedHandleTypes = [.emailAddress]
        config.includesCallsInRecents = true
        config.iconTemplateImageData = nil

        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)

        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
    }

    // MARK: - Actions

    func reportIncomingCall(uuid: UUID, jid: String, hasVideo: Bool) async throws {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .emailAddress, value: jid)
        update.hasVideo = hasVideo
        update.localizedCallerName = jid.components(separatedBy: "@").first ?? jid

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.reportNewIncomingCall(with: uuid, update: update) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        activeCallUUID = uuid
    }

    func startCall(uuid: UUID, jid: String, isVideo: Bool) {
        let handle = CXHandle(type: .emailAddress, value: jid)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = isVideo

        let transaction = CXTransaction(action: action)
        callController.request(transaction) { error in
            if let error { print("CallKit startCall error: \(error)") }
        }
        activeCallUUID = uuid
    }

    func endCall() {
        guard let uuid = activeCallUUID else { return }
        let action = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { _ in }
        activeCallUUID = nil
    }

    func endCall(uuid: UUID) {
        provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        if activeCallUUID == uuid { activeCallUUID = nil }
    }

    func reportOutgoingCallConnecting(uuid: UUID) {
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
    }

    func reportOutgoingCallConnected(uuid: UUID) {
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// El remoto/otro extremo terminó la llamada: el sistema la da por
    /// finalizada sin acción de usuario (arsenal del seam D7).
    func reportRemoteEnded(uuid: UUID) {
        provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        if activeCallUUID == uuid { activeCallUUID = nil }
    }

    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    // MARK: - PushKit Token

    var voipToken: String? {
        didSet {
            if let token = voipToken { print("VoIP token: \(token)") }
        }
    }
}

// MARK: - Seam CallKit (D7 del diseño, M2)

extension CallManager: CallKitAdapting {}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        activeCallUUID = nil
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        configureAudioSession()
        onAnswer?(action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        onEnd?(action.callUUID)
        activeCallUUID = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onMute?(action.callUUID, action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureAudioSession()
        onStartCall?(action.callUUID, action.handle.value)
        action.fulfill()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        configureAudioSession()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}

// MARK: - PKPushRegistryDelegate

extension CallManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        voipToken = token
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        let dict = payload.dictionaryPayload
        let jid = dict["jid"] as? String ?? "unknown"
        let uuid = UUID()

        Task { [weak self] in
            try? await self?.reportIncomingCall(uuid: uuid, jid: jid, hasVideo: false)
            completion()
        }
    }
}
