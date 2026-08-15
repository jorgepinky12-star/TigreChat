import Foundation
import os
import Darwin
import NIO
import NIOEmbedded
import NIOTLS
import NIOSSL

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

// MARK: - NIOSSL handshake watcher
//
// NIOSSL reports handshake completion/failure as user inbound events on the
// channel. The watcher records them so the synchronous pump loop below can
// detect completion without running an event loop.

private final class HandshakeWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private(set) var completed = false
    private(set) var failure: String?

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? TLSUserEvent {
            switch e {
            case .handshakeCompleted:
                completed = true
                os_log("[TLS] handshakeCompleted user event", log: connLog, type: .debug)
            case .shutdownCompleted:
                os_log("[TLS] shutdownCompleted", log: connLog, type: .debug)
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failure = "\(error)"
        context.fireErrorCaught(error)
    }
}

// MARK: - Trust anchors (synchronous BoringSSL verification)
//
// With `trustRoots == .default` (or `.none`) on Darwin, NIOSSL validates the
// peer certificate via Security.framework's ASYNC SecTrustEvaluate on a
// private queue, which then hops back onto the channel's event loop. That
// hop trips EmbeddedEventLoop's thread-safety check (it is not thread-safe).
// Setting an explicit certificate set makes NIOSSL use BoringSSL's own
// synchronous X509 chain verification instead — safe for EmbeddedChannel —
// while hostname validation stays enabled (.fullVerification default).
//
// iOS does not expose SecTrustCopyAnchorCertificates (macOS-only), so the
// server's root CA is embedded instead (root-level pinning). ims-brz.z17.cu
// serves a Let's Encrypt chain that terminates in ISRG Root X2 (2026
// hierarchy, cross-signed by ISRG Root X1); X1 is included as a second
// anchor so verification survives chain reconfigurations that omit X2.

private enum TrustAnchors {
    /// Decodes embedded DER. `Data(base64Encoded:)` rejects newlines, so the
    /// wrapped literals below must be flattened before decoding.
    private static func der(_ base64: String) -> Data {
        guard let data = Data(base64Encoded: base64.filter { !$0.isWhitespace }) else {
            preconditionFailure("Embedded trust anchor is not valid base64")
        }
        return data
    }

    /// ISRG Root X1 (Let's Encrypt real trust root; cross-signing parent of X2).
    private static let isrgRootX1DER = der("""
        MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
        TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
        cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
        WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
        ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
        MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
        h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
        0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
        A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
        T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
        B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
        B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
        KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
        OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
        jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
        qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
        rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
        HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
        hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
        ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
        3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
        NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
        ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
        TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
        jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
        oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
        4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
        mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
        emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
        """)

    /// ISRG Root X2 (Let's Encrypt 2026 hierarchy root; the final certificate
    /// of the server's chain).
    private static let isrgRootX2DER = der("""
        MIIEcDCCAligAwIBAgIQbI8dxyfHEX97r4U6yYD5zTANBgkqhkiG9w0BAQsFADBP
        MQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJuZXQgU2VjdXJpdHkgUmVzZWFy
        Y2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBYMTAeFw0yNjA1MTMwMDAwMDBa
        Fw0zMjA5MDIyMzU5NTlaME8xCzAJBgNVBAYTAlVTMSkwJwYDVQQKEyBJbnRlcm5l
        dCBTZWN1cml0eSBSZXNlYXJjaCBHcm91cDEVMBMGA1UEAxMMSVNSRyBSb290IFgy
        MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEzZvVn4CDCuwJSvMWSj5cz3es3mcFDR0H
        ttwW+1qLFNvicWDEukWVEYmO6gbf9yoWHKS5xcUy4APgHoIYOIvXRdgKam7mAHf7
        AlF9ItgKbppbd9/w+kHsOdx1ymgHDB/qo4H1MIHyMA4GA1UdDwEB/wQEAwIBBjAd
        BgNVHSUEFjAUBggrBgEFBQcDAQYIKwYBBQUHAwIwDwYDVR0TAQH/BAUwAwEB/zAd
        BgNVHQ4EFgQUfEKWrt5LSDv6kviejM9ti6lyN5UwHwYDVR0jBBgwFoAUebRZ5nu2
        5eQBc4AIiMgaWPbpm24wMgYIKwYBBQUHAQEEJjAkMCIGCCsGAQUFBzAChhZodHRw
        Oi8veDEuaS5sZW5jci5vcmcvMBMGA1UdIAQMMAowCAYGZ4EMAQIBMCcGA1UdHwQg
        MB4wHKAaoBiGFmh0dHA6Ly94MS5jLmxlbmNyLm9yZy8wDQYJKoZIhvcNAQELBQAD
        ggIBAD2/e9frmMxNpCV03qUHegg+MV2wz9644YoXdqtH8RyWYcBO7xfjjGEXdU1e
        /o0OkEFiynUCOSIk/vLLo7ttz6CPAeNlWfC0XNkoGeWgK6jjXvozBaGuGH5n0Ufo
        shMeWTuURqNN5G00sSXDTBrpp2+mgvdZQjb8K11TYMA25QA+YHNfbIEL0BniAhKS
        2gsnJjSzrdZLI+EZ7SEyqdR2rkjd1KutLDU+n3TFyxjniZVGur4YlhMP3mY/dV95
        IruAkkjOZier6hGBdEgZXXvaCz9u9iVEadsIE75pAGL8oHV5vxdARDiotRpul1IN
        /UZwzAbrfUFcw1HkAcYD/mlZfnQ2ieCF2MS7j3Vhv7JPDKp45fmykmzYNSrumRW0
        upFFKDBOoF7hsOb7oLyHS+Uft6jOUfOrogj8YUx38hKb2K20r42OgsSdDdxdeYWc
        MS3Sb6mwJeSZEYxJ2gaXnDSPaKhhrNkYwljyVQyr4Nq+MEJytXNTnHqaAcrNwZlV
        pcJL1KBnMrMjP7eanvUwL3FYj3cF17jtboLt7gLoi4+2rWZFvn+w54jmd/FIuhhZ
        cEaU/wvU6BUNMtcVquVGHp7itQeDth5j+XL3j4WJ2SABwzUl6OeYdgpIt/ITZa+p
        TT0mQ/r5XyA4MEAiabn7XJjvCERlF2dcn2wqJw+CreTkkQ2R
        """)

    static func certificates() throws -> [NIOSSLCertificate] {
        try [isrgRootX2DER, isrgRootX1DER].map {
            try NIOSSLCertificate(bytes: Array($0), format: .der)
        }
    }
}

// MARK: - Transport
//
// Network.framework cannot upgrade an already-open connection to TLS, which
// is exactly what XMPP STARTTLS requires. NIOSSL (BoringSSL) can wrap an
// existing POSIX socket in-band, so the transport below is: POSIX socket +
// optional NIOSSL pump on top of the same fd. The TLS stack runs inside an
// EmbeddedChannel; the pump moves ciphertext between the socket and the
// channel and serves plaintext to the XMPP layer.
//
// Thread-safety: EmbeddedEventLoop is NOT thread-safe — it may only be
// touched from the thread that created it (any other thread prints "NIO API
// misuse: EmbeddedEventLoop is not thread-safe" and future NIO releases will
// crash). A Swift actor does NOT guarantee a single thread (its methods run
// on any thread of the cooperative pool), so all channel/socket work runs on
// ONE dedicated thread, serialized through a small job queue with a
// synchronous wait-and-return for each public call.

private final class Transport: @unchecked Sendable {
    enum ReadResult: Sendable {
        case data(Data)
        case wouldBlock
        case closed
    }

    // MARK: Single-thread job executor (the TLS thread)

    private let jobLock = NSLock()
    private var jobs: [() -> Void] = []
    private let jobSignal = DispatchSemaphore(value: 0)

    private func runJobLoop() {
        while true {
            jobLock.lock()
            while jobs.isEmpty {
                jobLock.unlock()
                jobSignal.wait()
                jobLock.lock()
            }
            let job = jobs.removeFirst()
            jobLock.unlock()
            job()
        }
    }

    /// Enqueues `body` on the TLS thread and blocks the caller until it
    /// returns. Every public operation below funnels through this, so all
    /// fd/channel access is serialized on one fixed thread.
    private func enqueueAndWait<T>(_ body: @escaping () -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        var result: T!
        jobLock.lock()
        jobs.append {
            result = body()
            done.signal()
        }
        jobLock.unlock()
        jobSignal.signal()
        done.wait()
        return result
    }

    // MARK: State (TLS-thread-only)

    private var fd: Int32 = -1
    private var tlsChannel: EmbeddedChannel?
    private var tlsActive = false

    init() {
        let thread = Thread { [weak self] in
            self?.runJobLoop()
        }
        thread.name = "tigrechat.tls"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // MARK: Public API (any thread; serialized on the TLS thread)

    /// Resolves the host and opens a non-blocking TCP connection.
    func connect(host: String, port: Int) -> Bool {
        enqueueAndWait { self.connectImpl(host: host, port: port) }
    }

    /// Creates the NIOSSL pump bound to the open fd and runs the TLS
    /// handshake (used both for DirectTLS and in-band STARTTLS).
    func startTLS(domain: String) -> Bool {
        enqueueAndWait { self.startTLSImpl(domain: domain) }
    }

    func isTLSActive() -> Bool {
        enqueueAndWait { self.tlsActive }
    }

    func read(maxLength: Int) -> ReadResult {
        enqueueAndWait { self.readImpl(maxLength: maxLength) }
    }

    /// Writes everything, waiting for the socket to become writable on EAGAIN.
    func write(_ data: Data) -> Bool {
        enqueueAndWait { self.writeImpl(data) }
    }

    func teardown() {
        enqueueAndWait { self.teardownImpl() }
    }

    // MARK: TLS-thread implementations

    private func connectImpl(host: String, port: Int) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var res: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(host, String(port), &hints, &res)
        guard gai == 0, let first = res else { return false }
        defer { freeaddrinfo(res) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let addr = cursor {
            let candidate = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            if candidate >= 0 {
                _ = fcntl(candidate, F_SETFL, O_NONBLOCK)
                let rc = Darwin.connect(candidate, addr.pointee.ai_addr, addr.pointee.ai_addrlen)
                if rc == 0 {
                    fd = candidate
                    return true
                }
                if errno == EINPROGRESS {
                    var pfd = pollfd(fd: candidate, events: Int16(POLLOUT), revents: 0)
                    // Timeout generoso: el firewall del servidor real (z17.cu)
                    // puede tardar varios segundos en completar el SYN-ACK con
                    // conexiones simultáneas o tras ráfagas recientes.
                    if poll(&pfd, 1, 10000) > 0 {
                        var soError: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(candidate, SOL_SOCKET, SO_ERROR, &soError, &len)
                        if soError == 0 {
                            fd = candidate
                            return true
                        }
                    }
                }
                close(candidate)
            }
            cursor = addr.pointee.ai_next
        }
        return false
    }

    private func startTLSImpl(domain: String) -> Bool {
        guard fd >= 0, tlsChannel == nil else { return false }
        do {
            var config = TLSConfiguration.makeClientConfiguration()
            config.trustRoots = .certificates(try TrustAnchors.certificates())
            let context = try NIOSSLContext(configuration: config)
            let handler = try NIOSSLClientHandler(context: context, serverHostname: domain)
            let watcher = HandshakeWatcher()
            let channel = EmbeddedChannel(handlers: [handler, watcher])
            // connect() fires channelActive, which makes NIOSSLClientHandler
            // emit the ClientHello into the outbound buffer.
            try channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
            tlsChannel = channel

            guard try pumpOutbound(channel) else { return false }

            // Canonical non-blocking pattern: wait for the socket to become
            // readable, feed the ciphertext into the channel, flush whatever
            // the handshake produced outbound (cert verify, Finished), and
            // re-check the watcher.
            var attempts = 0
            while !watcher.completed && attempts < 60 {
                attempts += 1
                if let f = watcher.failure {
                    os_log("[TLS] watcher failure: %{public}s", log: connLog, type: .debug, f)
                    return false
                }
                guard waitReadable(timeoutMs: 5000) else {
                    os_log("[TLS] handshake poll timeout", log: connLog, type: .debug)
                    return false
                }
                let raw = readAllAvailable()
                guard !raw.isEmpty else {
                    os_log("[TLS] handshake read empty", log: connLog, type: .debug)
                    return false
                }
                var bb = channel.allocator.buffer(capacity: raw.count)
                bb.writeBytes(raw)
                try channel.writeInbound(IOData.byteBuffer(bb))
                guard try pumpOutbound(channel) else {
                    os_log("[TLS] handshake outbound flush failed", log: connLog, type: .debug)
                    return false
                }
                if let f = watcher.failure {
                    os_log("[TLS] watcher failure: %{public}s", log: connLog, type: .debug, f)
                    return false
                }
            }
            guard watcher.completed else {
                os_log("[TLS] handshake did not complete in %d attempts", log: connLog, type: .debug, attempts)
                return false
            }
            os_log("[TLS] HANDSHAKE COMPLETE after %d iterations", log: connLog, type: .info, attempts)
            tlsActive = true
            return true
        } catch {
            os_log("[TLS] startTLS error: %{public}s", log: connLog, type: .error, String(describing: error))
            // Release BoringSSL state; the raw fd stays open so the caller can
            // still read/write plaintext (XMPP-level abort) until teardown().
            if let channel = tlsChannel {
                tlsChannel = nil
                _ = try? channel.finish()
            }
            tlsActive = false
            return false
        }
    }

    private func readImpl(maxLength: Int) -> ReadResult {
        guard fd >= 0 else { return .closed }
        var buffer = [UInt8](repeating: 0, count: maxLength)
        if tlsActive, let channel = tlsChannel {
            // Poll the fd for ciphertext (timeout 0: non-blocking semantics),
            // feed it into the channel, then serve decrypted plaintext.
            guard waitReadable(timeoutMs: 0) else { return .wouldBlock }
            let raw = readAllAvailable()
            guard !raw.isEmpty else { return .wouldBlock }
            var bb = channel.allocator.buffer(capacity: raw.count)
            bb.writeBytes(raw)
            do {
                try channel.writeInbound(IOData.byteBuffer(bb))
            } catch {
                return .closed
            }
            _ = try? pumpOutbound(channel)
            var plain = Data()
            while let p = try? channel.readInbound(as: ByteBuffer.self) {
                plain.append(contentsOf: p.readableBytesView)
            }
            if plain.isEmpty { return .wouldBlock }
            let n = min(maxLength, plain.count)
            buffer.withUnsafeMutableBytes { $0.copyBytes(from: plain.prefix(n)) }
            return .data(Data(buffer[0..<n]))
        }
        let n = Darwin.read(fd, &buffer, maxLength)
        if n > 0 { return .data(Data(buffer[0..<n])) }
        if n == 0 { return .closed }
        let err = errno
        if err == EAGAIN || err == EWOULDBLOCK { return .wouldBlock }
        if err == EINTR { return .wouldBlock }
        return .closed
    }

    private func writeImpl(_ data: Data) -> Bool {
        guard fd >= 0 else { return false }
        if tlsActive, let channel = tlsChannel {
            var bb = channel.allocator.buffer(capacity: data.count)
            bb.writeBytes(data)
            do {
                try channel.writeOutbound(IOData.byteBuffer(bb))
                return try pumpOutbound(channel)
            } catch {
                return false
            }
        }
        return rawWrite(data)
    }

    /// Raw socket write (plaintext path and TLS ciphertext pump).
    private func rawWrite(_ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if n < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    if !waitWritable() { return false }
                    continue
                }
                return false
            }
            offset += n
        }
        return true
    }

    /// Flushes encrypted outbound from the channel to the fd.
    private func pumpOutbound(_ channel: EmbeddedChannel) throws -> Bool {
        while let enc = try channel.readOutbound(as: ByteBuffer.self) {
            let data = Data(enc.readableBytesView)
            os_log("[TLS] outbound %d bytes", log: connLog, type: .debug, data.count)
            guard rawWrite(data) else { return false }
        }
        return true
    }

    /// True once the fd is readable with no error bits set.
    private func waitReadable(timeoutMs: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pr = poll(&pfd, 1, timeoutMs)
        if pr <= 0 { return false }
        if pfd.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)) != 0 { return false }
        return true
    }

    /// Drains whatever the kernel receive buffer holds (up to 64 KB per pass).
    private func readAllAvailable() -> Data {
        var out = Data()
        for _ in 0..<4 {
            var buf = [UInt8](repeating: 0, count: 16384)
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]); continue }
            break
        }
        return out
    }

    private func waitWritable() -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        return poll(&pfd, 1, 5000) > 0
    }

    private func teardownImpl() {
        if let channel = tlsChannel {
            tlsChannel = nil
            _ = try? channel.finish()
        }
        tlsActive = false
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

final class XMPPConnection: Sendable {
    private actor State {
        var isConnected = false
        var receiveTask: Task<Void, Never>?

        func markConnected(_ v: Bool) { isConnected = v }
        func isConn() -> Bool { isConnected }
        func setReceiveTask(_ task: Task<Void, Never>?) { receiveTask = task }
        func getReceiveTask() -> Task<Void, Never>? { receiveTask }
    }

    private let state = State()
    private let transport = Transport()
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

        guard transport.connect(host: host, port: port) else {
            throw XMPPConnectionError.connectionFailed("Could not connect to \(host):\(port)")
        }
        if useTLS {
            os_log("[NW] DirectTLS handshake", log: connLog, type: .info)
            guard transport.startTLS(domain: host) else {
                throw XMPPConnectionError.tlsFailed("TLS handshake failed for \(host)")
            }
        }
        os_log("[NW] Connected", log: connLog, type: .info)
        await state.markConnected(true)
        await startReceiveLoop()
    }

    /// In-band STARTTLS (XEP-0115 negotiation already done): upgrades the
    /// existing connection to TLS after the server sent `<proceed/>`.
    /// The receive loop is paused for the handshake: the pump feeds and
    /// drains the same fd, and the loop would otherwise steal TLS bytes from
    /// the handshake via its own reads.
    func startTLS(domain: String) async throws {
        os_log("[NW] In-band STARTTLS upgrade", log: connLog, type: .info)
        await state.getReceiveTask()?.cancel()
        await state.setReceiveTask(nil)
        guard transport.startTLS(domain: domain) else {
            throw XMPPConnectionError.tlsFailed("In-band TLS handshake failed for \(domain)")
        }
        await startReceiveLoop()
    }

    private func startReceiveLoop() async {
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard await self.state.isConn() else { break }
                switch self.transport.read(maxLength: 65536) {
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        os_log("[NW] Recv(%d): %{public}s", log: connLog, type: .debug, data.count, String(text.prefix(500)))
                    } else {
                        os_log("[NW] Recv(%d): <no utf8>", log: connLog, type: .debug, data.count)
                    }
                    self.receiveContinuation.yield(data)
                case .wouldBlock:
                    try? await Task.sleep(nanoseconds: 50_000_000)
                case .closed:
                    os_log("[NW] Receive loop ended (server closed)", log: connLog, type: .info)
                    await self.state.markConnected(false)
                    return
                }
            }
            os_log("[NW] Receive loop ended", log: connLog, type: .info)
        }
        await state.setReceiveTask(task)
    }

    func send(data: Data) async throws {
        guard await state.isConn() else { throw XMPPConnectionError.disconnected }
        let ok = transport.write(data)
        guard ok else { throw XMPPConnectionError.connectionFailed("Write failed") }
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
        transport.teardown()
        await state.markConnected(false)
    }
}
