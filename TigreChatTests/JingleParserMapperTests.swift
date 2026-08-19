//
//  JingleParserMapperTests.swift
//  TigreChatTests
//
//  T-010 RED: parser XML real de Jingle con fixtures XEP-0166/0167/0320,
//  y mapper SDP ⇄ JingleContent (T-012 RED se deriva de acá).
//

import XCTest
@testable import TigreChat

private let sessionInitiateAudio = """
<iq to='juliet@capulet.com/balcony' id='jingle1' type='set'>
  <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' initiator='romeo@montague.net/orchard' sid='a73sjjvkla37jfea'>
    <content creator='initiator' name='audio'>
      <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>
        <payload-type id='96' name='opus' clockrate='48000'/>
        <payload-type id='0' name='PCMU' clockrate='8000'/>
      </description>
      <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1'>
        <candidate component='1' foundation='1' generation='0' id='el0747fg11' ip='10.0.1.1' network='1' port='8998' priority='2130706431' protocol='udp' type='host'/>
        <candidate component='1' foundation='2' generation='0' id='y3j2z3b2' ip='192.0.2.3' network='1' port='45664' priority='1694498815' protocol='udp' type='srflx'/>
      </transport>
      <security xmlns='urn:xmpp:jingle:apps:dtls:0'>
        <fingerprint hash='sha-256'>A58B0C0B39E79FB5045A2BBCD6430EEF88E809DB7590A36363EFA59FA9067C44</fingerprint>
        <setup>actpass</setup>
      </security>
    </content>
  </jingle>
</iq>
"""

private let transportInfo = """
<iq to='romeo@montague.net/orchard' id='jingle2' type='set'>
  <jingle xmlns='urn:xmpp:jingle:1' action='transport-info' initiator='romeo@montague.net/orchard' sid='a73sjjvkla37jfea'>
    <content creator='initiator' name='audio'>
      <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1'>
        <candidate component='1' foundation='3' generation='0' id='x8v7w6u5' ip='192.0.2.3' network='1' port='45664' priority='1694498815' protocol='udp' type='srflx'/>
      </transport>
    </content>
  </jingle>
</iq>
"""

private let terminateSuccess = """
<iq to='romeo@montague.net/orchard' id='jingle3' type='set'>
  <jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' initiator='romeo@montague.net/orchard' sid='a73sjjvkla37jfea'>
    <reason><success/></reason>
  </jingle>
</iq>
"""

private let terminateTimeout = """
<iq to='romeo@montague.net/orchard' id='jingle4' type='set'>
  <jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' initiator='romeo@montague.net/orchard' sid='a73sjjvkla37jfea'>
    <reason><timeout/></reason>
  </jingle>
</iq>
"""

private let terminateBusy = """
<iq to='romeo@montague.net/orchard' id='jingle5' type='set'>
  <jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' initiator='romeo@montague.net/orchard' sid='a73sjjvkla37jfea'>
    <reason><busy/></reason>
  </jingle>
</iq>
"""

private let unknownAction = """
<iq to='juliet@capulet.com/balcony' id='jingle6' type='set'>
  <jingle xmlns='urn:xmpp:jingle:1' action='dance' sid='a73sjjvkla37jfea'/>
</iq>
"""

private let missingAction = """
<iq to='juliet@capulet.com/balcony' id='jingle7' type='set'>
  <jingle xmlns='urn:xmpp:jingle:1' sid='a73sjjvkla37jfea'/>
</iq>
"""

private let noJingle = """
<iq to='juliet@capulet.com/balcony' id='jingle8' type='set'>
  <message type='chat'/>
</iq>
"""

private let multiLineFingerprint = """
<iq to='juliet@capulet.com/balcony' id='jingle9' type='set'>
  <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' initiator='romeo@montague.net/orchard' sid='fp1'>
    <content creator='initiator' name='audio'>
      <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>
        <payload-type id='96' name='opus' clockrate='48000'/>
      </description>
      <security xmlns='urn:xmpp:jingle:apps:dtls:0'>
        <fingerprint hash='sha-256'>
          A5:8B:0C:0B
          39:E7:9F:B5
          04:5A:2B:BC
          D6:43:0E:EF
          88:E8:09:DB
          75:90:A3:63
          63:EF:A5:9F
          A9:06:7C:44
        </fingerprint>
        <setup>active</setup>
      </security>
    </content>
  </jingle>
</iq>
"""

final class JingleParserMapperTests: XCTestCase {

    private let parser = JingleXMLParser()
    private let mapper = JingleSDPMapper()

    // MARK: - Parser: session-initiate

    func testParseSessionInitiateAudio() throws {
        let stanza = try parser.parse(sessionInitiateAudio)
        XCTAssertEqual(stanza.action, .sessionInitiate)
        XCTAssertEqual(stanza.sid, "a73sjjvkla37jfea")
        XCTAssertEqual(stanza.initiator, "romeo@montague.net/orchard")
        XCTAssertNil(stanza.responder)
        XCTAssertEqual(stanza.contents.count, 1)

        let content = try XCTUnwrap(stanza.contents.first)
        XCTAssertEqual(content.creator, "initiator")
        XCTAssertEqual(content.name, "audio")
        XCTAssertEqual(content.media, "audio")
        XCTAssertEqual(content.payloadTypes, [
            PayloadType(id: 96, name: "opus", clockrate: 48000, channels: nil),
            PayloadType(id: 0, name: "PCMU", clockrate: 8000, channels: nil),
        ])
        let fingerprint = try XCTUnwrap(content.fingerprint)
        XCTAssertEqual(fingerprint.hash, "sha-256")
        XCTAssertEqual(fingerprint.value, "A58B0C0B39E79FB5045A2BBCD6430EEF88E809DB7590A36363EFA59FA9067C44")
        XCTAssertEqual(fingerprint.setup, "actpass")
        XCTAssertEqual(content.candidates.count, 2)
        XCTAssertEqual(content.candidates[0].ip, "10.0.1.1")
        XCTAssertEqual(content.candidates[0].port, 8998)
        XCTAssertEqual(content.candidates[0].type, "host")
        XCTAssertEqual(content.candidates[1].ip, "192.0.2.3")
        XCTAssertEqual(content.candidates[1].port, 45664)
        XCTAssertEqual(content.candidates[1].type, "srflx")
    }

    // MARK: - Parser: transport-info

    func testParseTransportInfo() throws {
        let stanza = try parser.parse(transportInfo)
        XCTAssertEqual(stanza.action, .transportInfo)
        XCTAssertEqual(stanza.sid, "a73sjjvkla37jfea")
        let content = try XCTUnwrap(stanza.contents.first)
        let candidate = try XCTUnwrap(content.candidates.first)
        XCTAssertEqual(candidate.component, 1)
        XCTAssertEqual(candidate.foundation, "3")
        XCTAssertEqual(candidate.ip, "192.0.2.3")
        XCTAssertEqual(candidate.port, 45664)
        XCTAssertEqual(candidate.protocol, "udp")
        XCTAssertEqual(candidate.type, "srflx")
    }

    // MARK: - Parser: session-terminate

    func testParseTerminateReasons() throws {
        XCTAssertEqual(try parser.parse(terminateSuccess).terminateReason, "success")
        XCTAssertEqual(try parser.parse(terminateTimeout).terminateReason, "timeout")
        XCTAssertEqual(try parser.parse(terminateBusy).terminateReason, "busy")
    }

    // MARK: - Parser: errores

    func testParseUnknownActionThrows() {
        XCTAssertThrowsError(try parser.parse(unknownAction)) { error in
            guard case JingleParseError.unknownAction("dance") = error else {
                return XCTFail("esperaba unknownAction, obtuve \(error)")
            }
        }
    }

    func testParseMissingActionThrows() {
        XCTAssertThrowsError(try parser.parse(missingAction))
    }

    func testParseWithoutJingleThrows() {
        XCTAssertThrowsError(try parser.parse(noJingle))
    }

    func testParseMalformedStringThrows() {
        XCTAssertThrowsError(try parser.parse("esto no es xml"))
    }

    // MARK: - Parser: fingerprint multilínea normalizado

    func testParseNormalizesMultilineFingerprint() throws {
        let stanza = try parser.parse(multiLineFingerprint)
        let content = try XCTUnwrap(stanza.contents.first)
        let fingerprint = try XCTUnwrap(content.fingerprint)
        XCTAssertEqual(fingerprint.value, "A58B0C0B39E79FB5045A2BBCD6430EEF88E809DB7590A36363EFA59FA9067C44")
        XCTAssertEqual(fingerprint.setup, "active")
    }

    // MARK: - Mapper: JingleContent → SDP

    func testMapContentToOfferSDP() throws {
        let stanza = try parser.parse(sessionInitiateAudio)
        let content = try XCTUnwrap(stanza.contents.first)
        let sdp = try mapper.sdp(from: content, type: .offer)
        XCTAssertEqual(sdp.type, .offer)
        XCTAssertTrue(sdp.sdp.contains("m=audio"))
        XCTAssertTrue(sdp.sdp.contains("a=rtpmap:96 opus/48000"))
        XCTAssertTrue(sdp.sdp.contains("a=rtpmap:0 PCMU/8000"))
        XCTAssertTrue(sdp.sdp.contains("a=fingerprint:sha-256 A58B0C0B39E79FB5045A2BBCD6430EEF88E809DB7590A36363EFA59FA9067C44"))
        XCTAssertTrue(sdp.sdp.contains("a=setup:actpass"))
        XCTAssertTrue(sdp.sdp.contains("v=0"))
    }

    func testMapContentWithoutDescriptionThrows() {
        let content = JingleContent(creator: "initiator", name: "audio", media: nil, payloadTypes: [], fingerprint: nil, candidates: [])
        XCTAssertThrowsError(try mapper.sdp(from: content, type: .offer)) { error in
            guard case JingleSDPMapper.MappingError.missingDescription = error else {
                return XCTFail("esperaba missingDescription, obtuve \(error)")
            }
        }
    }

    // MARK: - Mapper: SDP → JingleContent

    func testMapOfferSDPToContent() throws {
        let sdp = SessionDescription(
            sdp: """
            v=0
            o=- 2890844526 2890844526 IN IP4 192.0.2.1
            s=-
            t=0 0
            c=IN IP4 192.0.2.1
            m=audio 49170 RTP/AVP 96 0
            a=rtpmap:96 opus/48000/2
            a=rtpmap:0 PCMU/8000
            a=fingerprint:sha-256 A58B0C0B39E79FB5045A2BBCD6430EEF88E809DB7590A36363EFA59FA9067C44
            a=setup:actpass
            """,
            type: .offer
        )
        let content = try mapper.content(from: sdp, creator: "initiator", name: "audio")
        XCTAssertEqual(content.creator, "initiator")
        XCTAssertEqual(content.name, "audio")
        XCTAssertEqual(content.media, "audio")
        XCTAssertEqual(content.payloadTypes, [
            PayloadType(id: 96, name: "opus", clockrate: 48000, channels: 2),
            PayloadType(id: 0, name: "PCMU", clockrate: 8000, channels: nil),
        ])
        let fingerprint = try XCTUnwrap(content.fingerprint)
        XCTAssertEqual(fingerprint.hash, "sha-256")
        XCTAssertEqual(fingerprint.setup, "actpass")
    }
}