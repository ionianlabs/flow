import Foundation
import Testing
@testable import IonianFlow

extension IonianFlowTests {
@Suite struct TextCleanup {
    @Test func fillers() {
        let cases: [(String, String?, String)] = [
            ("Um, I think we should, uh, ship it.", "en-US", "I think we should, ship it."),
            ("So, uhm, yeah.", "en-US", "So, yeah."),
            ("Können wir das Meeting morgen um zehn Uhr machen?", "de-DE", "Können wir das Meeting morgen um zehn Uhr machen?"),
            ("Äh, ich schicke euch, ähm, die Präsentation.", "de-DE", "Ich schicke euch, die Präsentation."),
            ("Hmm. Okay, let's go.", "en-US", "Okay, let's go."),
            ("Umbrella and humming stay.", "en-US", "Umbrella and humming stay."),
            ("Das ist, öhm... gut.", nil, "Das ist, gut."),
        ]
        for (input, lang, expected) in cases {
            #expect(FillerFilter.clean(input, lang: lang) == expected, "\(input)")
        }
    }

    @Test func formatting() {
        let cases: [(String, String)] = [
            ("Wir haben drei Themen, erstens das Budget, zweitens die Roadmap und drittens das Hiring.",
             "Wir haben drei Themen:\n1. Das Budget\n2. Die Roadmap\n3. Das Hiring."),
            ("First, update the docs. Second, ship the release. Third, tell the team. Thanks everyone.",
             "1. Update the docs.\n2. Ship the release.\n3. Tell the team.\n\nThanks everyone."),
            ("Punkt eins Kaffee, Punkt zwei Milch", "1. Kaffee\n2. Milch"),
            ("The first time I tried it, it worked.", "The first time I tried it, it worked."),
            ("First, let me check that.", "First, let me check that."),
            ("Give me a second, first I need coffee.", "Give me a second, first I need coffee."),
            ("Hallo Team. Neue Zeile. Wie geht's?", "Hallo Team.\nWie geht's?"),
            ("Thanks, new paragraph, best regards", "Thanks\n\nBest regards"),
            ("Erstens, wir starten morgen", "Erstens, wir starten morgen"),  // live partial: no list yet
            ("Erstens, wir starten morgen, zweitens", "1. Wir starten morgen\n2. "),
        ]
        for (input, expected) in cases {
            #expect(TextFormatter.format(input) == expected, "\(input)")
        }
    }

    @Test func echoRemoval() {
        let them = ["Hey, can you review the pull request before launch? I think the streaming latency looks really good now."]
        let cases: [(String, String)] = [
            ("Hey can you review the pull request before launch", ""),
            ("Hey can you review the pull request yes I'll do it before launch", "Yes I'll do it"),
            ("Hey can you review the full request before launch", ""),  // one misheard word inside
            ("Sure, I'll review it after lunch.", "Sure, I'll review it after lunch."),
            ("I think the streaming latency looks really good now, but the build is slow", "But the build is slow"),
            ("Ja genau, das machen wir so.", "Ja genau, das machen wir so."),
        ]
        for (input, want) in cases {
            #expect(Transcriber.stripEcho(input, theirs: them) == want, "echo: \(input)")
        }
    }
}
}
