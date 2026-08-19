import XCTest
@testable import TigreChat

/// Valida el eslabón parser → stanzas: el dividido de `XMPPStanzaParser` debe
/// entregar cada mensaje completo, en orden de llegada y sin pérdidas, tanto
/// con varios stanzas en un mismo chunk como con un mensaje partido en dos
/// chunks (borde de buffer) — el camino live de un mensaje entrante.
final class StanzaPipelineTests: XCTestCase {

    /// Caja thread-safe para recolectar stanzas desde el callback del parser.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var _stanzas: [MessageStanza] = []
        private var _raws: [String] = []
        func addMessage(_ stanza: MessageStanza) {
            lock.lock()
            _stanzas.append(stanza)
            lock.unlock()
        }
        func addRaw(_ rawXML: String) {
            lock.lock()
            _raws.append(rawXML)
            lock.unlock()
        }
        var stanzas: [MessageStanza] {
            lock.lock()
            defer { lock.unlock() }
            return _stanzas
        }
        var raws: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _raws
        }
    }

    private func makeParser(_ collector: Collector) async -> XMPPStanzaParser {
        let parser = XMPPStanzaParser()
        await parser.setStanzaCallback { stanza in
            // El raw XML de TODA stanza (message, iq, presence) importa para la
            // ruta jingle; los mensajes además alimentan las aserciones de texto.
            collector.addRaw(stanza.xml)
            if case .message(let msg) = stanza {
                collector.addMessage(msg)
            }
        }
        return parser
    }

    /// Dos mensajes en el mismo chunk: deben llegar completos y en orden.
    func testTwoMessagesInOneChunkArriveInOrder() async throws {
        let collector = Collector()
        let parser = await makeParser(collector)

        let chunk = """
        <message id='m-a' to='jorge@x' from='jorge2@x/r1' type='chat'><body>Primero</body></message>\
        <presence from='jorge2@x/r1' type='available'/>\
        <message id='m-b' to='jorge@x' from='jorge2@x/r1' type='chat'><body>Segundo</body></message>
        """
        await parser.appendData(chunk.data(using: .utf8)!)

        let stanzas = collector.stanzas
        XCTAssertEqual(stanzas.count, 2, "Ambos mensajes deben entregarse")
        XCTAssertEqual(stanzas[0].id, "m-a")
        XCTAssertEqual(stanzas[0].body, "Primero")
        XCTAssertEqual(stanzas[1].id, "m-b")
        XCTAssertEqual(stanzas[1].body, "Segundo")
    }

    /// Un mensaje partido en dos chunks (borde de buffer): debe reconstruirse.
    func testMessageSplitAcrossChunksIsReassembled() async throws {
        let collector = Collector()
        let parser = await makeParser(collector)

        let first = "<message id='m-split' to='jorge@x' from='jorge2@x/r1' type='chat'><body>Part"
        let second = "e</body></message>"
        await parser.appendData(first.data(using: .utf8)!)
        // Aún sin el cierre, no debe entregarse nada incompleto.
        XCTAssertEqual(collector.stanzas.count, 0)
        await parser.appendData(second.data(using: .utf8)!)

        let stanzas = collector.stanzas
        XCTAssertEqual(stanzas.count, 1)
        XCTAssertEqual(stanzas[0].id, "m-split")
        XCTAssertEqual(stanzas[0].body, "Parte")
    }

    /// Un mensaje con delay (catch-up MAM) entrega el timestamp del archivo.
    func testMessageWithDelayCarriesArchiveTimestamp() async throws {
        let collector = Collector()
        let parser = await makeParser(collector)

        let xml = """
        <message id='m-delay' to='jorge@x' from='jorge2@x' type='chat'><body>Viejo</body>\
        <delay xmlns='urn:xmpp:delay' from='jorge2@x' stamp='2026-08-15T10:00:00Z'/></message>
        """
        await parser.appendData(xml.data(using: .utf8)!)

        let stanzas = collector.stanzas
        XCTAssertEqual(stanzas.count, 1)
        XCTAssertEqual(stanzas[0].id, "m-delay")
        XCTAssertEqual(stanzas[0].timestamp?.timeIntervalSince1970 ?? 0, 1_786_788_000, accuracy: 2.0)
    }

    /// Ruta jingle: un IQ session-initiate partido en dos chunks se reconstruye
    /// completo — es la entrada de `handleUnsolicitedIQ`, que despacha por
    /// `rawXML.contains("urn:xmpp:jingle:1")`. El borde de buffer no debe
    /// romper la condición de ruta ni mutilar el XML.
    func testJingleIQSplitAcrossChunksIsReassembled() async throws {
        let collector = Collector()
        let parser = await makeParser(collector)

        let first = "<iq to='juliet@capulet.com/balcony' id='jingle-f' type='set'><jingle xmlns='urn:xmpp:jingle:1' action='session-ini"
        let second = "tiate' sid='jingle-f'/></iq>"
        await parser.appendData(first.data(using: .utf8)!)
        XCTAssertEqual(collector.raws.count, 0, "IQ incompleto no debe entregarse")
        await parser.appendData(second.data(using: .utf8)!)

        let raw = try XCTUnwrap(collector.raws.first)
        XCTAssertTrue(raw.contains("urn:xmpp:jingle:1"), "la routing condition debe sobrevivir al split")
        XCTAssertTrue(raw.contains("action='session-initiate'"))
        XCTAssertTrue(raw.contains("id='jingle-f'"))
    }
}