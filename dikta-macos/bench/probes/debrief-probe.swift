import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Feeds realistic dictated meeting-debrief transcripts (English + Swedish)
// through FoundationModelsDebriefSummarizer and HeuristicDebriefSummarizer to
// capture real, working outputs from both engines as PoC evidence — see
// docs/review-2026-09/debrief-probe-2026-09-17.md for the write-up.
//
// All six transcripts below are SYNTHETIC (no real recording/history.json was
// available to source from), but written in the shape WhisperKit actually
// produces for a rambling, unscripted single-speaker debrief: capitalized
// starts at each implied sentence boundary, almost no terminal punctuation
// (so HeuristicDebriefSummarizer's discourse-marker/run-on splitting in
// dikta-macos/Dikta/Services/Debrief/HeuristicDebriefSummarizer.swift is
// actually exercised instead of trivially splitting on periods), filler
// words, and no line breaks. Each transcript contains at least one spoken
// owner+deadline, one decision, and one open question, worded so both a
// keyword-heuristic and an LLM should be able to find them.

// MARK: - Samples

struct Sample {
    let id: String
    let lang: String
    let text: String
}

let samples: [Sample] = [
    Sample(
        id: "en1-design-sync",
        lang: "en",
        text: "So we just wrapped up the sync with the design team and there is a lot to go through First thing Maria said the onboarding mockups are basically done and she will send the final Figma link to the whole team by Friday next week which is great because we have been blocked on that for like two weeks Then we spent a good chunk of time debating whether to use a modal or a full screen takeover for the upgrade prompt and honestly nobody landed on a clear answer yet so that one is still unclear and we need to figure it out before engineering can start Okay next we did agree that the free trial reminder should use the modal pattern everybody agreed on that after Jonas showed the click through numbers from last quarter Also Sarah is going to own reaching out to the two beta customers who complained about the confusing settings page and she needs to have notes back to the team by next Wednesday morning before the planning meeting Then Peter brought up that the analytics dashboard still is not tracking the new signup funnel correctly and it just shows zero for half the events which is worrying going into launch Also legal still has not signed off on the updated terms of service and that is blocking the pricing page changes so we cannot ship those until that comes through One more thing the support team flagged that the churn survey response rate dropped a lot this month and it is not sure if that is because of the new tool or just fewer people churning so someone should dig into that before we draw any conclusions Okay overall good meeting lots of momentum but a few loose ends before next week"
    ),
    Sample(
        id: "en2-sales-call",
        lang: "en",
        text: "Okay so that call with Acme went actually pretty well overall they are still interested in the enterprise plan but they have some concerns about the migration timeline First thing the client said their current contract with the other vendor does not expire until March so we need to figure out a transition plan that does not leave them paying for two tools at once Then David is going to put together a migration proposal and he will send it over to their procurement team by next Monday which is tight but doable Also we decided to offer them a two month trial extension so they can test the reporting features before committing fully everybody on our side agreed that was the right call given how close we are to closing this Then we spent a while talking about pricing and honestly it is still unclear whether they want the annual plan or the monthly one with a discount so that is an open question for the next call Also the client mentioned their VP of ops wants a security review before signing off and nobody on our team is sure who owns coordinating that internally so someone needs to figure that out soon Next Lisa is going to follow up with their technical lead about the API rate limits since that came up twice during the call and she should have an answer by Thursday One more thing the client asked about our uptime guarantees and we did not have a great answer on the spot so we should probably put together a one pager on that before the next meeting Overall promising call but a few things to close out fast"
    ),
    Sample(
        id: "en3-incident-postmortem",
        lang: "en",
        text: "So that was a rough one the payment service went down for about forty minutes this afternoon and we need to walk through what happened First thing the on call engineer noticed the alerts around two fifteen but it took almost ten minutes to page the right person because the escalation policy still points to someone who left the team last month so we must fix that routing today Then we spent a while digging through logs and it looks like the database connection pool got exhausted after a deploy earlier in the day nobody caught it in staging because the load there is nowhere close to production traffic Okay so we decided to add a synthetic load test to the staging pipeline before every deploy going forward everyone on the call agreed that should have caught this sooner Also Tom is going to own updating the escalation policy and he needs to have the new on call rotation documented by end of day tomorrow Next we talked about whether we should roll back deploys automatically when error rates spike but honestly that is still unclear because nobody wants false positives triggering rollbacks during normal traffic spikes so that is an open question for the platform team to think through Also Anna mentioned the status page update went out fifteen minutes late because nobody remembered the runbook step for that and she will add a reminder to the deploy checklist by Friday One more thing we still do not have a root cause for why the connection pool config was not caught in code review so someone should look into whether we need a linter rule for that Overall a painful afternoon but a clear list of fixes coming out of it"
    ),
    Sample(
        id: "sv1-marknad-sync",
        lang: "sv",
        text: "Okej så vi hade precis avstämning med marknadsteamet och det var mycket att gå igenom Först sa Erik att kampanjmaterialet för höstlanseringen är nästan klart och han ska skicka de slutgiltiga banderollerna till hela teamet senast fredag nästa vecka vilket är skönt eftersom vi legat efter där i typ två veckor Sen pratade vi länge om huruvida vi ska köra influencer-samarbetet på Instagram eller TikTok och ärligt talat är det fortfarande oklart vilken kanal som passar bäst för den här målgruppen så det är en öppen fråga vi behöver lösa innan budgeten låses Också bestämde vi att nyhetsbrevet ska gå ut på tisdagar istället för torsdagar alla höll med efter att Sara visade öppningsstatistiken från förra kvartalet Sedan kommer Lina att äga uppföljningen med de tre kunderna som klagade på den nya prisstrukturen och hon behöver ha återkoppling klar till teamet senast onsdag morgon före planeringsmötet Också värt att nämna att analyspanelen fortfarande inte räknar konverteringar korrekt från landningssidan och ingen är riktigt säker på varför den bara visar noll för hälften av händelserna vilket känns lite oroande inför lanseringen Sen tog Johan upp att juridik fortfarande inte har godkänt de nya kampanjvillkoren och det blockerar annonserna så vi kan inte publicera dem förrän det är klart En sak till supportteamet flaggade att svarsfrekvensen på kundundersökningen sjönk rejält den här månaden och det är osäkert om det beror på det nya verktyget eller bara färre som hör av sig så vi bör nog gräva i det innan vi drar några slutsatser Överlag bra möte mycket driv men några lösa trådar att knyta ihop innan nästa vecka"
    ),
    Sample(
        id: "sv2-kundsamtal",
        lang: "sv",
        text: "Så det där samtalet med Nordkund gick faktiskt ganska bra överlag de är fortfarande intresserade av enterprise-paketet men har en del frågor kring migreringstidslinjen Först sa kunden att deras nuvarande avtal med den andra leverantören inte löper ut förrän i mars så vi måste ta fram en övergångsplan som inte gör att de betalar för två system samtidigt Sen ska David sätta ihop ett migreringsförslag och han ska skicka över det till deras inköpsavdelning senast på måndag vilket är stressigt men görbart Också kom vi överens om att erbjuda dem en förlängd testperiod på två månader så att de kan testa rapportfunktionerna innan de bestämmer sig helt alla på vår sida höll med om att det var rätt beslut med tanke på hur nära vi är en affär Sen pratade vi ett tag om prissättning och ärligt talat är det fortfarande osäkert om de vill ha årsplanen eller månadsplanen med rabatt så det är en öppen fråga till nästa samtal Också nämnde kunden att deras driftchef vill ha en säkerhetsgenomgång innan de skriver på och ingen i vårt team vet riktigt vem som äger att koordinera det internt så någon behöver reda ut det snart Sedan ska Lisa följa upp med deras tekniska ledare om api-gränserna eftersom det kom upp två gånger under samtalet och hon bör ha ett svar senast på torsdag En sak till kunden frågade om våra drifttidsgarantier och vi hade inget bra svar på plats så vi bör nog ta fram en sammanfattning om det innan nästa möte Överlag ett lovande samtal men några saker att knyta ihop snabbt"
    ),
    Sample(
        id: "sv3-incident",
        lang: "sv",
        text: "Okej det där var en jobbig eftermiddag betaltjänsten låg nere i ungefär fyrtio minuter och vi behöver gå igenom vad som hände Först märkte jouren larmen runt två och kvart men det tog nästan tio minuter att larma rätt person eftersom eskaleringsrutinen fortfarande pekar på någon som slutade i teamet förra månaden så vi måste fixa den routingen redan idag Sen grävde vi ett tag i loggarna och det ser ut som att databaskopplingspoolen tog slut efter en driftsättning tidigare på dagen ingen fångade det i staging eftersom belastningen där inte är i närheten av produktionstrafiken Okej så vi bestämde att lägga till ett syntetiskt lasttest i staging-pipelinen inför varje driftsättning framöver alla på mötet höll med om att det borde ha fångats tidigare Också ska Tomas äga uppdateringen av eskaleringsrutinen och han behöver ha den nya jourrotationen dokumenterad senast i morgon eftermiddag Sen pratade vi om huruvida vi ska rulla tillbaka driftsättningar automatiskt när felfrekvensen spikar men ärligt talat är det fortfarande oklart eftersom ingen vill ha falska larm som triggar återställningar vid normala trafiktoppar så det är en öppen fråga för plattformsteamet att fundera vidare på Också nämnde Anna att statussidan uppdaterades femton minuter för sent eftersom ingen kom ihåg det steget i driftboken och hon ska lägga till en påminnelse i checklistan för driftsättningar senast på fredag En sak till vi har fortfarande ingen grundorsak till varför konfigurationen för kopplingspoolen inte fångades i kodgranskningen så någon bör kolla om vi behöver en lint-regel för det Överlag en smärtsam eftermiddag men en tydlig lista med åtgärder efter det"
    ),
]

// MARK: - Helpers

/// Prints a line and flushes stdout immediately, so output survives even if
/// the process is killed or the terminal buffer is lost mid-run (the earlier
/// foundation-formatprobe run was truncated mid-print without this).
func printFlush(_ s: String) {
    print(s)
    fflush(stdout)
}

func jsonString(_ summary: DebriefSummary) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(summary), let str = String(data: data, encoding: .utf8) else {
        return "<failed to encode DebriefSummary as JSON>"
    }
    return str
}

/// Runs one sample through one engine, printing engine/language/latency, the
/// raw JSON, and the rendered plain text — or the verbatim error on failure.
///
/// Applies `.normalized()` before printing, same as `DebriefPipeline` does
/// before rendering for real users, so probe output reflects what a user
/// would actually see pasted, not the engine's raw (pre-normalization) result.
///
/// Note: this probe intentionally stops at `.normalized()` and does not also
/// call `DebriefSummary.validated(against:)` (added in Tuning round 2),
/// because the same probe source is compiled against both the pre-tuning and
/// post-tuning snapshot of `DebriefSummary.swift` to produce the round-2
/// before/after evidence, and `validated(against:)` does not exist in the
/// pre-tuning snapshot. `validated(against:)`'s behavior is covered instead
/// by unit tests (`DiktaTests/DebriefSummaryTests.swift`,
/// `DiktaTests/DebriefRealTranscriptTests.swift`) against the exact defective
/// summaries this round's real recordings produced.
func runSample(engine: DebriefSummarizer, sample: Sample) async {
    let start = Date()
    do {
        let result = try await engine.summarize(transcript: sample.text, language: sample.lang).normalized()
        let elapsed = Date().timeIntervalSince(start)
        printFlush("=== sample=\(sample.id) lang=\(sample.lang) engine=\(engine.name) latency=\(String(format: "%.2f", elapsed))s ===")
        printFlush("--- JSON ---")
        printFlush(jsonString(result))
        printFlush("--- renderPlainText(language: \"\(sample.lang)\") ---")
        printFlush(result.renderPlainText(language: sample.lang))
    } catch {
        let elapsed = Date().timeIntervalSince(start)
        printFlush("=== sample=\(sample.id) lang=\(sample.lang) engine=\(engine.name) latency=\(String(format: "%.2f", elapsed))s ERROR ===")
        printFlush("\(error)")
    }
}

// MARK: - Stability (--runs mode)

/// Whether decisions, action-item texts, and action-item due strings came out
/// identical across a set of same-sample runs. With fewer than 2 successful
/// runs there is nothing to compare, so every field reports stable.
struct StabilityResult {
    let decisionsStable: Bool
    let actionsStable: Bool
    let dueStable: Bool
}

func checkStability(_ results: [DebriefSummary]) -> StabilityResult {
    guard let first = results.first, results.count > 1 else {
        return StabilityResult(decisionsStable: true, actionsStable: true, dueStable: true)
    }
    let decisionsStable = results.allSatisfy { $0.decisions == first.decisions }
    let firstActionTexts = first.actionItems.map(\.text)
    let actionsStable = results.allSatisfy { $0.actionItems.map(\.text) == firstActionTexts }
    let firstDueStrings = first.actionItems.map { $0.due ?? "nil" }
    let dueStable = results.allSatisfy { $0.actionItems.map { $0.due ?? "nil" } == firstDueStrings }
    return StabilityResult(decisionsStable: decisionsStable, actionsStable: actionsStable, dueStable: dueStable)
}

/// Runs `sample` through `engine` `runs` times, printing each run's full
/// output (same shape as `runSample`) plus — when `runs > 1` — one trailing
/// STABILITY line comparing decisions/action-item-texts/due-strings across
/// whichever runs succeeded. A single run (the default) prints nothing extra,
/// since there is nothing to compare.
func runSampleWithStability(engine: DebriefSummarizer, sample: Sample, runs: Int) async {
    var successes: [DebriefSummary] = []
    var errorCount = 0

    for _ in 0..<max(1, runs) {
        let start = Date()
        do {
            let result = try await engine.summarize(transcript: sample.text, language: sample.lang).normalized()
            let elapsed = Date().timeIntervalSince(start)
            printFlush("=== sample=\(sample.id) lang=\(sample.lang) engine=\(engine.name) latency=\(String(format: "%.2f", elapsed))s ===")
            printFlush("--- JSON ---")
            printFlush(jsonString(result))
            printFlush("--- renderPlainText(language: \"\(sample.lang)\") ---")
            printFlush(result.renderPlainText(language: sample.lang))
            successes.append(result)
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            printFlush("=== sample=\(sample.id) lang=\(sample.lang) engine=\(engine.name) latency=\(String(format: "%.2f", elapsed))s ERROR ===")
            printFlush("\(error)")
            errorCount += 1
        }
    }

    guard runs > 1 else { return }

    if successes.count < 2 {
        printFlush("STABILITY sample=\(sample.id) engine=\(engine.name): n/a (\(errorCount)/\(runs) runs errored)")
    } else {
        let stability = checkStability(successes)
        func label(_ stable: Bool) -> String { stable ? "stable" : "DIVERGED" }
        printFlush(
            "STABILITY sample=\(sample.id) engine=\(engine.name): " +
            "decisions=\(label(stability.decisionsStable)) " +
            "actions=\(label(stability.actionsStable)) " +
            "due=\(label(stability.dueStable)) " +
            "(\(successes.count)/\(runs) succeeded)"
        )
    }
}

// MARK: - Session transcripts (--sessions mode)

/// Trivial Swedish-vs-English language detector: counts whole-word,
/// case-insensitive occurrences of a handful of very common stop words per
/// language and picks whichever has more. Ties (including zero/zero) default
/// to English. Good enough to route a real session transcript to the right
/// prompt language without pulling in NLLanguageRecognizer for a probe.
func detectLanguage(_ text: String) -> String {
    let svStopWords: Set<String> = ["och", "att", "är", "det", "jag", "ska"]
    let enStopWords: Set<String> = ["the", "and", "is", "to", "i", "will"]

    let tokens = text
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }

    var svCount = 0
    var enCount = 0
    for token in tokens {
        if svStopWords.contains(token) { svCount += 1 }
        if enStopWords.contains(token) { enCount += 1 }
    }
    return svCount > enCount ? "sv" : "en"
}

/// Loads one `Sample` per `<dir>/*/transcript.txt`, skipping any session
/// folder that has no transcript or an empty one. `id` is the session
/// folder's own name (e.g. a timestamp) so probe output is traceable back to
/// `~/Documents/Dikta/<id>/`.
func loadSessionSamples(from dir: String) -> [Sample] {
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else {
        return []
    }

    var result: [Sample] = []
    for entry in entries.sorted() {
        let sessionDir = (dir as NSString).appendingPathComponent(entry)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sessionDir, isDirectory: &isDirectory), isDirectory.boolValue else {
            continue
        }

        let transcriptPath = (sessionDir as NSString).appendingPathComponent("transcript.txt")
        guard let rawText = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            continue
        }

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }

        result.append(Sample(id: entry, lang: detectLanguage(trimmed), text: trimmed))
    }
    return result
}

// MARK: - Corpus transcripts (--corpus mode)

/// Loads one `Sample` per `<dir>/*.txt` — the in-repo regression corpus
/// (`dikta-macos/bench/probes/debrief-corpus/`), copied verbatim from real
/// `~/Documents/Dikta/<session>/transcript.txt` recordings. Unlike
/// `loadSessionSamples`, language is NOT detected — it comes straight from
/// the filename prefix ("en-"/"sv-"), since these filenames are chosen
/// deliberately (see debrief-corpus/ for the naming) rather than being
/// timestamp folder names. `id` is the filename without its extension.
/// Files without a recognized prefix are skipped. Sorted for a deterministic
/// run order.
func loadCorpusSamples(from dir: String) -> [Sample] {
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else {
        return []
    }

    var result: [Sample] = []
    for entry in entries.sorted() where entry.hasSuffix(".txt") {
        let lang: String
        if entry.hasPrefix("en-") {
            lang = "en"
        } else if entry.hasPrefix("sv-") {
            lang = "sv"
        } else {
            continue
        }

        let path = (dir as NSString).appendingPathComponent(entry)
        guard let rawText = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }

        result.append(Sample(id: (entry as NSString).deletingPathExtension, lang: lang, text: trimmed))
    }
    return result
}

// MARK: - Main

@main
struct DebriefProbe {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)

        guard #available(macOS 26.0, *) else {
            printFlush("macOS < 26.0 — FoundationModels unavailable, aborting probe.")
            return
        }

        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        printFlush("AVAILABILITY: \(model.availability)")

        guard model.availability == .available else {
            printFlush("Foundation Models unavailable (\(model.availability)) — stopping probe here per escalation rule.")
            return
        }

        let foundationModelsEngine = FoundationModelsDebriefSummarizer()
        let heuristicEngine = HeuristicDebriefSummarizer()

        // `--runs N` (default 1) repeats every sample N times per engine and
        // prints a per-sample STABILITY line at the end (see
        // runSampleWithStability). Applies uniformly across all three modes.
        let arguments = CommandLine.arguments
        var runs = 1
        if let flagIndex = arguments.firstIndex(of: "--runs"), flagIndex + 1 < arguments.count,
           let parsed = Int(arguments[flagIndex + 1]), parsed > 0 {
            runs = parsed
        }

        // `--corpus <dir>` iterates `<dir>/*.txt` — the in-repo regression
        // corpus, language taken from the filename prefix. Takes priority
        // over `--sessions` if both are somehow passed.
        if let flagIndex = arguments.firstIndex(of: "--corpus"), flagIndex + 1 < arguments.count {
            let corpusDir = arguments[flagIndex + 1]
            let corpusSamples = loadCorpusSamples(from: corpusDir)
            guard !corpusSamples.isEmpty else {
                printFlush("No corpus files found under \(corpusDir) (expected \(corpusDir)/{en,sv}-*.txt)")
                return
            }
            for sample in corpusSamples {
                printFlush("### corpus=\(sample.id) lang=\(sample.lang) ###")
                await runSampleWithStability(engine: foundationModelsEngine, sample: sample, runs: runs)
                await runSampleWithStability(engine: heuristicEngine, sample: sample, runs: runs)
            }
            return
        }

        // `--sessions <dir>` iterates `<dir>/*/transcript.txt` (real recordings
        // saved by the app) instead of the synthetic samples below. Default
        // (no args) keeps the original synthetic-sample behavior.
        if let flagIndex = arguments.firstIndex(of: "--sessions"), flagIndex + 1 < arguments.count {
            let sessionsDir = arguments[flagIndex + 1]
            let sessionSamples = loadSessionSamples(from: sessionsDir)
            guard !sessionSamples.isEmpty else {
                printFlush("No sessions found under \(sessionsDir) (expected \(sessionsDir)/*/transcript.txt)")
                return
            }
            for sample in sessionSamples {
                printFlush("### session=\(sample.id) detectedLang=\(sample.lang) ###")
                await runSampleWithStability(engine: foundationModelsEngine, sample: sample, runs: runs)
                await runSampleWithStability(engine: heuristicEngine, sample: sample, runs: runs)
            }
            return
        }

        for sample in samples {
            await runSampleWithStability(engine: foundationModelsEngine, sample: sample, runs: runs)
            await runSampleWithStability(engine: heuristicEngine, sample: sample, runs: runs)
        }
        #else
        printFlush("FoundationModels not importable on this platform — aborting probe.")
        #endif
    }
}
