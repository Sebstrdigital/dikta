import XCTest
@testable import Dikta

final class ReadAloudTextPreparerTests: XCTestCase {
    private let preparer = ReadAloudTextPreparer()

    func testPlainTextNormalizesWhitespaceWithoutLosingPunctuation() {
        XCTAssertEqual(preparer.prepare("  Hello\t  world.\r\nThis is  text!  ").text, "Hello world. This is text!")
    }

    func testFormattingOnlyTextIsEmpty() {
        XCTAssertEqual(preparer.prepare("# \n* \n").kind, .empty)
    }

    func testConfirmedTableRetainsHeaderRowsAndEmptyCells() {
        let input = "| Setting | Value | Note |\n|:--|---:|---|\n| Speed | Normal | |\n| Voice | Heart | warm |"
        XCTAssertEqual(preparer.prepare(input).text, "Setting; Value; Note\nSpeed; Normal; \nVoice; Heart; warm")
    }

    func testPartialTableAndCodePipeAreConservative() {
        XCTAssertEqual(preparer.prepare("left | right\nvalue | other").text, "left | right\nvalue | other")
        XCTAssertEqual(preparer.prepare("`a | b` | prose").text, "a | b | prose")
    }

    func testFencedAndInlineCodePreserveContentButDropMatchedWrappers() {
        let input = "```sh\necho $HOME | grep -v _tmp\n```\nUse `foo_bar(-1)` now."
        XCTAssertEqual(preparer.prepare(input).text, "echo $HOME | grep -v _tmp\nUse foo_bar(-1) now.")
        XCTAssertEqual(preparer.prepare("Use ``a ` b`` literally.").text, "Use a ` b literally.")
    }

    func testUnmatchedFenceAndMarkersRemainLiteral() {
        XCTAssertEqual(preparer.prepare("```\necho a | b").text, "```\necho a | b")
        XCTAssertEqual(preparer.prepare("Use *unmatched and foo_bar.").text, "Use *unmatched and foo_bar.")
    }

    func testListsHeadingsAndMatchedEmphasisRemoveOnlyPresentationSyntax() {
        let input = "## Title\n- **first** item\n1. [x] _second_ item\n- -1 is negative"
        XCTAssertEqual(preparer.prepare(input).text, "Title\nfirst item\n1. [x] second item\n-1 is negative")
    }

    func testUnicodeAndEscapedPipesArePreserved() {
        let input = "| Name | Value |\n| --- | --- |\n| cafe\u{301} | \u{1F469}\u{200D}\u{1F4BB} \\| CJK \u{4F60}\u{597D} |"
        XCTAssertEqual(preparer.prepare(input).text, "Name; Value\ncafe\u{301}; \u{1F469}\u{200D}\u{1F4BB} | CJK \u{4F60}\u{597D}")
    }

    func testConservativeLiteralsAndOnlyConfirmedFormattingOnlyForms() {
        XCTAssertEqual(preparer.prepare("*").text, "*")
        XCTAssertEqual(preparer.prepare("2 * 3 + 4").text, "2 * 3 + 4")
        XCTAssertEqual(preparer.prepare("# \n* \n```\n```\n").kind, .empty)
        XCTAssertEqual(preparer.prepare("echo a \\| sed -n '1p'").text, "echo a \\| sed -n '1p'")
    }

    func testInlineCodeAndTableEscapesHaveContextSpecificWhitespaceRules() {
        XCTAssertEqual(preparer.prepare("Use `a   b\\t c` exactly.").text, "Use a   b\\t c exactly.")
        XCTAssertEqual(preparer.prepare("| A | B |\n|---|---|\n| a\\|b | c |").text, "A; B\na|b; c")
    }

    func testExactBacktickRunsAndFencesAreConservative() {
        XCTAssertEqual(preparer.prepare("| A | B |\n|---|---|\n| ``a | b`` | c |").text, "A; B\na | b; c")
        XCTAssertEqual(preparer.prepare("```` swift\nlet x = `a`\n````\n").text, "let x = `a`")
        XCTAssertEqual(preparer.prepare("  ```swift\nlet x = 1\n  ```\n").text, "let x = 1")
        XCTAssertEqual(preparer.prepare("    ```swift\nlet x = 1\n    ```\n").text, "    ```swift\nlet x = 1\n    ```")
        XCTAssertEqual(preparer.prepare("``` bad`info\nx\n```\n").text, "``` bad`info\nx\n```")
    }

    func testSoftWrappedProseJoinsButStructuredAndAmbiguousLinesStayBounded() {
        let input = "A soft wrapped\nparagraph continues.\n\n- item one\n- item two\n\nleft | right\nvalue | other\n\n```sh\necho a | b\n```"
        XCTAssertEqual(preparer.prepare(input).text, "A soft wrapped paragraph continues.\n\nitem one\nitem two\n\nleft | right\nvalue | other\n\necho a | b")
    }

    func testNestedOrderedTaskAndAdversarialInputsRemainOrderedAndBounded() {
        let input = "1. [x] done\n   - nested *literal*\n2. -1..3 --flag foo_bar\n\u{00A0}\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{1F469}\u{200D}\u{1F4BB}"
        XCTAssertEqual(preparer.prepare(input).text, "1. [x] done\nnested literal\n2. -1..3 --flag foo_bar\n\u{00A0}\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{1F469}\u{200D}\u{1F4BB}")
        let hostile = String(repeating: "```\n", count: 20_000) + "x"
        XCTAssertEqual(preparer.prepare(hostile).kind, .ready)
    }

    func testReviewerExactArithmeticAndInlineRunCases() {
        XCTAssertEqual(preparer.prepare("5 * 3 * 2").text, "5 * 3 * 2")
        XCTAssertEqual(preparer.prepare("Use `a`` b` literally.").text, "Use a`` b literally.")
        XCTAssertEqual(preparer.prepare("***one** two***").text, "***one** two***")
    }

    func testReviewerFenceFallbackPreservesRegionLineForLine() {
        let indented = "    ```swift\n    - --flag\n    ```"
        XCTAssertEqual(preparer.prepare(indented).text, indented)
        let invalid = "``` bad`info\n- --flag\n```"
        XCTAssertEqual(preparer.prepare(invalid).text, invalid)
    }

    func testReviewerTableDelimiterAndNBSPConservatism() {
        for input in [
            "| A | B |\n| --:-- | --- |\n| x | y |",
            "| A | B |\n| :---:: | --- |\n| x | y |",
            "| A | B |\n| ---:x | --- |\n| x | y |"
        ] { XCTAssertEqual(preparer.prepare(input).text, input) }
        XCTAssertEqual(preparer.prepare("A\u{00A0}B\t C").text, "A\u{00A0}B C")
    }

    func testReviewerHostileBoundedFallbacksAndEdges() {
        let nearLimit = ReadAloudTextPreparer.maximumInputBytes - 16
        let longRun = String(repeating: "`", count: 8_000)
        let hostile = String(repeating: "\n", count: 4_000) + longRun + "x" + String(repeating: "`", count: 7_999)
        XCTAssertEqual(preparer.prepare(hostile).kind, .ready)
        XCTAssertEqual(preparer.prepare(String(repeating: "```x\n", count: 20_000)).kind, .ready)
        XCTAssertEqual(preparer.prepare(String(repeating: " ", count: nearLimit)).kind, .empty)
        XCTAssertEqual(preparer.prepare(String(repeating: "a", count: ReadAloudTextPreparer.maximumInputBytes)).kind, .ready)
    }

    func testThirdReviewFenceCloseRequiresAtMostThreeSpaces() {
        let input = "```sh\necho start\n    ```\nstill code\n```\n"
        XCTAssertEqual(preparer.prepare(input).text, "echo start\n    ```\nstill code")
    }

    func testThirdReviewEscapedMarkersRemainLiteralInProseAndTables() {
        XCTAssertEqual(preparer.prepare("\\*star\\* \\_under\\_ \\`code\\`").text, "\\*star\\* \\_under\\_ \\`code\\`")
        let table = "| A | B |\n| --- | --- |\n| \\*x\\* | \\`y\\` |"
        XCTAssertEqual(preparer.prepare(table).text, "A; B\n\\*x\\*; \\`y\\`")
    }

    func testThirdReviewNestedSpansAndCodeContainment() {
        XCTAssertEqual(preparer.prepare("**Run `x  y`**").text, "Run x  y")
        XCTAssertEqual(preparer.prepare("**outer *inner* text**").text, "outer inner text")
        XCTAssertEqual(preparer.prepare("`code *inner*`").text, "code *inner*")
        let nested = String(repeating: "**", count: 2_000) + "x" + String(repeating: "**", count: 2_000)
        XCTAssertEqual(preparer.prepare(nested).kind, .ready)
        // This stresses many short code spans interleaved with marker tokens;
        // completion relies on the tokenizer's one-pass span traversal, not timing.
        let adversarial = String(repeating: "`x` **y** ", count: 18_000)
        XCTAssertEqual(preparer.prepare(adversarial).kind, .ready)
    }

    func testThirdReviewLeadingWhitespaceLoneMarkersStayLiteral() {
        for marker in [" -", " +", " *", " #"] { XCTAssertEqual(preparer.prepare(marker).text, marker) }
        XCTAssertEqual(preparer.prepare("# \n* ").kind, .empty)
    }

    func testFourthReviewCodeOwnershipPrecedesEmphasisIncludingTables() {
        XCTAssertEqual(preparer.prepare("**before `a** b` after**").text, "before a** b after")
        let table = "| A | B |\n| --- | --- |\n| **before `a | b` after** | x |"
        XCTAssertEqual(preparer.prepare(table).text, "A; B\nbefore a | b after; x")
    }

    func testFourthReviewEscapedMarkerParityIsConservative() {
        XCTAssertEqual(preparer.prepare("\\*odd\\* \\\\*even\\\\*").text, "\\*odd\\* \\\\*even\\\\*")
        XCTAssertEqual(preparer.prepare("\t*\n \t#").text, "\t*\n \t#")
    }

    func testFifthReviewTableEscapeParityIsConservative() {
        let input = "| A | B | C |\n| --- | --- | --- |\n| \\*odd\\* | \\\\*even\\\\* | \\_u\\_ |\n| \\`code\\` | a\\|b \\*mark\\* | `x \\| y` |"
        XCTAssertEqual(preparer.prepare(input).text, "A; B; C\n\\*odd\\*; \\\\*even\\\\*; \\_u\\_\n\\`code\\`; a\\|b \\*mark\\*; x \\| y")
        let combined = "| A | B |\n| --- | --- |\n| `a  b\\|c` and \\*x\\* | z |"
        XCTAssertEqual(preparer.prepare(combined).text, "A; B\n`a  b\\|c` and \\*x\\*; z")
    }

    func testOuterPresentationWrappersRenderInteriorOnce() {
        let text = "```text\n# Notes\n- first item\n- second item\n```"
        XCTAssertEqual(preparer.prepare(text).text, "Notes\nfirst item\nsecond item")
        let markdown = "```markdown\n| A | B |\n| --- | --- |\n| x | y |\n```"
        XCTAssertEqual(preparer.prepare(markdown).text, "A; B\nx; y")
        let nested = "````text\n```sh\necho $HOME | grep ok\n```\n````"
        XCTAssertEqual(preparer.prepare(nested).text, "echo $HOME | grep ok")
    }

    func testOuterPresentationWrapperDoesNotBroadenFenceRecognition() {
        for input in [
            "```sh\n# literal\n- --flag\n```",
            "```swift\n# literal\n- --flag\n```",
            "```python\n# literal\n- --flag\n```",
            "```\n# literal\n- --flag\n```",
            "```unknown\n# literal\n- --flag\n```",
            "```md\n# literal\n- --flag\n```",
            "```mdown\n# literal\n- --flag\n```",
            "```text bad`label\n# literal\n```",
            "```text\n# partial"
        ] { XCTAssertTrue(preparer.prepare(input).text.contains("# literal") || preparer.prepare(input).text.contains("# partial")) }
    }

    func testOuterWrapperAllowsOnlyExteriorASCIIBlankPadding() {
        XCTAssertEqual(preparer.prepare("```text\n# Notes\n```\n").text, "Notes")
        XCTAssertEqual(preparer.prepare(" \t\n```MARKDOWN\n- item\n```\n\t \n").text, "item")
        let suffix = "```text\n# Notes\n```\nnot padding"
        XCTAssertTrue(preparer.prepare(suffix).text.contains("# Notes"))
        let nbsp = "\u{00A0}\n```text\n# Notes\n```"
        XCTAssertTrue(preparer.prepare(nbsp).text.contains("# Notes"))
    }

    func testRawAndPreparedBoundsRejectRatherThanTruncate() {
        let limit = ReadAloudTextPreparer.maximumInputBytes
        XCTAssertEqual(preparer.prepare(String(repeating: "a", count: limit + 1)).kind, .unsupported)
        XCTAssertEqual(preparer.prepare(String(repeating: "a ", count: limit / 2 + 1)).kind, .unsupported)
    }

    func testPreparationIsDeterministic() {
        let input = "# Heading\n| A | B |\n|---|---|\n| 1 | 2 |"
        XCTAssertEqual(preparer.prepare(input), preparer.prepare(input))
    }
}
