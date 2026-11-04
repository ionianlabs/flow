import Foundation

// Unit E. Model-free checks for the Polisher guards and glossary; called from EngineSelfTests.all().
// Expected values were produced by calling the former Python polish.py's functions (messages, finish, grounded, ...) once.

enum PolisherSelfTest {
    static func run() -> Bool {
        var failures = 0
        func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            if got != want {
                failures += 1
                FileHandle.standardError.write(Data("polisher selftest FAIL \(name): got \(got), want \(want)\n".utf8))
            }
        }
        typealias R = PolishRules

        // trigrams, stems
        check("trigrams", R.trigrams("Pull-Request, Ünï!"),
              Set([" pu", " re", " ün", "equ", "est", "l r", "ll ", "nï ", "pul", "que", "req", "st ", "t ü", "ues", "ull", "ünï"]))
        check("stems", R.stems("Wir haben 20 Prozent_x gemacht, naïve Übergänge 3rd"), ["wir", "habe", "proz", "gema", "naïv", "über"])

        // looping: the same three words four times in the last forty
        check("looping yes", R.looping("a b c a b c a b c a b c"), true)
        check("looping three times", R.looping("a b c a b c a b c"), false)
        check("looping none", R.looping("one two three four five"), false)
        check("looping run", R.looping("go go go go go go go"), true)

        // grounded: >= 60 % of stems known (numbers ignored)
        check("grounded all", R.grounded("the cat sat on mat", "the cat sat"), true)
        check("grounded 3 of 5", R.grounded("alpha beta gamma delta epsilon", "alpha beta gamma"), true)
        check("grounded numbers only", R.grounded("12 20", "x"), true)

        // dropped_tail: needs >= 6 stems; one of the last 3 must be among the output's last 8
        check("tail dropped", R.droppedTail("one two three four five six seven", "one two three four"), true)
        check("tail kept", R.droppedTail("one two three four five six seven", "one two three four five"), false)
        check("tail short text", R.droppedTail("a b c", "z"), false)

        // finish
        let src = "so the the new build is like uh twenty percent faster i think"
        func fin(_ text: String, _ out: String, _ ctx: String = "") -> String { R.finish(text, out, context: ctx) }
        check("finish ok", fin(src, "So the new build is like 20 percent faster, I think."), "So the new build is like 20 percent faster, I think.")
        check("finish labels+quotes", fin("hello big world", "\"Hello, big world.\"\nnext"), "Hello, big world.")
        check("finish repeated labels", fin("a b c d", "Segment: Output: A b c d."), "A b c d.")
        check("finish first line only", fin(src, "So the new build is like 20 percent faster, I think.\nExplanation: more text"),
              "So the new build is like 20 percent faster, I think.")
        check("finish think stripped", fin("hello big world", "<think>x\ny</think>\nHello, big world."), "Hello, big world.")
        check("finish unterminated think", fin(src, "<think>So the new build."), src)
        check("finish too short", fin(src, "Yes."), src)
        check("finish too long", fin(src, String(repeating: "x", count: 200)), src)
        check("finish empty", fin(src, ""), src)
        check("finish blank", fin(src, "  \n  "), src)
        check("finish loop", fin("so the build is fast really", "so the build is fast really fast fast fast fast fast fast"), "so the build is fast really")
        check("finish ungrounded", fin("hello world foo", "alpha beta gamma delta"), "hello world foo")
        check("finish grounded by glossary", fin("hello world foo", "alpha beta gamma delta", "alpha beta gamma delta"), "alpha beta gamma delta")
        check("finish length 0.5", fin("ich bin am Montag da und gehe", "Ich bin da."), "ich bin am Montag da und gehe")
        R.faithfulGuard = false  // the older guards alone
        check("finish tail ok", fin("one two three four five six seven", "one two three four five"), "one two three four five")
        R.faithfulGuard = true
        check("finish tail ok, but words dropped", fin("one two three four five six seven", "one two three four five"), "one two three four five six seven")
        check("finish dropped tail", fin("one two three four five six seven", "one two three four"), "one two three four five six seven")
        check("finish extra sentence rejected", fin(src, "So the new build is like 20 percent faster, I think. Also more more more."), src)
        var why = ""
        _ = R.finish("hello world foo", "alpha beta gamma delta") { why = $0 }
        check("finish reason", why, "invented words")

        // faithful: only punctuation, case, fillers, stutters, self-corrections, numbers and misheard words may change
        func ok(_ a: String, _ b: String, _ ctx: String = "") -> Bool { R.faithful(a, b, context: ctx) }
        check("faithful punctuation", ok("so the build is fast i think", "So the build is fast, I think."), true)
        check("faithful filler+stutter+number", ok(src, "So the new build is like 20 percent faster, I think."), true)
        check("faithful german number", ok("also ich denke um zehn Uhr", "Also, ich denke, um 10 Uhr."), true)
        check("faithful decimal", ok("two point five million users", "2.5 million users"), true)
        check("faithful unit", ok("a full 20% of the water", "A full 20 percent of the water"), true)
        check("faithful self-correction", ok("meet on Tuesday no sorry Wednesday at ten", "Meet on Wednesday at 10."), true)
        check("faithful misheard", ok("kannst du den pool request reviewen", "Kannst du den pull request reviewen?"), true)
        check("faithful glossary", ok("we run nemo tron locally", "We run Nemotron locally.", "Known terms: Nemotron"), true)
        check("faithful reorder", ok("die Strömung am Strand gebrochen", "Die Strömung gebrochen am Strand"), false)
        check("faithful dropped words", ok("one two three four five", "one two five"), false)
        check("faithful dropped tail fragment", ok("began to develop. one of the biggest developments", "Began to develop."), false)
        check("faithful added words", ok("it works", "It works well."), false)
        check("faithful inflection", ok("das Gebrüll des Löwens", "Das Gebrüll des Löwen"), false)
        check("faithful rewording", ok("verheiratet zu sein", "verheiratet sind"), false)
        check("faithful restart over filler", ok("um I think we should uh we should push the release", "I think we should push the release."), true)
        check("faithful identical", ok("hello", "Hello."), true)

        // glossary selection and context
        let terms = [
            PolishTerm(text: "Nemotron", aliases: []), PolishTerm(text: "Gemma", aliases: []),
            PolishTerm(text: "LumAI", aliases: []), PolishTerm(text: "Data Garage", aliases: []),
            PolishTerm(text: "pull request", aliases: ["pool request", "poor request"]),
            PolishTerm(text: "Katrin Ruppert", aliases: []),
        ]
        func names(_ t: String, _ k: Int = 15) -> [String] { R.relevant(terms, t, k).map(\.text) }
        check("relevant misheard", names("we run nemo tron and gem locally"), ["Nemotron", "Gemma"])
        check("relevant k=1", names("we run nemo tron and gem locally", 1), ["Nemotron"])
        check("relevant alias", names("kannst du den pool request reviewen"), ["pull request"])
        check("relevant name", names("katherine rupert schickt"), ["Katrin Ruppert"])
        check("relevant none", names("the weather is nice"), [])
        check("relevant empty", names(""), [])
        check("relevant exact", names("data garage"), ["Data Garage"])
        let vocab = PolishVocabulary(domain: "logistics IT", terms: [terms[4]])
        check("context", R.context(vocab, text: "kannst du den pool request reviewen"),
              "Domain: logistics IT\nKnown terms: pull request (often misheard as: pool request, poor request)")
        check("context none", R.context(nil, text: "x"), "")
        check("context empty vocab", R.context(PolishVocabulary(), text: "x"), "")
        check("context domain only", R.context(PolishVocabulary(domain: "d", terms: terms), text: "the weather is nice"), "Domain: d")

        // messages, max_tokens
        check("messages context+before", R.messages("Hallo Welt", context: "Domain: d", before: "vorher").user,
              "Context (never output this):\nDomain: d\nPrevious segment: vorher\nSegment: Hallo Welt\nOutput:")
        check("messages plain", R.messages("Hallo Welt").user, "Segment: Hallo Welt\nOutput:")
        check("messages before only", R.messages("Hallo", before: "prev").user,
              "Context (never output this):\nPrevious segment: prev\nSegment: Hallo\nOutput:")
        check("messages system", R.messages("x").system.hasPrefix("You clean up one segment") && R.messages("x").system.hasSuffix("I think."), true)
        check("max_tokens", [R.maxTokens("abcde"), R.maxTokens("äö")], [42, 41])

        return failures == 0
    }
}
