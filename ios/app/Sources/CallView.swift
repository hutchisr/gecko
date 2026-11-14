import SwiftUI
import UIKit

/// The in-app call surface: a floating glass card over the app while a call
/// exists. It never takes over the screen, so the chat underneath stays usable.
struct CallView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

#if targetEnvironment(macCatalyst)
    private let alignment: Alignment = .topTrailing
    private let insets = EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16)
#else
    private let alignment: Alignment = .top
    /// The top inset clears the navigation bar, which sits inside the root
    /// view's safe area.
    private let insets = EdgeInsets(top: 56, leading: 12, bottom: 0, trailing: 12)
#endif
    private let buttonSize: CGFloat = 44

    var body: some View {
        ZStack(alignment: alignment) {
            if let call = model.activeCall {
                card(call)
                    .padding(insets)
                    .transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .animation(
            accessibilityReduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.3),
            value: model.activeCall?.id)
        .alert("Call failed", isPresented: Binding(
            get: { model.callError != nil },
            set: { if !$0 { model.callError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.callError ?? "")
        }
    }

    private var transition: AnyTransition {
        accessibilityReduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    private func card(_ call: CallInfo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(call.name.isEmpty ? call.jid : call.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                status(call)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            controls(call)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: 400)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("call.card")
    }

    @ViewBuilder
    private func status(_ call: CallInfo) -> some View {
        if call.state == "in_progress", let start = call.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(Duration.seconds(max(0, Int(context.date.timeIntervalSince(start))))
                    .formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2))))
                    .monospacedDigit()
            }
        } else {
            Text(statusText(call))
        }
    }

    private func statusText(_ call: CallInfo) -> String {
        switch call.state {
        case "ringing": return call.incoming ? "Incoming call" : "Calling…"
        case "establishing": return "Connecting…"
        case "in_progress": return "Connected"
        case "ended": return "Call ended"
        case "declined": return "Declined"
        case "missed": return "Missed"
        case "failed": return "Call failed"
        case "other_device": return "Answered on another device"
        default: return ""
        }
    }

    @ViewBuilder
    private func controls(_ call: CallInfo) -> some View {
        if call.incoming, call.state == "ringing" {
            HStack(spacing: 10) {
                button("Decline", "phone.down.fill", fill: .red, action: model.declineCall)
                    .accessibilityIdentifier("call.decline")
                button("Accept", "phone.fill", fill: .green, action: model.acceptCall)
                    .accessibilityIdentifier("call.accept")
            }
        } else if !call.isTerminal {
            HStack(spacing: 10) {
                toggle("Mute", model.callMuted ? "mic.slash.fill" : "mic.fill",
                       isOn: model.callMuted, action: model.toggleCallMute)
                    .accessibilityIdentifier("call.mute")
#if !targetEnvironment(macCatalyst)
                toggle("Speaker", "speaker.wave.2.fill",
                       isOn: model.callSpeaker, action: model.toggleCallSpeaker)
                    .accessibilityIdentifier("call.speaker")
#endif
                button("End Call", "phone.down.fill", fill: .red, action: model.endCall)
                    .accessibilityIdentifier("call.end")
            }
        }
    }

    /// Solid circles rather than nested glass, like the other controls that
    /// sit inside a glass card (the attachment preview's send button).
    private func button(
        _ title: String, _ symbol: String, fill: Color, glyph: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(glyph)
                .frame(width: buttonSize, height: buttonSize)
                .background(fill, in: Circle())
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// On is an inverted fill, so the state does not depend on hue alone.
    private func toggle(
        _ title: String, _ symbol: String, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        button(title, symbol,
               fill: isOn ? Color.primary : Color.primary.opacity(0.12),
               glyph: isOn ? Color(.systemBackground) : Color.primary,
               action: action)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
    }
}
