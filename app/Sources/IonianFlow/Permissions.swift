import AppKit
import AVFoundation
import CoreGraphics

/// The macOS permissions Ionian Flow needs, what each is for, and how to ask for it.
enum Permission: String, CaseIterable, Identifiable {
    case microphone, accessibility, inputMonitoring, systemAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .systemAudio: return "System Audio Recording"
        }
    }

    /// The bold imperative in the setup guide.
    var action: String {
        switch self {
        case .microphone: return "Allow the microphone."
        case .accessibility: return "Allow accessibility."
        case .inputMonitoring: return "Allow input monitoring."
        case .systemAudio: return "Allow system audio."
        }
    }

    var reason: String {
        switch self {
        case .microphone: return "So it can hear you. Audio stays on your Mac."
        case .accessibility: return "So it can paste the text where you type."
        case .inputMonitoring: return "So it can notice your dictation key in any app."
        case .systemAudio: return "For meetings: it transcribes what your Mac plays. macOS asks on your first transcript."
        }
    }

    var required: Bool { self != .systemAudio }

    /// nil: macOS has no way to check it (system audio is only known once audio flows).
    var granted: Bool? {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .systemAudio: return nil
        }
    }

    /// Shows the macOS prompt where there is one; once it has been answered, only System Settings
    /// can change it, so that pane opens instead.
    func request() {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                openSettings()
            }
        case .accessibility:
            _ = TextInserter.hasAccessibility(prompt: true)
            openSettings()
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openSettings() }
        case .systemAudio:
            openSettings()
        }
    }

    func openSettings() {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        case .systemAudio: pane = "Privacy_ScreenCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    static var allRequiredGranted: Bool { allCases.filter(\.required).allSatisfy { $0.granted == true } }
}

extension Settings {
    /// The first-run guide was finished (or skipped).
    static var onboarded: Bool {
        get { UserDefaults.standard.bool(forKey: "onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "onboarded") }
    }
}

/// Quits and opens Ionian Flow again: some permissions only take effect in a new process.
func relaunch() {
    let path = Bundle.main.bundlePath
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
    try? p.run()
    NSApp.terminate(nil)
}
