"""Tests for `dikta.core.debrief.prompts`.

Ported from `DebriefPromptBuilderLabeledTranscriptTests` (the byte-identical
snapshot tests) and `DebriefPromptBuilderLanguageTests`
(`DiktaTests/DebriefSummaryTests.swift:819-955`). The expected text below is
assembled independently of `dikta.core.debrief.prompts` (copied from
port-spec section 6, itself sourced from the Swift snapshot tests) so this
is a real regression check, not a tautology. Long lines are split into
adjacent string literals purely to respect the project's line-length limit;
each pair concatenates back to the exact original text.
"""

from __future__ import annotations

import pytest

from dikta.core.debrief.prompts import system_prompt, user_prompt

_JSON_SCHEMA = (
    "{\n"
    '  "summary": "string, 2-5 sentences",\n'
    '  "decisions": ["string", "..."],\n'
    '  "actionItems": [{"text": "string", "owner": "string or null", "due": "string or null"}],\n'
    '  "openQuestions": ["string", "..."]\n'
    "}"
)

_INTRO = (
    "You are an assistant that summarizes spoken post-meeting debriefs. The transcript is the "
    "USER's own first-person account of a meeting they just left — not a description of someone "
    "else. The transcript may be Swedish or English, and punctuation may be missing or "
    "inconsistent because it comes from speech-to-text."
)

_SELF_NAMING_EN = (
    "Write your output in the SAME language as the transcript, and in FIRST PERSON (\"I\", "
    "\"we\") the way the speaker talks — never call them \"the speaker\" or refer to them in "
    "the third person. If the speaker states their own name (often as an aside, e.g. \"it "
    "was me, Sebastian, and Erik\"), that name refers to THEM, the speaker — it is not a "
    "separate third person they met with. Never write something like \"we met with "
    "Sebastian\" when Sebastian is the speaker's own name; write \"I met with...\" instead. "
    "Use that name as the owner for actions the speaker themselves will do. Write every "
    "field, including owner and due, in the transcript's language only."
)

_SELF_NAMING_SV = (
    "Write your output in the SAME language as the transcript, and in FIRST PERSON (\"I\", "
    "\"we\") the way the speaker talks — never call them \"the speaker\" or refer to them in "
    "the third person. If the speaker states their own name (often as an aside, e.g. \"det "
    "var jag, Sebastian och Erik\"), that name refers to THEM, the speaker — it is not a "
    "separate third person they met with. Never write something like \"we met with "
    "Sebastian\" when Sebastian is the speaker's own name; write \"I met with...\" instead. "
    "Use that name as the owner for actions the speaker themselves will do. Write every "
    "field, including owner and due, in the transcript's language only."
)

_SPEECH_TO_TEXT = (
    "Speech-to-text often spells the same name or company two different ways in one "
    "transcript (e.g. \"Acme\" vs \"Akme\" for the same company). These are the SAME entity, "
    "not two different ones. Before you write anything, decide on ONE spelling for every "
    "name that appears more than once with different spellings, and re-check your finished "
    "summary, decisions, action items, and open questions to make sure the spelling you "
    "rejected does not appear ANYWHERE in them — not even once, not even in the summary "
    "while a decision uses the other spelling."
)

_RETURN_JSON = (
    "Return ONLY a JSON object with this shape, no prose before or after it:\n" + _JSON_SCHEMA
)

_RULE_SPELLING = (
    "- Spell every name/company only ONE way everywhere, even if the transcript spells it more "
    "than one way."
)

_RULE_SUMMARY = (
    "- summary: 2-5 sentences, first person, what happened IN the meeting. Something already "
    "done or true before the meeting is context here only, never a decision or action."
)

_RULE_DECISIONS_EN = (
    "- decisions: ONLY things explicitly agreed or concluded, using committal language actually "
    "spoken (e.g. \"we decided\", \"we'll go with\"). A conditional or either/or still being "
    "weighed (\"if he should X or Y\") is an openQuestion, not a decision. A future task — "
    "scheduling, booking, sending, following up — is always an actionItem, never a decision, "
    "even phrased as \"we decided to...\". Empty array if none."
)

_RULE_DECISIONS_SV = (
    "- decisions: ONLY things explicitly agreed or concluded, using committal language "
    "actually spoken (e.g. \"vi bestämde\", \"vi kör på\"). A conditional or either/or still "
    "being weighed (\"om han ska X eller Y\") is an openQuestion, not a decision. A future "
    "task — scheduling, booking, sending, following up — is always an actionItem, never a "
    "decision, even phrased as \"vi bestämde att...\". Empty array if none."
)

_RULE_ACTION_ITEMS_EN = (
    "- actionItems: things still to do after the meeting. owner is the GRAMMATICAL SUBJECT "
    "of the task as spoken: \"I\" means the speaker — use their own stated name, else \"me\"; "
    "\"X will\" means X. Never give the speaker's own task to someone else nearby. An "
    "already-arranged event (\"we will have a meeting tomorrow\") is NOT an action item — "
    "summary only. due is copied VERBATIM as spoken (e.g. \"one week from now\", \"tomorrow\") "
    "— NEVER converted to a calendar date, NEVER given a year or weekday the speaker didn't "
    "say, and never an unrelated date borrowed from elsewhere in the transcript. owner is "
    "only a person actually named, never a generic group like \"Team\"/\"Everyone\"; owner and "
    "due are null when not spoken."
)

_RULE_ACTION_ITEMS_SV = (
    "- actionItems: things still to do after the meeting. owner is the GRAMMATICAL SUBJECT "
    "of the task as spoken: \"jag\" means the speaker — use their own stated name, else "
    "\"jag\"; \"X ska\" means X. Never give the speaker's own task to someone else nearby. An "
    "already-arranged event (\"vi ska ha ett möte imorgon\") is NOT an action item — summary "
    "only. due is copied VERBATIM as spoken (e.g. \"om två veckor\", \"imorgon\") — NEVER "
    "converted to a calendar date, NEVER given a year or weekday the speaker didn't say, "
    "and never an unrelated date borrowed from elsewhere in the transcript. owner is only a "
    "person actually named, never a generic group like \"Team\"/\"Everyone\"; owner and due are "
    "null when not spoken."
)

_RULE_EVERY_ITEM_EN = (
    "- Every item is EITHER a decision OR an actionItem, never both or worded twice in each "
    "place (e.g. \"booked the meeting\" as a decision and \"book the meeting\" as an action "
    "item is still one item)."
)

_RULE_EVERY_ITEM_SV = (
    "- Every item is EITHER a decision OR an actionItem, never both or worded twice in each "
    "place (e.g. \"bokade mötet\" as a decision and \"boka mötet\" as an action item is still "
    "one item)."
)

_RULE_OPEN_QUESTIONS = (
    "- openQuestions: unresolved points or either/or options actually voiced, including a "
    "conditional the speaker is still weighing (see decisions). Never invent one. Empty array "
    "if none."
)

_RULE_NEVER_INVENT = (
    "- Never invent facts, owners, dates, or years absent from the transcript. Use empty arrays "
    "for empty sections. owner/due must be null, never a placeholder such as \"Not specified\", "
    "\"TBD\", \"N/A\", \"None\" or \"Unknown\"."
)

_EXPECTED_EN = "\n\n".join(
    [
        _INTRO,
        _SELF_NAMING_EN,
        _SPEECH_TO_TEXT,
        _RETURN_JSON,
        "\n".join(
            [
                "Rules:",
                _RULE_SPELLING,
                _RULE_SUMMARY,
                _RULE_DECISIONS_EN,
                _RULE_ACTION_ITEMS_EN,
                _RULE_EVERY_ITEM_EN,
                _RULE_OPEN_QUESTIONS,
                _RULE_NEVER_INVENT,
            ]
        ),
    ]
)

_EXPECTED_SV = "\n\n".join(
    [
        _INTRO,
        _SELF_NAMING_SV,
        _SPEECH_TO_TEXT,
        _RETURN_JSON,
        "\n".join(
            [
                "Rules:",
                _RULE_SPELLING,
                _RULE_SUMMARY,
                _RULE_DECISIONS_SV,
                _RULE_ACTION_ITEMS_SV,
                _RULE_EVERY_ITEM_SV,
                _RULE_OPEN_QUESTIONS,
                _RULE_NEVER_INVENT,
            ]
        ),
    ]
)


def test_unlabeled_is_byte_identical_to_the_previous_prompt() -> None:
    assert system_prompt("en") == _EXPECTED_EN


def test_unlabeled_swedish_is_byte_identical_to_the_previous_prompt() -> None:
    assert system_prompt("sv") == _EXPECTED_SV


def test_systemprompt_english_contains_no_swedish_example_literals() -> None:
    text = system_prompt("en")
    assert "vi bestämde" not in text
    assert "det var jag, Sebastian och Erik" not in text


def test_systemprompt_swedish_contains_no_english_example_literals() -> None:
    text = system_prompt("sv")
    assert "we decided" not in text
    assert "it was me, Sebastian, and Erik" not in text
    assert '"me"' not in text


def test_systemprompt_unsupported_language_falls_back_to_english_examples() -> None:
    assert system_prompt("fr") == _EXPECTED_EN
    assert system_prompt("id") == _EXPECTED_EN


def test_systemprompt_both_languages_mention_transcript_language_only_rule() -> None:
    marker = "Write every field, including owner and due, in the transcript's language only."
    for language in ("en", "sv"):
        assert marker in system_prompt(language)


def test_systemprompt_rules_block_stays_under_word_budget_per_language() -> None:
    # Mirrors `test_systemPrompt_rulesBlockStaysUnderWordBudgetPerLanguage`
    # (DiktaTests/DebriefPipelineTests.swift:1023-1034): the block from the
    # "Rules:" token (inclusive) through the end of the prompt, split on any
    # whitespace (Swift's `split(whereSeparator: isWhitespace)` ==
    # Python's default `str.split()`), must be <= 350 words.
    # en: 332 words, sv: 329 words (well under budget).
    for language in ("en", "sv"):
        prompt = system_prompt(language)
        rules_block = prompt[prompt.index("Rules:") :]
        word_count = len(rules_block.split())
        assert word_count <= 350, f"Rules block for {language} is {word_count} words, over budget"


def test_systemprompt_labeled_raises_not_implemented() -> None:
    with pytest.raises(NotImplementedError):
        system_prompt("en", labeled=True)


def test_user_prompt_format() -> None:
    assert user_prompt("hello there", "en") == "Transcript (language: en):\n\nhello there"
