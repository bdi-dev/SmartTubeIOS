import Observation
import SwiftUI

// MARK: - ToastModifier
//
// A lightweight, self-dismissing message pill that floats near the bottom of
// any view.  Designed to be applied once at an appropriate ancestor — the
// modifier owns the show/hide lifecycle so callers only need to write a value.
//
// Usage:
//   .toast(message: $someStringBinding)
//
// The binding is set to nil automatically after 2 seconds so callers never
// have to schedule their own dismissal.

private struct ToastModifier: ViewModifier {
    @Binding var message: String?
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                toastPill
            }
            .onChange(of: message) { _, newValue in
                dismissTask?.cancel()
                guard newValue != nil else { return }
                dismissTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    message = nil
                }
            }
    }

    @ViewBuilder
    private var toastPill: some View {
        if let text = message {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(.bottom, 32)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                .accessibilityIdentifier("player.toast")
        }
    }
}

extension View {
    /// Displays a self-dismissing toast pill when `message` is non-nil.
    /// The binding is automatically cleared after 2 seconds.
    func toast(message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

// MARK: - ToastCenter
//
// App-wide quiet confirmations ("Download complete", "Saved to Watch Later"). Unlike an alert a
// toast has no button, does not block the screen, and goes away by itself, so routine
// confirmations do not read as warnings. Errors that need a decision keep using alerts.

@MainActor
@Observable
public final class ToastCenter {
    public static let shared = ToastCenter()

    public struct Toast: Identifiable, Equatable {
        public let id = UUID()
        public let title: String
        public let message: String
    }

    public private(set) var current: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    public init() {}

    /// Shows a toast, replacing any current one. It dismisses itself after `duration` seconds.
    public func show(title: String, message: String = "", duration: TimeInterval = 3) {
        let toast = Toast(title: title, message: message)
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, self?.current?.id == toast.id else { return }
            self?.current = nil
        }
    }

    public func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

/// Draws `ToastCenter.shared.current` as a small, non-interactive card near the bottom.
private struct ToastHostModifier: ViewModifier {
    private var center: ToastCenter { .shared }

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                VStack(spacing: 2) {
                    Text(toast.title).font(.footnote.weight(.medium))
                    if !toast.message.isEmpty {
                        Text(toast.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 24)
                #if os(iOS)
                .padding(.bottom, 100)  // clear the tab bar
                #else
                .padding(.bottom, 40)
                #endif
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(toast.message.isEmpty ? toast.title : "\(toast.title). \(toast.message)")
                .accessibilityIdentifier("toast.message")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.current)
    }
}

extension View {
    /// Shows `ToastCenter.shared` toasts over this view. Apply once at the root and on any
    /// full-screen cover (a cover hides the root's toast).
    func toastHost() -> some View {
        modifier(ToastHostModifier())
    }

    /// Replaces `.alert(item:)` for confirmations: when `item` is set it is shown as a toast and
    /// the binding is cleared, so no button is needed.
    func toast(item: Binding<DownloadAlertItem?>) -> some View {
        onChange(of: item.wrappedValue?.id) { _, id in
            guard id != nil, let value = item.wrappedValue else { return }
            ToastCenter.shared.show(title: value.title, message: value.message)
            item.wrappedValue = nil
        }
    }
}
