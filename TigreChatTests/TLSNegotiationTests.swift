//
//  TLSNegotiationTests.swift
//  TigreChatTests
//
//  Integration harness: reproduces the real XMPP STARTTLS upgrade against
//  ims-brz.z17.cu:5222 using SecureTransport custom-IO callbacks, the exact
//  same path the app uses. Runs on the iOS simulator, whose SecureTransport
//  matches the device.
//
//  Strategy under test controls how the read callback serves a TLS record:
//    exact  -> give ST exactly what it asked (len.pointee) — current app behavior
//    header -> when a full record is buffered but ST asked for part of it,
//              give only the 5-byte header so ST re-asks with the full length
//    full   -> when the full record is buffered, give the ENTIRE record even
//              if ST asked for less
//

import XCTest
import Security
import Darwin

// Shared callback state (mirrors the app's tlsReadBuffers pattern).
nonisolated(unsafe) private var cbStrategy = "exact"
nonisolated(unsafe) private var cbBuffer = Data()
nonisolated(unsafe) private var cbLock = NSLock()

private func cbRead(_ conn: SSLConnectionRef, _ data: UnsafeMutableRawPointer, _ len: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Int32(truncatingIfNeeded: Int(bitPattern: conn))
    cbLock.lock()
    defer { cbLock.unlock() }

    var pending = cbBuffer
    while pending.count < len.pointee {
        var chunk = [UInt8](repeating: 0, count: 16384)
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n > 0 {
            print("[cb] want=\(len.pointee) got=\(n) errno=\(errno) buffered=\(pending.count)")
            pending.append(contentsOf: chunk[0..<n])
            continue
        }
        if n == 0 { return errSSLClosedGraceful }
        let err = errno
        if err == EINTR { continue }
        if err == EAGAIN || err == EWOULDBLOCK { break }
        return errSSLClosedAbort
    }
    guard !pending.isEmpty else { return errSSLWouldBlock }

    var give = min(pending.count, len.pointee)

    var fullRecord = 0
    if pending.count >= 5 {
        fullRecord = 5 + ((Int(pending[3]) << 8) | Int(pending[4]))
    }

    switch cbStrategy {
    case "header":
        if pending.count >= fullRecord, fullRecord > 0, len.pointee < fullRecord {
            give = 5
            print("[cb] HEADER-ONLY: gave 5 of \(fullRecord) (asked \(len.pointee))")
        }
    case "full":
        if pending.count >= fullRecord, fullRecord > 0, len.pointee < fullRecord {
            give = fullRecord
            print("[cb] FULL-RECORD: gave \(fullRecord) (asked \(len.pointee))")
        }
    default:
        break
    }

    pending.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        if let base = bytes.baseAddress {
            data.copyMemory(from: base, byteCount: give)
        }
    }
    let hex = pending.prefix(give).prefix(96).map { String(format: "%02x", $0) }.joined()
    print("[cb] hex: \(hex)")
    len.pointee = give
    cbBuffer = Data(pending.dropFirst(give))
    return noErr
}

private func cbWrite(_ conn: SSLConnectionRef, _ data: UnsafeRawPointer, _ len: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Int32(truncatingIfNeeded: Int(bitPattern: conn))
    let n = Darwin.write(fd, data, len.pointee)
    print("[cb] write want=\(len.pointee) wrote=\(n)")
    len.pointee = n > 0 ? n : 0
    return n >= 0 ? noErr : (errno == EAGAIN ? errSSLWouldBlock : errSSLClosedAbort)
}

final class TLSNegotiationTests: XCTestCase {

    private var fd: Int32 = -1
    private var ctx: SSLContext?

    override func tearDown() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        ctx = nil
        cbBuffer = Data()
        super.tearDown()
    }

    /// Opens TCP to the server and completes the XMPP STARTTLS negotiation
    /// (<stream> -> <features> -> <starttls/> -> <proceed/>).
    private func connectAndStartTLS(strategy: String) throws {
        cbStrategy = strategy
        cbBuffer = Data()

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>? = nil
        let gai = getaddrinfo("ims-brz.z17.cu", "5222", &hints, &res)
        guard gai == 0, let addr = res else {
            throw XCTSkip("DNS resolution failed: \(String(cString: gai_strerror(gai)))")
        }
        defer { freeaddrinfo(res) }

        let c = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
        guard c >= 0 else { throw XCTSkip("socket() failed: \(String(cString: strerror(errno)))") }
        _ = fcntl(c, F_SETFL, O_NONBLOCK)
        let rc = connect(c, addr.pointee.ai_addr, addr.pointee.ai_addrlen)
        if rc != 0 {
            guard errno == EINPROGRESS else {
                close(c)
                throw XCTSkip("connect failed: \(String(cString: strerror(errno)))")
            }
            var pfd = pollfd(fd: c, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, 5000) > 0 else { close(c); throw XCTSkip("connect timeout") }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(c, SOL_SOCKET, SO_ERROR, &soError, &len)
            guard soError == 0 else { close(c); throw XCTSkip("connect SO_ERROR \(soError)") }
        }
        fd = c
        print("[tls-test] TCP connected fd=\(fd) strategy=\(strategy)")

        func send(_ s: String) {
            let d = Data(s.utf8)
            d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                var sent = 0
                while sent < d.count {
                    let n = Darwin.write(fd, b.baseAddress! + sent, d.count - sent)
                    if n > 0 { sent += n } else if n < 0 && errno == EAGAIN { usleep(10000) } else { break }
                }
            }
        }

        func recvUntil(_ needle: String) -> Data {
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 8192)
            while buf.count < 200000 {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, 5000) <= 0 { break }
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n > 0 {
                    buf.append(contentsOf: chunk[0..<n])
                    if let s = String(data: buf, encoding: .utf8), s.contains(needle) { break }
                } else { break }
            }
            return buf
        }

        send("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' to='ims-brz.z17.cu' version='1.0'>")
        let features = recvUntil("<starttls")
        print("[tls-test] features: \(String(data: features, encoding: .utf8)?.prefix(120) ?? "?")")
        send("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
        let proceed = recvUntil("<proceed")
        print("[tls-test] proceed: \(String(data: proceed, encoding: .utf8)?.prefix(120) ?? "?")")
        guard let s = String(data: proceed, encoding: .utf8), s.contains("<proceed") else {
            throw XCTSkip("Server did not send <proceed/>")
        }

        guard let ssl = SSLCreateContext(nil, SSLProtocolSide.clientSide, SSLConnectionType.streamType) else {
            throw XCTSkip("SSLCreateContext failed")
        }
        ctx = ssl
        SSLSetIOFuncs(ssl, cbRead, cbWrite)
        SSLSetConnection(ssl, UnsafeRawPointer(bitPattern: Int(fd)))
        SSLSetPeerDomainName(ssl, "ims-brz.z17.cu", 14)
        SSLSetProtocolVersionMin(ssl, SSLProtocol.tlsProtocol12)
        SSLSetProtocolVersionMax(ssl, SSLProtocol.tlsProtocol12)
    }

    /// Runs SSLHandshake with poll-driven re-entry, mirroring Transport.startTLS.
    private func runHandshake() -> OSStatus {
        guard let ssl = ctx else { return -1 }
        var status = SSLHandshake(ssl)
        print("[tls-test] first handshake: \(status)")
        var attempts = 0
        while status == errSSLWouldBlock {
            attempts += 1
            if attempts > 60 { return status }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 5000) <= 0 { return status }
            if pfd.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)) != 0 { return status }
            status = SSLHandshake(ssl)
            print("[tls-test] re-entry \(attempts): \(status)")
        }
        print("[tls-test] FINAL: \(status)")
        return status
    }

    // MARK: Strategies

    func testStrategyExact() throws {
        try connectAndStartTLS(strategy: "exact")
        let status = runHandshake()
        print("[tls-test] strategy=exact result=\(status)")
        // Documenting current failure: ST asks for a partial record chunk and
        // fails with errSSLProtocol instead of asking for the rest.
        XCTAssertNotEqual(status, noErr, "exact strategy unexpectedly succeeded")
    }

    func testStrategyHeader() throws {
        try connectAndStartTLS(strategy: "header")
        let status = runHandshake()
        print("[tls-test] strategy=header result=\(status)")
        XCTAssertEqual(status, noErr, "header strategy should complete the handshake")
    }

    func testStrategyFull() throws {
        try connectAndStartTLS(strategy: "full")
        let status = runHandshake()
        print("[tls-test] strategy=full result=\(status)")
        XCTAssertEqual(status, noErr, "full strategy should complete the handshake")
    }
}
