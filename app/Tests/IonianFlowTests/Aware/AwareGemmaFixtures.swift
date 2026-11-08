import Foundation
@testable import IonianFlow

/// Invented meetings and dictations for the Gemma model tests. All names are made up.
enum AwareGemmaFixtures {
    struct SplitMix { var s: UInt64
        mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
        mutating func rawValue(_ short: [String], _ long: [String]) -> String { next() % 5 == 0 ? pick(short) : pick(long) }
    }

    /// Invented talk that holds nothing worth keeping: opinions, small talk, hypotheticals, narration, open questions.
    static let talk = [
        "Yeah, I looked at the logs this morning and the spikes seem to line up with the nightly sync, but that might be a coincidence.",
        "Honestly I never liked how the settings page is laid out, it always takes me a minute to find anything.",
        "We could maybe try a different approach there at some point, but I would not want to commit to anything right now.",
        "It was a long week, the train was late twice and I barely got through my inbox.",
        "I think the demo went fine, people seemed interested, although nobody asked a lot of questions.",
        "That reminds me of a project I did years ago where the whole thing was held together with spreadsheets.",
        "Sure, go ahead, I am happy to hear what you think about it.",
        "What do you all think about the new layout? I find it a bit busy, but maybe I am just not used to it.",
        "The weather has been terrible, I cycled in and arrived completely soaked.",
        "I was reading about how other teams handle this and there seem to be about five different schools of thought.",
        "To be honest I am not sure the users even notice that part of the interface.",
        "Right, so the way it works today is that the job runs, writes the file, and somebody picks it up later.",
        "That is an interesting point, I had not thought about it from the support side.",
        "I feel like we keep having this same conversation every few weeks without really getting anywhere.",
        "Did anybody watch the match last night? I fell asleep halfway through the second half.",
        "The code is not pretty, but it does the job, and I would rather not touch it unless we have to.",
        "Somebody mentioned that the old approach was faster, but I could not reproduce that on my machine.",
        "I am a bit torn, there are good reasons for both options and I can see why people disagree.",
        "Okay, interesting, so basically the problem is that nobody really owns that part of the system.",
        "I had a call with a customer last week and they were generally happy, just a few small complaints.",
        "It looks better than I expected, to be fair, the colours work well together.",
        "I wonder whether we are overthinking this, a lot of teams just live with it.",
        "Sorry, my connection is flaky today, can you repeat the last part?",
        "The thing about that module is that it grew organically, so nobody remembers why half of it exists.",
        "We talked about something similar in the spring, and I remember the discussion getting quite heated.",
        "Mm, I see what you mean, that would be nice to have, though it feels like a stretch.",
        "My gut feeling is that it will be fine, these things usually sort themselves out.",
        "Lunch was surprisingly good today, the canteen finally changed the menu.",
        "I have been going through the feedback forms and the tone is mostly positive, with the usual grumbling about speed.",
        "Let me share my screen for a second, one moment, can you see it now?",
        "I think the tricky part is explaining it to people who were not in the room.",
        "That is a fair concern, although I do not think it is as bad as it sounds.",
        "Back when I started here the whole process was a lot more manual, which was kind of charming in a way.",
        "Hmm, I would have to look at it again before I can say anything useful.",
        "It is one of those things that is easy to criticise and hard to improve.",
        "Anyway, that is just my impression, I could be completely wrong about it.",
        "We got some nice comments on the last release, mostly about the cleaner look.",
        "Yeah, the diagram on the wiki is outdated, but the general idea is still right.",
        "I would love to dig into that more, it sounds like a fun puzzle.",
        "A colleague of mine ran into the same thing last year and said it took them ages to figure out.",
        "Right, that makes sense, thanks for explaining it.",
        "I guess it depends on who you ask, some people love the new flow and some hate it.",
        "Is that the same issue we saw before the holidays, or a different one?",
        "The graph looks a bit odd on the left side, but I think that is just a rendering quirk.",
        "To be fair the team has been under a lot of pressure lately, so I would cut everyone some slack.",
        "I am not convinced that more tooling is the answer here, sometimes talking to each other is enough.",
        "There was a lot of noise around that topic last quarter, and now it has calmed down.",
        "You know, I think we are mostly on the same page, we just describe it differently.",
        "Oh, that was funny, I did not know that about the old office.",
        "The docs are decent, but they assume you already know the basics.",
        "Honestly, I would be surprised if anyone complained about that, it is a pretty minor thing.",
        "So what happened was, the request came in, it got a bit stuck, and then it just went through on its own.",
        "I could see us revisiting that idea down the road, but it is not on my mind right now.",
        "He seems nice, I only met him briefly at the kickoff, but he asked good questions.",
        "It really does feel like the team has found its rhythm over the past months.",
        "I am slightly worried about how long that takes, but it is hard to tell without more data.",
        "We looked at a few alternatives and none of them was clearly better, to be honest.",
        "Right, the old report had a lot of columns nobody ever used.",
        "Thanks for joining, everyone, I know the schedule is tight today.",
        "Good question, I do not have a good answer at the moment.",
        "That sounds about right, I remember it being roughly like that.",
        "People tend to underestimate how much goes into keeping things running smoothly.",
        "I took a look at the competitor's product and it is, well, different, not necessarily better.",
        "It would be great if the whole thing felt a little less fragile, but that is a long conversation.",
        "I am happy with the progress overall, even if it does not look dramatic from the outside.",
        "Maybe, maybe not, I honestly could not tell you which way it will go.",
        "We had a similar discussion in the hallway earlier, and the opinions were all over the place.",
        "Well, that is the nice thing about this kind of work, there is always something new to learn.",
        "I was a bit surprised how well it held up under the test, considering the state it was in.",
        "Yeah, it is what it is, we will see how it goes.",
        "The new colleague seems to have settled in nicely, which is good to see.",
        "Some days the whole thing feels simple and other days it feels impossible.",
        "Okay, I think I follow, so it is more of a perception problem than a technical one.",
        "I keep forgetting how many steps there are in that process, it always seems longer than it should be.",
        "Not sure, to be honest, I would have to ask around before I say anything definite.",
        "That chart is lovely, but I do not really understand what the colours mean.",
        "Funny enough, the same thing happened to me on holiday, my phone just stopped working.",
        "I have mixed feelings about the whole direction, although I understand where it comes from.",
        "It is quiet now, which is a relief after the busy autumn.",
        "I read an article about this the other day and it said roughly the opposite.",
        "Fine by me, I do not have a strong opinion either way.",
        "The room is a bit cold today, is it only me?",
        "That was a good presentation, clear and not too long.",
        "I suppose we will find out soon enough how people react.",
        "For what it is worth, I think the previous version was a bit friendlier.",
        "Good point, though I think it applies more to the other team than to us.",
        "We should be careful not to read too much into one set of numbers.",
        "It feels like every time we fix one thing, something else pops up, which is just the nature of software.",
        "I do not really have anything to add, I am just listening in today.",
        "Honestly, the whole thing is more complicated than it looks from the outside.",
    ]
    static let fillers = ["Right.", "Yeah, that makes sense.", "Mm-hm, okay.", "Sure, go ahead.", "Fair point.", "Let me think about that for a second.", "Sorry, you were muted.", "How was your weekend, by the way?", "Can everybody see my screen now?", "Hm, I am not sure about that.", "Okay, interesting.", "That is a good question."]

    /// Plant: (position fraction 0..1, speaker, text).
    typealias Plant = (Double, AwareSpeaker, String)

    /// A planted item with its label: what a perfect sweep would write. `project` nil means "none" (a to-do for nobody's project).
    struct Label {
        var frac: Double
        var speaker: AwareSpeaker
        var text: String
        var category: AwareCategory
        var project: String?
        var due: String?
        /// The gate drops decisions and facts without a project, so those can only be found with one.
        var reachable: Bool { category == .todo || project != nil }
        var plant: Plant { (frac, speaker, text) }
    }

    static let meeting1Labels: [Label] = [
        Label(frac: 0.06, speaker: .them, text: "Can you share the migration checklist with the platform team by Friday?", category: .todo, project: "alpha", due: "2026-11-06"),
        Label(frac: 0.15, speaker: .you, text: "Okay, so we go with the weekly release train for the migration, that's settled.", category: .decision, project: "alpha", due: nil),
        Label(frac: 0.27, speaker: .them, text: "The reporting beta opens on the eighteenth of January, that date is fixed now.", category: .fact, project: "orchid", due: nil),
        Label(frac: 0.38, speaker: .you, text: "I need to update the runbook before the freeze starts.", category: .todo, project: nil, due: nil),
        Label(frac: 0.50, speaker: .them, text: "We are not renewing the Hartmann licence for the old reporting tool, that is the final call.", category: .decision, project: "orchid", due: nil),
        Label(frac: 0.62, speaker: .them, text: "Don't forget to ask Jonas about the staging certificate.", category: .todo, project: nil, due: nil),
        Label(frac: 0.74, speaker: .you, text: "The reporting service is now called Orchid, the old name is retired.", category: .fact, project: "orchid", due: nil),
        Label(frac: 0.86, speaker: .them, text: "Could you book the review room for next Monday, ten o'clock?", category: .todo, project: nil, due: "2026-11-09"),
    ]
    static let meeting2Labels: [Label] = [
        Label(frac: 0.20, speaker: .them, text: "Please send Marta the signed contract by Wednesday.", category: .todo, project: nil, due: "2026-11-11"),
        Label(frac: 0.55, speaker: .you, text: "Right, we will use Postgres for the migrated ledger, no more discussion on that.", category: .decision, project: "alpha", due: nil),
        Label(frac: 0.80, speaker: .them, text: "The nightly sync now handles about forty thousand records.", category: .fact, project: "alpha", due: nil),
    ]
    static var meeting1Plants: [Plant] { meeting1Labels.map(\.plant) }
    static var meeting2Plants: [Plant] { meeting2Labels.map(\.plant) }

    /// A meeting of about `minutes` of speech (130 words a minute) on Wednesday 2026-11-04 with the plants inserted.
    static func meeting(file: String, minutes: Int, seed: UInt64, plants: [Plant], talk: [String] = AwareGemmaFixtures.talk, fillers: [String] = AwareGemmaFixtures.fillers) -> [AwareSource] {
        var rng = SplitMix(s: seed)
        let day = awareTestDate(2026, 11, 4, 9, 0)
        var turns: [(AwareSpeaker, String)] = []
        var words = 0
        while words < minutes * 130 {
            var parts: [String] = []
            for _ in 0..<Int(1 + rng.next() % 3) {
                parts.append(rng.rawValue(fillers, talk))
            }
            let t = parts.joined(separator: " ")
            words += t.split(separator: " ").count
            turns.append((rng.next() % 2 == 0 ? .you : .them, t))
        }
        for (frac, sp, text) in plants.sorted(by: { $0.0 > $1.0 }) { turns.insert((sp, text), at: Int(Double(turns.count) * frac)) }
        return turns.enumerated().map { i, t in
            AwareSource(id: "\(file)#\(i)", kind: .transcript(fileName: file), time: day.addingTimeInterval(Double(i) * Double(minutes) * 60 / Double(turns.count)), speaker: t.0, text: t.1)
        }
    }

    /// Labels of the five dictations worth keeping, by text.
    static let dictationLabels: [Label] = [
        Label(frac: 0, speaker: .you, text: "Remind me to renew the vendor contract by Friday.", category: .todo, project: nil, due: "2026-11-06"),
        Label(frac: 0, speaker: .you, text: "Note to self: rotate the staging key every month.", category: .todo, project: nil, due: nil),
        Label(frac: 0, speaker: .you, text: "For the record, the audit is on the third of March.", category: .fact, project: nil, due: "2027-03-03"),
        Label(frac: 0, speaker: .you, text: "We decided to use Postgres for the ledger.", category: .decision, project: "alpha", due: nil),
        Label(frac: 0, speaker: .you, text: "Don't forget to send Marta the invoice on Monday.", category: .todo, project: nil, due: "2026-11-09"),
    ]

    static let projects = [
        AwareProjectHint(slug: "alpha", description: "Rewrite of the export job and the legacy export", focus: "Drop the legacy export and ship the new one in Q1"),
        AwareProjectHint(slug: "orchid", description: "The reporting service and its dashboards", focus: "Private beta in January"),
    ]

    /// 20 dictations: 5 worth keeping (marked), 15 not.
    static let dictations: [(app: String, bundle: String, text: String, keep: Bool)] = [
        ("Notes", "com.apple.Notes", "Remind me to renew the vendor contract by Friday.", true),
        ("Notes", "com.apple.Notes", "Note to self: rotate the staging key every month.", true),
        ("Notes", "com.apple.Notes", "For the record, the audit is on the third of March.", true),
        ("Messages", "com.apple.MobileSMS", "We decided to use Postgres for the ledger.", true),
        ("Notes", "com.apple.Notes", "Don't forget to send Marta the invoice on Monday.", true),
        ("Mail", "com.apple.mail", "Hi Anna, thanks for the update, see you tomorrow.", false),
        ("Messages", "com.apple.MobileSMS", "Sounds good, let's do that.", false),
        ("Slack", "com.tinyspeck.slackmacgap", "Haha yes I saw that, pretty funny.", false),
        ("Mail", "com.apple.mail", "Thank you for your patience, I hope you have a great week.", false),
        ("Slack", "com.tinyspeck.slackmacgap", "I think the new layout is kind of busy but fine.", false),
        ("Notes", "com.apple.Notes", "We could maybe look at caching someday.", false),
        ("Messages", "com.apple.MobileSMS", "How was your weekend?", false),
        ("Slack", "com.tinyspeck.slackmacgap", "I think the API is kind of slow.", false),
        ("Mail", "com.apple.mail", "Good morning everyone, the meeting notes are attached for reference.", false),
        ("Safari", "com.apple.Safari", "Best Italian restaurants near the main station.", false),
        ("Messages", "com.apple.MobileSMS", "Running ten minutes late, sorry.", false),
        ("Slack", "com.tinyspeck.slackmacgap", "Looks good to me, nice work on that.", false),
        ("Notes", "com.apple.Notes", "The weather was lovely during the walk today.", false),
        ("Mail", "com.apple.mail", "Could you please confirm that you received my last message?", false),
        ("Slack", "com.tinyspeck.slackmacgap", "Interesting, I had not thought about it that way.", false),
    ]

    static func dictationSources(copies: Int = 1) -> [AwareSource] {
        var out: [AwareSource] = []
        let base = awareTestDate(2026, 11, 5, 8, 0)
        for c in 0..<copies {
            for (i, d) in dictations.enumerated() {
                let n = c * dictations.count + i
                out.append(AwareSource(id: "d\(n)", kind: .dictation(app: d.app, bundle: d.bundle), time: base.addingTimeInterval(Double(n) * 90), speaker: nil, text: d.text))
            }
        }
        return out
    }

    static func source(_ id: String, _ speaker: AwareSpeaker, _ text: String, day: Date = awareTestDate(2026, 11, 5, 10, 14)) -> AwareSource {
        AwareSource(id: id, kind: .transcript(fileName: "t.md"), time: day, speaker: speaker, text: text)
    }
}
