import Foundation

/// Árbol XML mínimo para parsear payloads OMEMO (XEP-0384): bundles PEP,
/// device lists y mensajes `<encrypted>`. El resto del cliente usa helpers de
/// rangos de string; OMEMO necesita anidamiento real (`<key>` con `<iv>`
/// hijo), así que aquí se usa `XMLParser` de Foundation.
struct OMEMOXMLElement: Sendable {
    let name: String
    let attributes: [String: String]
    /// Texto directo del elemento (sin el texto de sus hijos).
    var text: String
    var children: [OMEMOXMLElement]

    func attribute(_ key: String) -> String? {
        attributes[key]
    }

    func firstChild(named name: String) -> OMEMOXMLElement? {
        children.first { $0.name == name }
    }

    /// Busca el primer descendiente con el nombre dado (BFS).
    func firstDescendant(named name: String) -> OMEMOXMLElement? {
        if self.name == name { return self }
        for child in children {
            if let found = child.firstDescendant(named: name) {
                return found
            }
        }
        return nil
    }

    /// Parsea el primer elemento raíz del XML. Devuelve nil si no hay raíz.
    static func parse(_ xml: String) -> OMEMOXMLElement? {
        let parser = OMEMOXMLParserDelegate()
        let xmlParser = XMLParser(data: Data(xml.utf8))
        xmlParser.delegate = parser
        guard xmlParser.parse(), let root = parser.root else { return nil }
        return root
    }
}

/// Delegate de `XMLParser` que construye el árbol. No es Sendable: solo vive
/// durante `parse`.
private final class OMEMOXMLParserDelegate: NSObject, XMLParserDelegate {
    private var stack: [OMEMOXMLElement] = []
    var root: OMEMOXMLElement?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = OMEMOXMLElement(name: elementName, attributes: attributeDict, text: "", children: [])
        stack.append(element)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !stack.isEmpty {
            stack[stack.count - 1].text += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let finished = stack.popLast() else { return }
        if let parent = stack.popLast() {
            var updated = parent
            updated.children.append(finished)
            stack.append(updated)
        } else {
            root = finished
        }
    }
}
