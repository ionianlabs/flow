import AppKit
import SwiftUI

/// `IonianFlow --render <surface> <out.png> [--dark]` and `--render all <dir>`: draws a surface into a
/// bitmap without ordering any window in, so nothing appears on screen. Glass uses the GLS-01 recipe over
/// a Breeze still, standing in for the desktop. Add a surface by adding a line to `surfaces`.
@MainActor enum Renderer {
    struct Surface {
        var size: CGSize
        /// Draws the Breeze still behind the surface, as the desktop.
        var backdrop = false
        var make: () -> AnyView
    }

    static let surfaces: [String: Surface] = [
        "hud": hud(text: "Das Meeting ist um zehn, can you send the deck?"),
        "hud-long": hud(text: "Hallo Team, ich schicke euch die Präsentation heute Nachmittag. Für morgen haben wir drei Themen, "
            + "erstens das Budget, zweitens die Roadmap und drittens das Hiring, can you confirm the numbers by noon?"),
        "hud-two-lines": hud(text: "Das Meeting ist um zehn, can you send the deck? Ich bringe die Zahlen mit."),
        "hud-empty": hud(text: ""),
        "hud-handsfree": hud(text: "", locked: true),
        "settings-general": generalSurface(.normal, width: 820),
        "settings-general-shot": generalSurface(.normal, width: 820, height: 540),
        "settings-general-fresh": generalSurface(.fresh, width: 820),
        "settings-general-cleanup-off": generalSurface(.cleanupOff, width: 820),
        "settings-general-min": generalSurface(.normal, width: 700),
        "settings-general-fresh-min": generalSurface(.fresh, width: 700),
        "settings-general-cleanup-off-min": generalSurface(.cleanupOff, width: 700),
        "settings-shortcuts": Surface(size: CGSize(width: 820, height: 640), make: { AnyView(mainViewForRender(page: .shortcuts)) }),
        "settings-dictation": Surface(size: CGSize(width: 820, height: 640), make: { AnyView(mainViewForRender(page: .dictation)) }),
        "settings-transcription": Surface(size: CGSize(width: 820, height: 640), make: { AnyView(mainViewForRender(page: .transcription)) }),
        "onboarding-0": onboarding(0), "onboarding-1": onboarding(1), "onboarding-2": onboarding(2),
        "onboarding-3": onboarding(3), "onboarding-4": onboarding(4, models: .idle), "onboarding-5": onboarding(5),
        "models-downloading": onboarding(4, models: .downloading), "models-error": onboarding(4, models: .error),
        "models-skipped": onboarding(4, models: .skipped), "models-done": onboarding(4, models: .done),
        "vocabulary": Surface(size: CGSize(width: 820, height: 900), make: { AnyView(mainViewForRender(page: .vocabulary, vocabulary: vocabularySample())) }),
        "vocabulary-shot": Surface(size: CGSize(width: 820, height: 760), make: { AnyView(mainViewForRender(page: .vocabulary, vocabulary: vocabularySample())) }),
        "vocabulary-large": Surface(size: CGSize(width: 820, height: 900), make: { AnyView(mainViewForRender(page: .vocabulary, vocabulary: vocabularyLarge())) }),
        "vocabulary-large-category": Surface(size: CGSize(width: 820, height: 700), make: { AnyView(mainViewForRender(page: .vocabulary, vocabulary: vocabularyLarge(), category: "People")) }),
        "vocabulary-search": Surface(size: CGSize(width: 820, height: 700), make: { AnyView(mainViewForRender(page: .vocabulary, vocabulary: vocabularyLarge(), query: "ar")) }),
        "vocabulary-add": Surface(size: CGSize(width: 820, height: 700), make: { AnyView(mainViewForRender(page: .vocabulary, vocabulary: vocabularyLarge(), query: "Lindgren")) }),
        "vocabulary-empty": Surface(size: CGSize(width: 820, height: 640), make: { AnyView(mainViewForRender(page: .vocabulary)) }),
        "vocabulary-review": Surface(size: CGSize(width: 480, height: 600), make: {
            let store = VocabularyStore(url: vocabularySample(), watch: false)
            return AnyView(ReviewSheet(store: store, entries: store.unreviewed, onDone: {}))
        }),
        "panel-empty": Surface(size: CGSize(width: 560, height: 700), backdrop: true, make: {
            AnyView(transcriptPreview(empty: true).frame(width: 400, height: 640))
        }),
        "panel-ended": Surface(size: CGSize(width: 560, height: 700), backdrop: true, make: {
            AnyView(transcriptPreview(ended: true).frame(width: 400, height: 640))
        }),
        "panel-min": Surface(size: CGSize(width: 400, height: 460), backdrop: true, make: {
            AnyView(transcriptPreview(ended: true).frame(width: WindowLayout.transcriptMin.width, height: WindowLayout.transcriptMin.height))
        }),
        "panel-min-live": Surface(size: CGSize(width: 400, height: 460), backdrop: true, make: {
            AnyView(transcriptPreview().frame(width: WindowLayout.transcriptMin.width, height: WindowLayout.transcriptMin.height))
        }),
        "panel": Surface(size: CGSize(width: 560, height: 700), backdrop: true, make: {
            AnyView(transcriptPreview().frame(width: 400, height: 640))
        }),
    ]

    /// General in a known state: neutral sample totals (2,545 words, 23 min of meetings) unless fresh.
    private static func generalSurface(_ state: RenderState, width: CGFloat, height: CGFloat = 1000) -> Surface {
        Surface(size: CGSize(width: width, height: height), make: {
            var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            domain["statsWords"] = state == .fresh ? 0 : 2545
            domain["statsTranscribedSeconds"] = state == .fresh ? 0 : 1380
            UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
            return AnyView(mainViewForRender(page: .general, state: state))
        })
    }

    private static func hud(text: String, locked: Bool = false) -> Surface {
        Surface(size: CGSize(width: 720, height: 220), backdrop: true, make: {
            let model = OverlayModel()
            model.visible = true
            model.startedAt = Date().addingTimeInterval(-5)
            model.update(text)
            model.startedAt = model.startedAt.addingTimeInterval(-2)  // the words are in by the first frame
            model.lang = "de-DE"
            model.level = 0.03
            model.locked = locked
            return AnyView(OverlayView(model: model))
        })
    }

    enum ModelsState { case idle, downloading, error, skipped, done }

    private static func onboarding(_ step: Int, models state: ModelsState = .done) -> Surface {
        Surface(size: OnboardingWindow.size, make: {
            Settings.registerDefaults()
            let model = AppModel()
            model.status = "ASR: ready"
            let notes = URL(fileURLWithPath: "/tmp/Northwind Notes", isDirectory: true)
            let known = [VaultSweeper.Vault(name: "Northwind Notes", url: notes),
                         VaultSweeper.Vault(name: "Garden", url: URL(fileURLWithPath: "/tmp/Garden", isDirectory: true))]
            let fake = FakeModelStore(installed: state == .done ? [.speech] : [])
            let models = ModelSetupModel(store: fake)
            switch state {
            case .downloading: fake.hold = true; models.start(.speech); models.start(.cleanup)
            case .error: fake.failNext(.speech); models.start(.speech)
            case .skipped: models.skipCleanup()
            default: break
            }
            // Let the fake's first progress and error land before the frame is drawn.
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            return AnyView(OnboardingView(model: model, models: models, step: step, applyShortcuts: {}, connectVault: { _ in },
                                          pickVaultFolder: { nil }, onDone: {}, knownVaults: known, vault: step == 3 ? notes : nil))
        })
    }

    /// A vocabulary file with fictional terms, some of them already reviewed.
    private static func vocabularySample() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ionian-flow-render-vocabulary.md")
        let text = """
            # Ionian Flow Vocabulary

            Domain: civil engineering

            ## Terms
            - ACME
            - pull request (heard as: pool request)

            ## People
            - Marco

            ## Ignore

            <!-- ionian-flow:vault:start x -->
            ## From vault: Northwind Notes

            ### People
            - Jana Weber
            - Lena

            ### Projects
            - Harbor Bridge

            ### Acronyms
            - QA

            ### Products
            - Gemma
            <!-- ionian-flow:vault:end -->

            """
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// ~45 invented terms across categories: the case that used to overwhelm the page.
    private static func vocabularyLarge() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ionian-flow-render-vocabulary-large.md")
        func block(_ name: String, _ items: [String]) -> String { "### \(name)\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        let people = ["Lena", "Marco", "Jana Weber", "Tobias Keller", "Sofia Marin", "Henrik Voss", "Amara Okafor", "Pavel Novak", "Ines Duarte", "Kai Lindner",
                      "Mira Sandoval", "Lena Hartwig", "Yuki Tanaka", "Elena Rossi"]
        let projects = ["Harbor Bridge", "Northwind Logistics", "Project Lantern", "Blue Heron", "Cedar Yard", "Mill Street Depot", "Quarry Line", "Tidewater"]
        let acronyms = ["QA", "RFI", "SLA", "ETA", "BIM", "KPI", "OKR", "SOP"]
        let products = ["Gemma", "Parakeet", "Obsidian", "Figma", "Linear", "Notion"]
        let places = ["Rotterdam", "Gdansk", "Porto", "Tallinn", "Ghent"]
        let text = "# Ionian Flow Vocabulary\n\nDomain: civil engineering\n\n## Terms\n- ACME\n- pull request (heard as: pool request)\n- retaining wall\n\n## People\n- Marco\n\n## Ignore\n\n"
            + "<!-- ionian-flow:vault:start x -->\n## From vault: Northwind Notes\n\n"
            + block("People", people) + block("Projects", projects) + block("Acronyms", acronyms) + block("Products", products) + block("Places", places)
            + "<!-- ionian-flow:vault:end -->\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func run(_ args: [String]) -> Int32 {
        IonianFont.register()
        // Highest-priority defaults, in memory only: renders never show or change this Mac's real settings.
        UserDefaults.standard.setVolatileDomain([
            "renderVersion": "0.1.0", "vault": "/tmp/Northwind Notes", "lastVaultScan": Date().addingTimeInterval(-3600), "dictationKey": "rightOption",
            "vocabularyReviewed": ["jana weber", "lena", "qa"],
        ], forName: UserDefaults.argumentDomain)
        GeneralLayout.numberLocale = Locale(identifier: "en_US")
        let dark = args.contains("--dark")
        let names = args.filter { !$0.hasPrefix("--") }
        guard names.count == 2 else {
            print("usage: --render <surface|all> <out.png|dir> [--dark]\nsurfaces: \(surfaces.keys.sorted().joined(separator: ", "))")
            return 2
        }
        if names[0] == "all" {
            let dir = URL(fileURLWithPath: names[1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var ok = true
            for name in surfaces.keys.sorted() {
                for mode in [false, true] {
                    ok = render(name, dark: mode, to: dir.appendingPathComponent("\(name)\(mode ? "-dark" : "-light").png")) && ok
                }
            }
            return ok ? 0 : 1
        }
        return render(names[0], dark: dark, to: URL(fileURLWithPath: names[1])) ? 0 : 1
    }

    @discardableResult
    static func render(_ name: String, dark: Bool, to url: URL) -> Bool {
        guard let surface = surfaces[name] else { print("unknown surface \(name)"); return false }
        let canvas = Canvas(surface, dark: dark)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))  // let SwiftUI finish its first pass
        guard canvas.snapshot(to: url) else { return false }
        print("wrote \(url.path)")
        return true
    }

    /// One surface in an offscreen host, kept alive so a script can change its model and take frames over time.
    @MainActor final class Canvas {
        let host: NSHostingView<AnyView>
        private let window: NSWindow
        let size: CGSize

        init(_ surface: Surface, dark: Bool) {
            size = surface.size
            let size = surface.size
            let content = ZStack {
                if surface.backdrop { ChromeStill(name: "breeze").frame(width: size.width, height: size.height) }
                surface.make()
            }
            .environment(\.ionianOffscreen, true)
            .frame(width: size.width, height: size.height)

            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host = NSHostingView(rootView: AnyView(content))
            host.sizingOptions = []
            host.appearance = appearance
            host.frame = CGRect(origin: .zero, size: size)
            // Never ordered in: the window only gives the hosting view somewhere to live, far off screen.
            window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
        }

        /// The current state as a PNG, 2 pixels per point.
        @discardableResult
        func snapshot(to url: URL) -> Bool {
            host.layoutSubtreeIfNeeded()
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return false }
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return false }
            return (try? png.write(to: url)) != nil
        }
    }
}
