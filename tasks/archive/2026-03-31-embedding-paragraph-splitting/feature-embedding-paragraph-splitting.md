# Feature: Embedding-Based Paragraph Splitting

## Introduction

The deterministic text formatter in Dikta uses transition-word heuristics (e.g. "by the way", "okay", "anyway") to detect topic shifts and insert paragraph breaks. This catches ~30-40% of topic shifts but fails on unmarked transitions — like a dictated message switching from work discussion to personal questions without an explicit marker word.

Research confirmed this is the ceiling for rules-based approaches (TextTiling, C99, LCseg all require 1000+ word documents). Prototype testing of sentence embedding models showed that **all-MiniLM-L12-v2** (33MB, 384-dim) reliably detects these unmarked topic shifts via cosine similarity depth scoring. It detected the critical "PM?" → "How's the family?" shift with depth 0.474, while Apple's built-in NLEmbedding and gte-small both missed it.

This feature adds MiniLM-L12 as a supplementary paragraph-splitting signal, running alongside the existing heuristics.

## Goals

- Detect unmarked topic shifts in dictated messages that the heuristic formatter misses
- Maintain zero-network, fully offline operation — model ships bundled in the app
- Keep formatting latency under 200ms for a typical 15-sentence message
- Preserve all existing formatter behavior — embeddings supplement, never override
- Cross-platform architecture: CoreML on macOS now, ONNX on Windows later (same model)

## User Stories

### US-001: Convert and bundle MiniLM-L12 model for CoreML
**Description:** As a developer, I want the all-MiniLM-L12-v2 model converted to CoreML format and bundled in the macOS app so that sentence embeddings can be computed locally without any network access.

**Acceptance Criteria:**
- [ ] When the app launches, no model download or network call is required for the embedding model
- [ ] The bundled CoreML model produces 384-dimensional sentence embeddings that match the Python reference implementation (cosine similarity > 0.99 for identical inputs)
- [ ] App bundle size increases by no more than 40MB from the embedded model

### US-002: Embedding-based paragraph splitter service
**Description:** As a user, I want the formatter to use sentence embeddings to detect topic shifts so that my dictated messages get paragraph breaks at natural topic boundaries, even when I don't use transition words.

**Acceptance Criteria:**
- [ ] When formatting "So we need to have a new meeting... PM? How's the family?...", a paragraph break appears between the work discussion and personal questions
- [ ] When formatting a single-topic message (pure work or pure personal), no spurious paragraph breaks are inserted
- [ ] When formatting the Test 1 message ("Hello, Reino! So, we have some work..."), the work→personal shift at "Okay, so how is life?" produces a paragraph break

### US-003: Integrate embedding splitter into StructuredTextFormatter
**Description:** As a user, I want embedding-based splitting to work seamlessly with the existing formatter so that I get the best of both approaches — heuristic transition words AND semantic topic detection.

**Acceptance Criteria:**
- [ ] When the embedding model detects a topic shift that heuristics miss, the paragraph break is inserted
- [ ] When heuristics already detect a break (via transition words), the embedding signal does not create duplicate or conflicting breaks
- [ ] All 203 existing formatter tests continue to pass with the embedding layer active

### US-004: Language-aware fallback and lazy loading
**Description:** As a user dictating in any of Dikta's 12 supported languages, I want formatting to work well regardless of whether the embedding model supports my language, and I don't want the model to slow down app startup.

**Acceptance Criteria:**
- [ ] When dictating in a MiniLM-supported language (English and major European languages), embedding-based splitting is used
- [ ] When dictating in an unsupported language, the formatter falls back to heuristic-only splitting with no error or degradation
- [ ] The embedding model loads on first format hotkey press, not at app startup — first-format latency stays under 500ms

## Functional Requirements

- FR-1: The system must convert all-MiniLM-L12-v2 from HuggingFace format to CoreML using coremltools, producing a `.mlpackage` or `.mlmodel` file
- FR-2: The system must compute cosine similarity between adjacent sentence embeddings and apply depth-score thresholding (TextTiling algorithm) to identify paragraph break points
- FR-3: The depth-score threshold must be calibrated against the existing test corpus — prototype testing suggests depth > 0.15-0.20 is the working range
- FR-4: The embedding splitter must be invoked from StructuredTextFormatter.analyze() as an additional check when heuristic Check D (paragraph splitting) finds only 1 group or misses likely breaks
- FR-5: The model must be lazy-loaded into memory on first use and cached for the app session lifetime
- FR-6: Language detection must use the existing `Language` enum to determine whether to use embeddings or fall back to heuristics

## Non-Goals

- Windows ONNX implementation (separate feature, same architecture)
- Fine-tuning or training a custom model — use pre-trained MiniLM-L12 as-is
- User-configurable threshold settings — depth threshold is hardcoded based on test results
- Model download at runtime — model ships bundled, no network needed
- Replacing the existing heuristic formatter — embeddings supplement it, not replace
- Supporting all 12 languages with embeddings — unsupported languages fall back to heuristics

## Technical Considerations

- **Model conversion pipeline:** Python coremltools converts the HuggingFace model to CoreML. This is a one-time build step, not runtime.
- **CoreML inference in Swift:** Use `MLModel` to load the `.mlpackage`, tokenize input sentences, run inference, and extract the embedding vectors. MiniLM uses a WordPiece tokenizer — need to bundle the vocabulary file or use a Swift tokenizer library.
- **Tokenization challenge:** CoreML handles the neural network but not tokenization. Options: (a) bundle a Swift WordPiece tokenizer, (b) use the tokenizer from swift-transformers (already a dependency via WhisperKit), (c) convert with tokenizer included in the CoreML pipeline.
- **Integration point:** The embedding splitter sits between sentence splitting and paragraph grouping in StructuredTextFormatter. It runs after splitSentences() and before the existing Check A-F analysis.
- **Memory:** The model is ~33MB on disk, ~50-80MB in memory. Lazy loading ensures this cost is only paid when formatting is actually used.
- **Existing dependency:** WhisperKit already pulls in swift-transformers which includes tokenizer support — may be reusable.

## Success Metrics

- The "PM?" → "How's the family?" topic shift (Test 2) is correctly detected
- All 4 prototype test cases produce correct paragraph breaks
- No regression in the existing 203 test suite
- Formatting latency stays under 200ms for 15 sentences (excluding first-load)
- App bundle size increase is under 40MB

## Open Questions

1. Can swift-transformers' tokenizer (already bundled via WhisperKit) handle MiniLM's WordPiece vocabulary, or do we need a separate tokenizer?
2. Should the depth threshold be a single global value or adaptive based on the number of sentences?
3. How should the embedding splitter interact with the MessageFormatter's 6-zone extraction — should embeddings run before or after zone extraction?
