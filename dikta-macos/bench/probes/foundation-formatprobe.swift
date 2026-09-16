import Foundation
import FoundationModels

// Tests whether Apple's on-device Foundation Models framework (macOS 26) can
// restructure raw dictated text into a typed email/document layout WITHOUT
// changing the words. Runs every sample against both @Generable target types,
// under default GenerationOptions and under greedy/temperature-0 options,
// and reports a word-preservation fidelity metric for each result.
//
// All sample texts below are REAL STT output, per project rule (see
// dikta CLAUDE.md / feedback_test_real_input memory): the English samples are
// copied verbatim from dikta-macos/DiktaTests/FormatterTests.swift fixtures
// (themselves real WhisperKit transcriptions), and the Swedish samples are
// built by concatenating consecutive `text` lines (Whisper special tokens
// stripped) from dikta-macos/bench/results/raw-openai_whisper-large-v3-v20240930_turbo_632MB-sv.jsonl,
// which is read speech but still real STT output. No sample text was invented.

// MARK: - Generable target types

@available(macOS 26.0, *)
@Generable
struct EmailDraft {
    @Guide(description: "Optional greeting line taken verbatim from the input, e.g. 'Hi John,'. Omit if the input has no greeting.")
    var greeting: String?

    @Guide(description: "Body paragraphs in original order, made only of words that appear in the input.")
    var paragraphs: [String]

    @Guide(description: "Bullet points if the input enumerates discrete items; empty array if the input lists nothing.")
    var bullets: [String]

    @Guide(description: "Optional sign-off phrase taken verbatim from the input, e.g. 'Best regards,'. Omit if none is present.")
    var signOff: String?

    @Guide(description: "Optional signature name taken verbatim from the input. Omit if none is present.")
    var signature: String?
}

@available(macOS 26.0, *)
@Generable
struct DocumentDraft {
    @Guide(description: "A short title. Use only words already present in the input; do not invent new wording.")
    var title: String

    @Guide(description: "Sections in original order.")
    var sections: [Section]

    @Generable
    struct Section {
        @Guide(description: "Section heading, built only from words present in the input.")
        var heading: String

        @Guide(description: "Body paragraphs for this section, in original order, made only of words that appear in the input.")
        var paragraphs: [String]

        @Guide(description: "Bullet points for this section; empty array if the input lists nothing here.")
        var bullets: [String]
    }
}

// MARK: - Instructions

let commonRules = """
You restructure raw dictated speech into a structured layout. Follow these rules without exception: \
(1) Preserve every single word from the input exactly as given, in the same language the input is written in. Never translate, not even a single word. \
(2) Never invent, add, infer, or hallucinate any new words, sentences, facts, greetings, sign-offs, titles, or headings that are not literally present in the input. \
(3) Never omit, summarize, condense, or shorten any part of the input. Every word in the input must appear somewhere in your output. \
(4) You may add capitalization, punctuation, and structure (splitting into paragraphs, bullets, sections) but the wording itself must remain unchanged. \
(5) If the input has no clear greeting, sign-off, title, or heading, leave that field empty/omit it rather than making one up.
"""

let emailInstructions = commonRules + """
 Fit the input into an email-like structure: greeting, body paragraphs, bullet points for any enumerated items, sign-off, and signature — using only words present in the input.
"""

let documentInstructions = commonRules + """
 Fit the input into a document-like structure: a title and one or more sections, each with a heading, body paragraphs, and bullet points for enumerated items — using only words present in the input. If the input doesn't naturally suggest a title, build the shortest possible phrase out of words already in the input rather than inventing one.
"""

// MARK: - Samples (real STT output only; see header comment for provenance)

struct Sample {
    let id: String
    let lang: String
    let text: String
}

let samples: [Sample] = [
    // English — verbatim from dikta-macos/DiktaTests/FormatterTests.swift
    Sample(id: "en1-greeting-list", lang: "en", text: "Hello, Regno! So, we have some work to do I guess. There is three things that I want to go through. First things first, there is a new document that we need to take a look at. Second thing, I have some feedback regarding a code review. And the third thing, we need to set a date for when we're going to start working. Okay, so how is life? How are you? How is my mom? Any news about the new car? Okay, have a good day. Best regards, Sebastian."),
    Sample(id: "en2-narrative", lang: "en", text: "I woke up this morning and checked my email. There were about 50 new messages. Most of them were spam but a few were important. I replied to the client and forwarded the contract to legal. Then I had breakfast and drove to the office. Traffic was terrible as usual. I got to the office around 9:30. The first meeting was at 10. We discussed the quarterly results. Revenue is up 15 percent. Expenses are also up but less than expected. The CEO was happy with the numbers."),
    Sample(id: "en3-formal-email", lang: "en", text: "Dear Mr. Johnson, I hope this message finds you well. I'm writing to follow up on our conversation from last week about the partnership opportunity. We've reviewed the terms and everything looks good on our end. However, we'd like to request a few modifications to the payment schedule. Furthermore, our legal team has some questions about the liability clause. Could you arrange a meeting with your legal department? Looking forward to hearing from you. Kind regards, Sarah Chen"),
    Sample(id: "en4-casual-message", lang: "en", text: "Hi Rickad! So regarding your questions, I have fixed everything and it's up and running. How about we set up a meeting for tomorrow? I'm eager to get going with our latest project. How are the wife and the kids by the way? Okay enough about that. Yeah, I'm heading out to the beach. Have a good day. Best regards, Sebastian."),
    Sample(id: "en5-status-update", lang: "en", text: "I wanted to give you an update on the project. We finished the authentication module yesterday. The tests are all green. Moving on to the next thing, we need to discuss the payment integration. I've been looking at Stripe and it seems like a good fit."),

    // Swedish — concatenated consecutive lines from raw-openai_whisper-large-v3-v20240930_turbo_632MB-sv.jsonl,
    // Whisper special tokens (<|...|>) stripped, whitespace collapsed. Read speech, but real STT output.
    Sample(id: "sv1-lines0-5", lang: "sv", text: "Bussar avgår från den distriktsgemensamma busstationen över floden hela dagen. Men de flesta, särskilt de som är på väg mot Öster och Jakar, Buntang, går mellan 6.30 och 7.30. Den officiella Falklandsvalutan är Falklandspundet FKP vars värde motsvarar värdet för en brittisk pund, GBP. Kyrkans centrala makt hade legat i Rom i över tusen år och denna koncentration av makt och pengar fick många att ifrågasätta om denna princip var uppfylld. När alla tillgängliga resurser används effektivt i en organisations funktionella avdelningar kan kreativitet och uppfyllningsrikedom frodas. I Mellanösterns varma klimat var huset inte så viktigt."),
    Sample(id: "sv2-lines6-12", lang: "sv", text: "Vatikanstaten har omkring 800 invånare. Det är världens minsta självständiga land och det land som har lägst antal invånare. Tack till elever och personal vid Säkerhetssäkerheten. Det kan finnas fler maria på närliggande sidan eftersom skorpan är tunnare där. Det gjorde det lättare för lava att stiga upp till ytan. Enligt forskare vid universitetet bildar det två föreningar i kristall som kan blockera nylfunktionen när de reagerar med varandra. Ingen vet säkert vem som skrev det, men vi vet att det stora pergamentet med mått på 75,6 cm x 62,2 cm rullades ihop för lagring tidigt i dess existens. Antalet sörjande var så stort att det inte var möjligt för alla att komma in och närvara vid begravningen på Petersplatsen. Detta sediment var nödvändigt för att skapa sandrev och stränder som fungerade som naturliga miljöer för djurliv. Innan soldaterna kom dit hade Haiti inte haft problem med sjukdomen sedan 1800-talet."),
    Sample(id: "sv3-lines13-19", lang: "sv", text: "Vanligtvis hörde alltid ljuden av turister och försäljare. Ljud och ljusberättelsen är precis som en sagobok. Tack till elever och personal vid Kärnberg. Det påstås särskilt att man kan avgöra om en person ljuger genom att tolka mikrouttryck på rätt sätt. Legeringar är en blandning av två eller flera metaller. Kom ihåg att det finns många olika grundämnen i det periodiska systemet. Tack till elever och personal vid Kärnbergs. I norr besök också fantastiska Sanctuary of Our Lady of Fatima, Helgedom, en plats världsberömd för uppenbarelser av Maria. Filosofen Aristoteles hade en teori om att allt bestod av ett eller flera av totalt fyra element. Dessa var jord, vatten, luft och eld. Tack. Mot slutet av medeltiden började Västeuropa utveckla sin egen stil. En av tidens största utvecklingar till följd av korstågen var att folk började använda knappar för att fästa kläder. Tack till elever och personal vid Säkerhetssäkerheten. Kyrkans centrala makt hade legat i Rom i över tusen år och denna koncentration av makt och pengar fick många till ifrågasätta om denna princip var uppfylld."),
]

// MARK: - Fidelity metric

func wordMultiset(_ s: String) -> [String: Int] {
    let lowered = s.lowercased()
    let allowed = CharacterSet.alphanumerics.union(.whitespaces)
    var scalars = String.UnicodeScalarView()
    for scalar in lowered.unicodeScalars {
        scalars.append(allowed.contains(scalar) ? scalar : " ")
    }
    let cleaned = String(scalars)
    let words = cleaned.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    var dict: [String: Int] = [:]
    for w in words { dict[w, default: 0] += 1 }
    return dict
}

func fidelity(input: String, output: String) -> (added: Int, removed: Int) {
    let a = wordMultiset(input)
    let b = wordMultiset(output)
    var added = 0
    var removed = 0
    for key in Set(a.keys).union(b.keys) {
        let ac = a[key] ?? 0
        let bc = b[key] ?? 0
        if bc > ac { added += bc - ac }
        if ac > bc { removed += ac - bc }
    }
    return (added, removed)
}

// MARK: - Flatten + print helpers

@available(macOS 26.0, *)
func flattenEmail(_ e: EmailDraft) -> String {
    var parts: [String] = []
    if let g = e.greeting { parts.append(g) }
    parts.append(contentsOf: e.paragraphs)
    parts.append(contentsOf: e.bullets)
    if let s = e.signOff { parts.append(s) }
    if let sig = e.signature { parts.append(sig) }
    return parts.joined(separator: " ")
}

@available(macOS 26.0, *)
func flattenDocument(_ d: DocumentDraft) -> String {
    var parts: [String] = [d.title]
    for sec in d.sections {
        parts.append(sec.heading)
        parts.append(contentsOf: sec.paragraphs)
        parts.append(contentsOf: sec.bullets)
    }
    return parts.joined(separator: " ")
}

@available(macOS 26.0, *)
func printEmail(_ e: EmailDraft) -> String {
    """
      greeting: \(e.greeting.map { "\"\($0)\"" } ?? "nil")
      paragraphs: \(e.paragraphs)
      bullets: \(e.bullets)
      signOff: \(e.signOff.map { "\"\($0)\"" } ?? "nil")
      signature: \(e.signature.map { "\"\($0)\"" } ?? "nil")
    """
}

@available(macOS 26.0, *)
func printDocument(_ d: DocumentDraft) -> String {
    var lines: [String] = ["  title: \"\(d.title)\""]
    for (i, sec) in d.sections.enumerated() {
        lines.append("  section[\(i)].heading: \"\(sec.heading)\"")
        lines.append("  section[\(i)].paragraphs: \(sec.paragraphs)")
        lines.append("  section[\(i)].bullets: \(sec.bullets)")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Main

@available(macOS 26.0, *)
func runSample(_ sample: Sample, optionLabel: String, options: GenerationOptions) async {
    // Email
    do {
        let session = LanguageModelSession(instructions: emailInstructions)
        let start = Date()
        let response = try await session.respond(to: sample.text, generating: EmailDraft.self, options: options)
        let elapsed = Date().timeIntervalSince(start)
        let email = response.content
        let flat = flattenEmail(email)
        let (added, removed) = fidelity(input: sample.text, output: flat)
        print("--- sample=\(sample.id) lang=\(sample.lang) type=email opts=\(optionLabel) latency=\(String(format: "%.2f", elapsed))s words_added=\(added) words_removed=\(removed) ---")
        print(printEmail(email))
    } catch {
        print("--- sample=\(sample.id) lang=\(sample.lang) type=email opts=\(optionLabel) ERROR ---")
        print("  \(error)")
    }

    // Document
    do {
        let session = LanguageModelSession(instructions: documentInstructions)
        let start = Date()
        let response = try await session.respond(to: sample.text, generating: DocumentDraft.self, options: options)
        let elapsed = Date().timeIntervalSince(start)
        let doc = response.content
        let flat = flattenDocument(doc)
        let (added, removed) = fidelity(input: sample.text, output: flat)
        print("--- sample=\(sample.id) lang=\(sample.lang) type=document opts=\(optionLabel) latency=\(String(format: "%.2f", elapsed))s words_added=\(added) words_removed=\(removed) ---")
        print(printDocument(doc))
    } catch {
        print("--- sample=\(sample.id) lang=\(sample.lang) type=document opts=\(optionLabel) ERROR ---")
        print("  \(error)")
    }
}

@main
struct FormatProbe {
    static func main() async {
        guard #available(macOS 26.0, *) else {
            print("macOS < 26, FoundationModels unavailable")
            return
        }

        let model = SystemLanguageModel.default
        print("AVAILABILITY:", model.availability)

        switch model.availability {
        case .available:
            break
        default:
            print("Model unavailable — stopping probe here per escalation rule.")
            return
        }

        let optionSets: [(String, GenerationOptions)] = [
            ("default", GenerationOptions()),
            ("greedy-temp0", GenerationOptions(samplingMode: .greedy, temperature: 0)),
        ]

        for (label, options) in optionSets {
            print("\n===== OPTIONS: \(label) =====")
            for sample in samples {
                await runSample(sample, optionLabel: label, options: options)
            }
        }
    }
}
