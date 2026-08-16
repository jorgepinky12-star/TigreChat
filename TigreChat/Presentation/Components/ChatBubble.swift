import SwiftUI
import UIKit

struct ChatBubble: View {
    let message: Message
    /// Acción opcional al retractar un mensaje propio (XEP-0424).
    var onRetract: (() -> Void)?
    /// Acción opcional al responder al mensaje (barra de reply del input).
    var onReply: ((Message) -> Void)?

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: Theme.Layout.spacing60) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: Theme.Layout.spacing4) {
                bubble
                    .contextMenu {
                        Button {
                            onReply?(message)
                        } label: {
                            Label("Responder", systemImage: "arrowshape.turn.up.left")
                        }
                        if message.isOutgoing {
                            Button(role: .destructive) {
                                onRetract?()
                            } label: {
                                Label("Eliminar para todos", systemImage: "trash")
                            }
                        }
                    }
            }

            if !message.isOutgoing { Spacer(minLength: Theme.Layout.spacing60) }
        }
    }

    /// La burbuja con el contenido y la fila de metadatos (cifrado, hora y
    /// estado) DENTRO del fondo: la hora entra en el color del globo para
    /// contrastar (blanca al 75% en saliente, `.secondary` en entrante).
    private var bubble: some View {
        let fill = message.isOutgoing ? Theme.Colors.outgoingBubble : Theme.Colors.incomingBubble
        let maxWidth = UIScreen.main.bounds.width * 0.7
        // Espejo WhatsApp: lo mío se alinea a la derecha y lo del otro a la
        // izquierda; así el texto y la fila de metadatos (hora/estado) quedan
        // pegados al borde correcto del globo.
        return VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: Theme.Layout.spacing4) {
            Group {
                if let attachment = message.attachment {
                    MessageAttachmentView(url: attachment.url, mimeType: attachment.mimeType)
                        .frame(maxWidth: maxWidth)
                } else {
                    Text(message.text)
                        .multilineTextAlignment(message.isOutgoing ? .trailing : .leading)
                        .frame(maxWidth: maxWidth, alignment: message.isOutgoing ? .trailing : .leading)
                }
            }
            .foregroundStyle(message.isOutgoing ? .white : Theme.Colors.incomingText)

            // Fila de metadatos: cifrado, hora y estado pegados al contenido
            // (sin Spacer para no estirar la burbuja).
            HStack(spacing: Theme.Layout.spacing4) {
                if message.isEncrypted {
                    EncryptionBadge()
                }
                Text(message.timestamp.chatBubbleTimestamp())
                    .font(Theme.Typography.caption2)
                if message.isOutgoing {
                    statusIcon
                }
            }
            .frame(maxWidth: maxWidth, alignment: message.isOutgoing ? .trailing : .leading)
            .foregroundStyle(message.isOutgoing ? .white.opacity(0.75) : .secondary)
        }
        .padding(.horizontal, Theme.Layout.spacing12)
        .padding(.vertical, Theme.Layout.spacing8)
        // Clave del ancho tipo WhatsApp: `fixedSize` horizontal anula la
        // propuesta de ancho del padre, el globo mide SOLO lo que mide su
        // contenido (texto corto = burbuja corta); el tope de 70% vive en el
        // `frame(maxWidth:)` del texto, que además envuelve los mensajes largos.
        .fixedSize(horizontal: true, vertical: false)
        // La cola forma parte del mismo trazo que la burbuja: un solo fill
        // para que la punta quede fundida con el globo.
        .background(ChatBubbleShape(isOutgoing: message.isOutgoing, radius: 18).fill(fill))
        .clipShape(ChatBubbleShape(isOutgoing: message.isOutgoing, radius: 18))
    }

    @ViewBuilder
    private var statusIcon: some View {
        // La burbuja saliente es ROJA: los estados de Theme (rojos sobre rojo)
        // eran invisibles. Aquí el único fondo posible es el globo saliente,
        // así que el estado usa blancos escalonados para que los ticks siempre
        // contrasten (estilo WhatsApp).
        switch message.status {
        case .sending:
            Image(systemName: "clock")
                .statusIcon()
                .foregroundStyle(.white.opacity(0.6))
        case .pending:
            Image(systemName: "clock.arrow.circlepath")
                .statusIcon()
                .foregroundStyle(.white.opacity(0.6))
        case .sent:
            Image(systemName: "checkmark")
                .statusIcon()
                .foregroundStyle(.white.opacity(0.7))
        case .delivered:
            Image(systemName: "checkmark.circle")
                .statusIcon()
                .foregroundStyle(.white.opacity(0.85))
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .statusIcon()
                .foregroundStyle(.white)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .statusIcon()
                .foregroundStyle(.white)
        }
    }
}

/// Silueta de la burbuja: rectángulo redondeado + cola dibujada como un solo
/// trazo continuo, para que la punta quede fundida con el globo.
struct ChatBubbleShape: Shape {
    let isOutgoing: Bool
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let r = radius
        // Dimensiones de la cola.
        let tailBaseHalf: CGFloat = 7   // mitad de la base de la cola
        let tailProtrusion: CGFloat = 4 // salida de la punta fuera del borde lateral
        let tailDrop: CGFloat = 7       // caída de la punta bajo el borde inferior
        let tailCorner: CGFloat = 2     // radio de la esquina de la cola

        var path = Path()
        if isOutgoing {
            // Cola abajo a la derecha, punta hacia abajo-derecha.
            path.move(to: CGPoint(x: r, y: 0))
            path.addLine(to: CGPoint(x: w - r, y: 0))
            path.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: w, y: h - tailCorner))
            path.addQuadCurve(to: CGPoint(x: w - tailCorner, y: h), control: CGPoint(x: w, y: h)) // esquina de la cola casi plana
            path.addLine(to: CGPoint(x: w - tailBaseHalf * 2, y: h)) // base de la cola
            path.addLine(to: CGPoint(x: w + tailProtrusion, y: h + tailDrop)) // punta de la cola
            path.addLine(to: CGPoint(x: w - tailCorner, y: h)) // vuelve a la base
            path.addLine(to: CGPoint(x: r, y: h))
            path.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: 0, y: r))
            path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
            path.closeSubpath()
        } else {
            // Cola abajo a la izquierda, punta hacia abajo-izquierda.
            path.move(to: CGPoint(x: r, y: 0))
            path.addLine(to: CGPoint(x: w - r, y: 0))
            path.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: w, y: h - r))
            path.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: tailBaseHalf * 2, y: h)) // base de la cola
            path.addLine(to: CGPoint(x: -tailProtrusion, y: h + tailDrop)) // punta de la cola
            path.addLine(to: CGPoint(x: tailCorner, y: h)) // vuelve a la base
            path.addQuadCurve(to: CGPoint(x: 0, y: h - tailCorner), control: CGPoint(x: 0, y: h)) // esquina de la cola casi plana
            path.addLine(to: CGPoint(x: 0, y: r))
            path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
            path.closeSubpath()
        }
        return path
    }
}