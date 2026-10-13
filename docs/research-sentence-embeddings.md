# Research: Sentence Embeddings for Topic-Shift Detection in Dikta

> **Historical / retired for Format Selection (2026-10):** the formatter use case was removed. `SentenceEmbeddingService` remains active for Debrief semantic deduplication; this research is retained as engineering history.

**Date:** 2026-03-31
**Goal:** Evaluate options for computing sentence-level similarity to detect topic shifts in short dictated messages (5-15 sentences), fully offline on macOS.

---

## 1. Apple NLEmbedding (NaturalLanguage Framework)

### What it is
Built-in macOS/iOS API that ships with the OS. No model download, no extra dependency. Available since iOS 14 / macOS 11.

### API
```swift
import NaturalLanguage

let embedding = NLEmbedding.sentenceEmbedding(for: .english)!
let vector = embedding.vector(for: "Hello world")  // [Double] with 512 dimensions
let distance = embedding.distance(between: "sentence A", and: "sentence B", distanceType: .cosine)
```

### Key facts
- **Model size:** 0 MB additional (ships with macOS)
- **Vector dimensions:** 512
- **Speed:** Near-instant. No model loading. Processing 15 sentences would be <10ms.
- **Quality:** Decent for general similarity but NOT state-of-the-art. It is a static embedding model (not transformer-based), predating SBERT. Good enough for coarse topic-shift detection but weaker on nuanced semantic similarity.
- **Distance types:** Cosine built-in via `NLDistanceType.cosine`

### Language support (CRITICAL LIMITATION)
Sentence embeddings supported for only **7 languages**:
- English, Spanish, French, Italian, German, Portuguese, Simplified Chinese

**NOT supported (but Dikta supports these):**
- Finnish, Norwegian, Danish, Dutch, Indonesian, Japanese, Swedish

This means NLEmbedding covers only 7 of Dikta's 12 languages. For unsupported languages, `NLEmbedding.sentenceEmbedding(for:)` returns `nil`.

### Verdict
Best option IF you only need EN/ES/FR/DE/IT/PT. Zero dependencies, zero model size, fastest possible inference. But the language gap is a dealbreaker for full coverage.

---

## 2. NLContextualEmbedding (macOS 14+ / iOS 17+)

### What it is
Apple's newer transformer-based (BERT) contextual embedding, introduced at WWDC 2023. Produces context-aware token embeddings (not sentence-level directly).

### Key facts
- **Architecture:** BERT-based, 3 model variants depending on language script
- **Vector dimensions:** 512 per token
- **Multilingual:** Supports up to 27 languages across 3 scripts (Latin, CJK, etc.)
- **Sentence embedding:** Does NOT produce a single sentence vector directly. Returns per-token vectors. You must pool them (mean pooling) yourself.
- **Model download:** May require on-demand asset download (unlike NLEmbedding which is always present)
- **Minimum OS:** macOS 14 Sonoma / iOS 17

### Verdict
Better language coverage, higher quality embeddings. But: requires macOS 14+, needs manual mean-pooling for sentence vectors, and model may need download. More complex integration for marginal benefit in a topic-shift use case.

---

## 3. SimilaritySearchKit (Swift Package)

### What it is
Open-source Swift package by Zach Nagengast providing on-device text embeddings and semantic search. Ships pre-converted CoreML models. 522 stars on GitHub.

**URL:** https://github.com/ZachNagengast/similarity-search-kit

### Available models

| Model | Use Case | Size | Source |
|-------|----------|------|--------|
| `NaturalLanguage` | Text similarity | Built-in (0 MB) | Apple NLEmbedding wrapper |
| `MiniLMAll` | Text similarity | **46 MB** | all-MiniLM-L6-v2 (CoreML) |
| `MiniLMMultiQA` | Q&A search | **46 MB** | multi-qa-MiniLM-L6 (CoreML) |
| `Distilbert` | Q&A search | **86 MB** (quantized) | msmarco-distilbert |

### Key facts — MiniLMAll (best candidate)
- **Model size:** 46 MB (CoreML-converted, pre-packaged in SPM)
- **Vector dimensions:** 384
- **Speed:** ~50 sentences/sec on CPU. 15 sentences in ~300ms.
- **Quality:** all-MiniLM-L6-v2 is the most popular sentence embedding model. Strong performance on STS benchmarks. Significantly better than NLEmbedding for semantic similarity.
- **Language support:** English-only (trained on English data). Works somewhat on other Latin-script languages but not reliably for Finnish, Japanese, etc.
- **Integration:** Add SPM dependency, select `SimilaritySearchKitMiniLMAll` target. CoreML model bundled automatically.

### Verdict
Excellent quality and easy integration. Model size (46 MB) is acceptable. But English-centric — same multilingual gap as NLEmbedding.

---

## 4. swift-embeddings (Swift Package)

### What it is
Newer Swift package by Jan Krukowski. Runs HuggingFace embedding models locally using MLTensor. More flexible model loading than SimilaritySearchKit.

**URL:** https://github.com/jkrukowski/swift-embeddings

### Key facts
- **Supported models:** all-MiniLM-L6-v2, msmarco-bert-base, gte-base, bert-base-uncased, and any compatible HuggingFace model
- **Model loading:** Downloads from HuggingFace Hub or loads local weights
- **Framework:** Uses MLTensor (Apple's newer ML compute API)
- **Size:** ~22M parameters for MiniLM → ~46MB on disk
- **Stars:** 117, 25 releases, actively maintained

### Verdict
More flexible than SimilaritySearchKit for model choice. Could use a multilingual model (e.g., paraphrase-multilingual-MiniLM-L12-v2) if one is converted. But requires more setup and the model must be bundled or downloaded.

---

## 5. Multilingual Model Options

For full 12-language coverage, you would need a multilingual sentence embedding model:

| Model | Parameters | Size | Languages | Dimensions |
|-------|-----------|------|-----------|------------|
| paraphrase-multilingual-MiniLM-L12-v2 | 118M | ~470MB | 50+ languages | 384 |
| multilingual-e5-small | 118M | ~470MB | 100+ languages | 384 |
| LaBSE | 471M | ~1.8GB | 109 languages | 768 |

**Problem:** All multilingual models are 400MB+, far exceeding the 50MB target. There is no multilingual sentence embedding model under 100MB that provides decent quality.

---

## 6. Topic Segmentation Algorithm

### The approach (Embedding-Enhanced TextTiling)
1. Compute sentence embedding for each sentence (S1, S2, ... Sn)
2. Calculate cosine similarity between adjacent pairs: sim(S1,S2), sim(S2,S3), ...
3. Compute "depth scores" at each gap: how much similarity drops relative to surrounding peaks
4. Where depth score exceeds threshold, insert paragraph break

### Threshold guidance
- **Raw cosine similarity threshold:** Typically 0.3-0.6 for topic boundary detection, but varies heavily by model and domain
- **Depth-score method (preferred):** Instead of a fixed threshold, compute local depth at each point as: `depth(i) = (peak_left - sim(i)) + (peak_right - sim(i))`. Then threshold on depth scores. This is more robust than raw similarity thresholds.
- **Smoothing:** Apply a small sliding window (size 2-3) to smooth similarity scores before detecting valleys
- **Research finding:** The optimal threshold is domain-specific and should be tuned on representative data. For short dictated messages, a depth threshold of 0.1-0.3 (on cosine similarity scale) is a reasonable starting point.

### State of the art
The 2024 survey "Recent Trends in Linear Text Segmentation" confirms that SBERT-based TextTiling variants are the standard approach for unsupervised topic segmentation. The method is well-established and works reliably for the use case described.

---

## 7. Feasibility Assessment & Recommendation

### Option A: NLEmbedding (RECOMMENDED for v1.2)
- **Pros:** Zero dependencies, zero model size, instant speed, dead-simple API, ships with macOS
- **Cons:** Only 7 languages supported (covers EN/ES/FR/DE/IT/PT + ZH)
- **Mitigation:** For unsupported languages (FI/NO/DA/NL/ID/JA/SV), fall back to the existing heuristic-based paragraph splitter
- **Effort:** Minimal — ~50 lines of Swift code
- **Risk:** Low

### Option B: SimilaritySearchKit + MiniLMAll
- **Pros:** Better embedding quality, easy SPM integration, pre-converted CoreML model
- **Cons:** +46MB app size, English-centric, slower than NLEmbedding
- **Effort:** Medium — add SPM dependency, integrate model loading
- **Risk:** Low-medium (model bundling in release build needs testing)

### Option C: swift-embeddings + Multilingual Model
- **Pros:** Full language coverage possible
- **Cons:** 400MB+ model size (dealbreaker), complex setup, model download/bundling
- **Effort:** High
- **Risk:** High (model size alone disqualifies this)

### Option D: Hybrid — NLEmbedding + Heuristic Fallback (STRONGEST RECOMMENDATION)
Use NLEmbedding for the 7 supported languages where it works. For the remaining 5 languages, keep the existing StructuredTextFormatter heuristic rules. This gives:
- Zero additional dependencies
- Zero additional model size
- Best possible speed
- Good-enough quality for topic-shift detection in short messages
- Graceful degradation for unsupported languages

The embedding approach and the heuristic approach can share the same paragraph-break insertion points — they just use different signals to determine where breaks go.

---

## Sources

- [NLEmbedding — Apple Developer Documentation](https://developer.apple.com/documentation/naturallanguage/nlembedding)
- [sentenceEmbedding(for:) — Apple Developer Documentation](https://developer.apple.com/documentation/naturallanguage/nlembedding/sentenceembedding(for:))
- [NLContextualEmbedding — Apple Developer Documentation](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding)
- [Explore Natural Language Multilingual Models — WWDC23](https://developer.apple.com/videos/play/wwdc2023/10042/)
- [Natural Language Framework: Sentence Embedding with Swift — Mark Brownsword](https://markbrownsword.com/2020/12/23/natural-language-framework-sentence-embedding-with-swift/)
- [SimilaritySearchKit — GitHub](https://github.com/ZachNagengast/similarity-search-kit)
- [swift-embeddings — GitHub](https://github.com/jkrukowski/swift-embeddings)
- [all-MiniLM-L6-v2 — HuggingFace](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)
- [Recent Trends in Linear Text Segmentation — arXiv 2024](https://arxiv.org/html/2411.16613v1)
- [Comparing Neural Sentence Encoders for Topic Segmentation — PeerJ 2023](https://pmc.ncbi.nlm.nih.gov/articles/PMC10702997/)
- [textsplit — Segment Documents Using Word Embeddings](https://github.com/chschock/textsplit)
- [Sentence-BERT: Sentence Embeddings using Siamese BERT-Networks](https://ar5iv.labs.arxiv.org/html/1908.10084)
