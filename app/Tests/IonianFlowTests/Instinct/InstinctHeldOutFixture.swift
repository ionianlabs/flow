import Foundation
@testable import IonianFlow

/// A held-out meeting for Instinct's precision work: a different domain (a village orchard cooperative), written before
/// any tuning and run only once at the end. All names are invented.
enum InstinctHeldOutFixture {
    typealias L = InstinctGemmaFixtures.Label

    static let talk = [
        "Honestly the apples this year were smaller than I expected, but they taste wonderful.",
        "I think the old shed looks charming, although it leans a little to the left these days.",
        "We could maybe try growing quinces at some point, but that is a long way off.",
        "My neighbour says the frost came early in the valley, and the plums suffered for it.",
        "The volunteers are in a good mood lately, the autumn days really brought people together.",
        "It was a very muddy morning, I nearly lost a boot in the lower field.",
        "I was reading about grafting techniques and there seem to be at least four schools of thought.",
        "Somebody told me the press from the next village is much louder than ours, which I find funny.",
        "To be fair, nobody really knows how old the big pear tree by the gate is.",
        "I like the new hand-painted sign, it feels a lot friendlier than the printed one.",
        "That would be a lovely thing to have one day, maybe when the cooperative has grown a bit.",
        "Right, so the way the pressing day works is that people bring crates, we weigh them, and everybody gets juice back.",
        "I am slightly worried about the wasps, but they seem to be calming down now that it is colder.",
        "Did anyone see the sunset over the hills yesterday? It was almost unreal.",
        "The tractor is not in great shape, but it keeps running, so I would leave it alone.",
        "It is one of those jobs that is much easier with four people than with two.",
        "I had a chat with a woman at the bakery and she was very enthusiastic about our juice.",
        "Some days the whole orchard feels like a lot of work, and other days it feels like a gift.",
        "I do not have a strong opinion about the label colours, either is fine with me.",
        "The cider we made last year was a bit sharp, but people seemed to like it anyway.",
        "Sorry, I was on mute, could you say that again?",
        "I keep thinking we should write down how everything works, but then the weekend comes and I forget.",
        "Mm, that is an interesting thought, I had not looked at it from the customers' side.",
        "Honestly I would not worry about the beehives, the bees seem to take care of themselves.",
        "It rained all of Sunday, so we mostly drank tea in the shed and talked.",
        "The new volunteers asked really good questions about pruning, which was nice to see.",
        "I wonder whether we are making this more complicated than it needs to be.",
        "Back when the cooperative started it was just five of us and a borrowed ladder.",
        "That is a fair point, although I think it matters more for the big trees than the small ones.",
        "Everyone seems to have a different idea of what the perfect market stall looks like.",
        "Well, that is the thing with orchards, you always have to wait and see.",
        "I think the juice tastes better when the apples are mixed, but that is just my taste.",
        "The tree by the fence looks a bit sad this year, I hope it recovers.",
        "We got a few nice messages after the harvest day, mostly about the cake.",
        "Yeah, the notice board outside is a bit of a mess, but people find what they need.",
        "I was surprised how many children turned up, they really enjoyed the pressing.",
        "It is hard to say, honestly, every year is different in the orchard.",
        "Okay, interesting, so it is more about habits than about equipment.",
        "The path to the lower field gets slippery, so people just walk on the grass.",
        "A lot of people ask where the name of the village comes from, and nobody has a good answer.",
        "I am happy with how things went overall, even if it felt chaotic at times.",
        "Thanks for coming, everyone, I know it is a cold evening.",
        "That sounds about right to me, though I would have to check my notes.",
        "Good question, I honestly do not know.",
    ]
    static let fillers = ["Right.", "Yeah, okay.", "Mm-hm.", "Sure, go on.", "Fair enough.", "Hm, let me think.", "Sorry, say that again?", "How was the drive over?", "Okay, interesting.", "That is a good question."]

    /// Tuesday 2026-11-03.
    static let labels: [L] = [
        L(frac: 0.08, speaker: .them, text: "Could you print forty price labels for the market stall before Saturday?", category: .todo, project: "market", due: "2026-11-07"),
        L(frac: 0.22, speaker: .you, text: "So we sell the cider only in returnable bottles, that is decided.", category: .decision, project: "market", due: nil),
        L(frac: 0.34, speaker: .them, text: "The market fee for the stall is ninety euros for the whole season.", category: .fact, project: "market", due: nil),
        L(frac: 0.47, speaker: .you, text: "I have to call the council about the pruning permit this week.", category: .todo, project: nil, due: nil),
        L(frac: 0.60, speaker: .them, text: "The tree register now lists three hundred and twelve trees.", category: .fact, project: "register", due: nil),
        L(frac: 0.72, speaker: .them, text: "We will label the old pear trees with the metal tags, final answer.", category: .decision, project: "register", due: nil),
        L(frac: 0.88, speaker: .them, text: "Remember to bring the ladder on Thursday.", category: .todo, project: nil, due: "2026-11-05"),
    ]

    static let projects: [(slug: String, description: String, focus: String)] = [
        ("market", "Stall at the winter market: products, rota and pricing", "Open the stall on the first Saturday of December"),
        ("register", "Mapping and labelling every tree in the cooperative orchard", "Finish the tree register by February"),
    ]

    static func meeting(file: String) -> [InstinctSource] {
        var sources = InstinctGemmaFixtures.meeting(file: file, minutes: 30, seed: 11, plants: labels.map(\.plant), talk: talk, fillers: fillers)
        let shift = instinctTestDate(2026, 11, 3, 18, 0).timeIntervalSince(instinctTestDate(2026, 11, 4, 9, 0))
        for i in sources.indices { sources[i].time = sources[i].time.addingTimeInterval(shift) }
        return sources
    }
}
