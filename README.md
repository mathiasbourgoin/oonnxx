# Oonnxx

Oonnxx is an OCaml library for local multilingual E5 embeddings. It runs a model through ONNX Runtime's C API, tokenizes with an OCaml implementation of the model's SentencePiece Unigram vocabulary, mean-pools the hidden states, and returns L2-normalized vectors. It also offers cosine ranking, reciprocal rank fusion, and little-endian float32 blobs suitable for a SQLite `BLOB` column.

## Status

Local v0.1 candidate. Tested on Linux x86-64 with ONNX Runtime 1.23.2 and `intfloat/multilingual-e5-small`'s `model_O4.onnx` and `tokenizer.json`. The tokenizer matches the Hugging Face tokenizers implementation on the French and English cases in `test/test_oonnxx.ml`. The current normalizer implements Unicode NFKC and the whitespace behavior exercised by those cases; the model's complete precompiled normalization table is not yet decoded, so other scripts and unusual Unicode may differ. Validate new scripts and unusual Unicode before relying on exact token parity.

The library contains OCaml and a small C binding for ONNX Runtime. There is no C++, Python, Ollama, or GPU implementation in the product. Any future GPU code should use Sarek.

## Build

The package builds without ONNX Runtime installed. At run time, provide ONNX Runtime 1.23.2's shared library. Oonnxx loads `libonnxruntime.so` from the normal linker path, or the file named by `ONNXRUNTIME_LIBRARY`. The source includes ONNX Runtime's MIT-licensed C headers under `lib/vendor/` so opam can build the binding without system headers.

```sh
opam pin add oonnxx .
```

The opam package installs OCaml dependencies `yojson`, `uutf`, `uunf`, `caqti`, `caqti-driver-sqlite3`, and `eio`. ONNX Runtime is a runtime dependency; opam does not download a model or runtime binary. `Oonnxx.open_model` returns an error if the shared library is unavailable.

## Model assets

Download the matching files from the model author:

- `https://huggingface.co/intfloat/multilingual-e5-small/resolve/main/onnx/model_O4.onnx` (tested SHA-256 `4654c156f3e4171abc9c716cdb771bf9116455d15ac1aab364aeeede0e3205b0`)
- `https://huggingface.co/intfloat/multilingual-e5-small/resolve/main/tokenizer.json` (tested SHA-256 `0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39`)

The assets are intentionally outside the Git repository. Check their hashes when reproducing the tests, because the URLs point to a movable branch.

## Use

```ocaml
let engine = Oonnxx.open_model ~model:"model_O4.onnx" ~tokenizer:"tokenizer.json" in
let query = Oonnxx.embed_query engine "black cat" in
let passage = Oonnxx.embed_passage engine "un chat noir" in
let score = Oonnxx.cosine query passage in
let blob = Oonnxx.encode_f32le passage in
let restored = Oonnxx.decode_f32le blob in
ignore (score, restored)
```

`Oonnxx_caqti.attach ~model_id` takes the consumer's existing `Caqti_blocking.CONNECTION`, creates the `oonnxx_documents` and FTS5 tables, and provides `upsert`, `delete`, `search_fts`, `search_vector`, and `search_hybrid`. Use a stable ID incorporating the exact model and tokenizer hashes; a mismatched ID is refused on reopen. `search_vector` streams rows, keeping only the requested top results in memory; it still scans all stored vectors. Use `oonnxx.caqti` as a Dune library dependency.

For Session Mesh, use the existing history database connection, derive a stable document ID from each history chunk, and call `upsert` after the chunk transaction commits. Call `delete` when a chunk is removed. The adapter's tables are independent of the history schema, so it does not alter the history migration state. Its blocking connection must remain on the thread that created it, as required by Caqti's blocking API.

`Oonnxx_eio.embed_passages` runs independent embeddings on Eio domains with a caller-selected concurrency limit. Use `oonnxx.eio` as a Dune library dependency. Split large files into passages before calling it: one embedding input is limited to 16 KiB and at most 510 body tokens. This is CPU parallelism; it is not an ONNX batch tensor and makes no throughput claim without a workload measurement.

## Test

```sh
ONNXRUNTIME_LIBRARY=/path/to/libonnxruntime.so \
OONNXX_TEST_MODEL=/path/to/model_O4.onnx \
OONNXX_TEST_TOKENIZER=/path/to/tokenizer.json \
dune runtest
```

Without the two test asset variables, the vector math and blob tests run but the model integration test is skipped.
