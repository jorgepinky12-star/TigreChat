import SwiftUI
import AVFoundation

struct CallView: View {
    @State private var viewModel: CallViewModel
    let contactName: String
    let isIncoming: Bool
    let onDismiss: () -> Void

    init(contactName: String, isIncoming: Bool, callRepository: CallRepository, onDismiss: @escaping () -> Void) {
        self.contactName = contactName
        self.isIncoming = isIncoming
        self.onDismiss = onDismiss
        _viewModel = State(initialValue: CallViewModel(callRepository: callRepository))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                AvatarView(name: contactName, size: 80)
                    .overlay(
                        Circle()
                            .stroke(viewModel.call?.state == .connected ? Color.green : Color.white, lineWidth: 3)
                    )

                Text(contactName)
                    .font(.title.bold())
                    .foregroundStyle(.white)

                statusText
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                if viewModel.call?.state == .connected || viewModel.call?.state == .connecting {
                    activeCallControls
                } else if isIncoming {
                    incomingCallControls
                } else {
                    outgoingCallControls
                }
            }
            .padding(.bottom, 50)
        }
        .onChange(of: viewModel.call?.state) { _, state in
            if state == .ended || state == .failed || state == .missed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { onDismiss() }
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch viewModel.call?.state {
        case .dialing: Text("Dialing...")
        case .ringing: Text("Ringing...")
        case .connecting: Text("Connecting...")
        case .connected: Text(viewModel.formattedDuration)
        case .reconnecting: Text("Reconnecting...")
        case .ended: Text("Call ended")
        case .failed: Text("Call failed")
        case .missed: Text("Missed call")
        case nil: Text("")
        }
    }

    private var activeCallControls: some View {
        HStack(spacing: 40) {
            CallControlButton(icon: isMuted ? "mic.slash.fill" : "mic.fill", color: isMuted ? .red : .white) {
                viewModel.toggleMute()
            }
            CallControlButton(icon: "phone.down.fill", color: .red) {
                Task { await viewModel.endCall() }
            }
            CallControlButton(icon: isSpeakerOn ? "speaker.wave.2.fill" : "speaker.fill", color: .white) {
                viewModel.toggleSpeaker()
            }
        }
    }

    private var incomingCallControls: some View {
        HStack(spacing: 60) {
            CallControlButton(icon: "phone.down.fill", color: .red) {
                Task { await viewModel.rejectCall() }
            }
            CallControlButton(icon: "phone.fill", color: .green) {
                guard let call = viewModel.call else { return }
                Task { await viewModel.acceptCall(call) }
            }
        }
    }

    private var outgoingCallControls: some View {
        CallControlButton(icon: "phone.down.fill", color: .red) {
            Task { await viewModel.endCall() }
        }
    }

    private var isMuted: Bool { viewModel.isMuted }
    private var isSpeakerOn: Bool { viewModel.isSpeakerOn }
}

struct CallControlButton: View {
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.2))
                    .frame(width: Theme.Layout.spacing60, height: Theme.Layout.spacing60)
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
            }
        }
    }
}

// MARK: - Video Call View

struct VideoCallView: View {
    let contactName: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                HStack {
                    Text(contactName)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Spacer()
                    Button("End", role: .destructive) { onDismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                .padding()

                Spacer()

                HStack(spacing: 40) {
                    Image(systemName: "mic.fill").foregroundStyle(.white)
                    Image(systemName: "video.fill").foregroundStyle(.white)
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.white)
                }
                .padding(.bottom, 40)
            }
        }
    }
}
