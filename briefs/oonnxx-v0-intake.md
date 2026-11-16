# Intake Brief — oonnxx-v0

**Date:** 2026-11-16
**Status: VALIDATED**
**Type:** feature
**Trust boundary:** no

## Goal

Create an OCaml library named Oonnxx that computes local French and English embeddings with a multilingual E5 ONNX model and provides vector retrieval primitives for indexed passages.

## Scope Boundary

- Keep integration with consumers outside this library.
- No Ollama or Python runtime dependency.
- The model files remain external assets supplied by the caller.

## Relevant Files

| File | Role | Key snippet |
|---|---|---|
| `lib/oonnxx.mli` | Public API | `val embed_query` |
| `lib/onnx_stubs.c` | ONNX Runtime binding | `OrtGetApiBase` |
| `lib/tokenizer.ml` | Pure OCaml E5 tokenization | `let encode` |
| `caqti/oonnxx_caqti.ml` | SQLite storage and hybrid search | `let search_hybrid` |
| `eio/oonnxx_eio.ml` | CPU parallel embedding | `let embed_passages` |

## Architecture Notes

Use the official ONNX Runtime C API through a small OCaml stub and implement E5's SentencePiece Unigram tokenizer in OCaml. Keep model/tokenizer binaries out of git. Model inputs are `input_ids`, `attention_mask`, and `token_type_ids`; mean-pool the last hidden state and normalize. A Caqti blocking adapter owns the SQLite schema and FTS5 triggers. Eio domains provide bounded CPU parallelism.

## Quality Gates

```bash
dune build
dune runtest
```

## Open Questions

_(empty)_
