import Foundation
import Network
import os

nonisolated(unsafe) let connLog = OSLog(subsystem: "com.tigrechat", category: "Connection")

enum XMPPConnectionError: Error, Sendable {
    case invalidHost
    case connectionFailed(String)
    case tlsFailed(String)
    case disconnected
    case timedOut
}

extension XMPPConnectionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidHost: return "Invalid host"
        case .connectionFailed(let text): return "Connection failed: \(text)"
        case .tlsFailed(let text): return "TLS error: \(text)"
        case .disconnected: return "Disconnected"
        case .timedOut: return "Connection timed out"
        }
    }
}

final class XMPPConnection: Sendable {
    private actor State {
        var connection: NWConnection?
        var isConnected = false
        var receiveTask: Task<Void, Never>?

        func setConnection(_ conn: NWConnection?) { connection = conn }
        func getConnection() -> NWConnection? { connection }
        func markConnected(_ v: Bool) { isConnected = v }
        func isConn() -> Bool { isConnected }
        func setReceiveTask(_ task: Task<Void, Never>?) { receiveTask = task }
        func getReceiveTask() -> Task<Void, Never>? { receiveTask }
    }

    private let state = State()
    private let queue = DispatchQueue(label: "com.tigrechat.xmpp.nw", qos: .userInitiated)
    private let receiveContinuation: AsyncStream<Data>.Continuation
    let receiveStream: AsyncStream<Data>

    init() {
        var cont: AsyncStream<Data>.Continuation!
        receiveStream = AsyncStream { continuation in
            cont = continuation
        }
        receiveContinuation = cont
    }

    func connect(host: String, port: Int, useTLS: Bool) async throws {
        await disconnectInternal()
        os_log("[NW] Connecting to %{public}s:%d (TLS: %d)", log: connLog, type: .info, host, port, useTLS)

        let parameters: NWParameters
        if useTLS {
            let tlsOpts = NWProtocolTLS.Options()
            parameters = NWParameters(tls: tlsOpts)
        } else {
            parameters = NWParameters.tcp
        }
        parameters.serviceClass = .responsiveData
        parameters.allowLocalEndpointReuse = true

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw XMPPConnectionError.invalidHost
        }

        let conn = NWConnection(host: nwHost, port: nwPort, using: parameters)
        await state.setConnection(conn)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    os_log("[NW] Connected", log: connLog, type: .info)
                    Task { await self.state.markConnected(true) }
                    cont.resume()
                case .failed(let error):
                    os_log("[NW] Failed: %{public}s", log: connLog, type: .error, error.localizedDescription)
                    cont.resume(throwing: XMPPConnectionError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    Task { await self.state.markConnected(false) }
                case .waiting(let error):
                    os_log("[NW] Waiting: %{public}s", log: connLog, type: .info, error.localizedDescription)
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            conn.start(queue: self.queue)
        }

        await startReceiveLoop()
    }

    private func startReceiveLoop() async {
        let task = Task { [weak self] in
            guard let self else { return }
            let conn = await self.state.getConnection()
            guard let conn else { return }
            while !Task.isCancelled {
                let isConn = await self.state.isConn()
                guard isConn else { break }
                do {
                    let data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                            if let data, !data.isEmpty {
                                cont.resume(returning: data)
                            } else if let error {
                                os_log("[NW] Receive callback error: %{public}s", log: connLog, type: .error, error.localizedDescription)
                                cont.resume(throwing: XMPPConnectionError.connectionFailed("NW: \(error.localizedDescription)"))
                            } else if isComplete {
                                os_log("[NW] Receive callback complete (server closed)", log: connLog, type: .info)
                                cont.resume(throwing: XMPPConnectionError.disconnected)
                            }
                        }
                    }
                    if let received = String(data: data, encoding: .utf8) {
                        os_log("[NW] Recv: %{public}s", log: connLog, type: .debug, String(received.prefix(300)))
                    }
                    self.receiveContinuation.yield(data)
                } catch {
                    os_log("[NW] Receive error: %{public}s", log: connLog, type: .info, error.localizedDescription)
                    if let nwErr = error as? NWError {
                        os_log("[NW] NWError: %d %{public}s", log: connLog, type: .info, nwErr.errorCode, nwErr.localizedDescription)
                    }
                    break
                }
            }
            os_log("[NW] Receive loop ended", log: connLog, type: .info)
        }
        await state.setReceiveTask(task)
    }

    func send(data: Data) async throws {
        guard let conn = await state.getConnection(), await state.isConn() else {
            throw XMPPConnectionError.disconnected
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: XMPPConnectionError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    func send(string: String) async throws {
        os_log("[NW] Send: %{public}s", log: connLog, type: .debug, String(string.prefix(200)))
        guard let data = string.data(using: .utf8) else { return }
        try await send(data: data)
    }

    func disconnect() async {
        await disconnectInternal()
    }

    private func disconnectInternal() async {
        await state.getReceiveTask()?.cancel()
        await state.setReceiveTask(nil)
        if let conn = await state.getConnection() {
            conn.cancel()
        }
        await state.setConnection(nil)
        await state.markConnected(false)
    }
}
