//
//  CallKitAdapting.swift
//  TigreChat
//
//  Seam D7 del diseño (M2): abstracción de CallKit para poder orquestar,
//  grabar y probar llamadas VoIP sin depender del sistema telefónico.
//  El CallManager real (CXProvider/CXCallController) conforma este protocolo;
//  los tests usan un doble grabador con el mismo contrato.
//

import Foundation

/// Contrato mínimo que el repositorio de llamadas necesita de CallKit:
/// timbre entrante, arranque saliente, conexión/desconexión y notificaciones
/// de fin (local o remoto). Todo el sistema de UI queda detrás de este seam.
@MainActor
protocol CallKitAdapting: AnyObject, Sendable {
    var onAnswer: ((UUID) -> Void)? { get set }
    var onEnd: ((UUID) -> Void)? { get set }
    var onMute: ((UUID, Bool) -> Void)? { get set }
    var onStartCall: ((UUID, String) -> Void)? { get set }

    /// Reporta una llamada entrante al sistema (timbre/CallKit). Lanza si el
    /// sistema rechaza la llamada (p. ej. el usuario ya está en otra llamada).
    func reportIncomingCall(uuid: UUID, jid: String, hasVideo: Bool) async throws

    /// Arranca una llamada saliente a través del sistema.
    func startCall(uuid: UUID, jid: String, isVideo: Bool)

    /// Finaliza la llamada `uuid` (local o remota).
    func endCall(uuid: UUID)

    /// El otro extremo terminó la llamada: el sistema la cierra sin acción del usuario.
    func reportRemoteEnded(uuid: UUID)

    /// La llamada saliente empezó a conectarse (wire establecido, media negociándose).
    func reportOutgoingCallConnecting(uuid: UUID)

    /// La llamada saliente quedó conectada (media activa).
    func reportOutgoingCallConnected(uuid: UUID)
}