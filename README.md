# Oonnxx

Oonnxx helps OCaml applications build **semantic indexes in SQLite**: store text passages with their embeddings, then retrieve passages by meaning, by keyword, or with both rankings combined. A query in English can retrieve a relevant passage in French. The library computes multilingual E5 embeddings locally through ONNX Runtime and connects directly to an existing Caqti SQLite connection.

## Install and supply a model

Oonnxx currently supports Linux and builds without ONNX Runtime installed:

```sh
opam pin add oonnxx .
```

At run time, supply ONNX Runtime 1.23.2's `libonnxruntime.so` on the linker path or set `ONNXRUNTIME_LIBRARY` to its path. Also download these matching files from the model author:

- [`model_O4.onnx`](https://huggingface.co/intfloat/multilingual-e5-small/resolve/main/onnx/model_O4.onnx) — tested SHA-256 `4654c156f3e4171abc9c716cdb771bf9116455d15ac1aab364aeeede0e3205b0`
- [`tokenizer.json`](https://huggingface.co/intfloat/multilingual-e5-small/resolve/main/tokenizer.json) — tested SHA-256 `0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39`

The model and runtime binaries are supplied separately; opam does not download them. Check the asset hashes because the URLs follow a movable branch. `Oonnxx.open_model` raises an exception if it cannot load the model, tokenizer, or runtime.

## Index passages and search

This example assumes an existing `Caqti_blocking.CONNECTION` to SQLite and the model files at the paths shown. Add `oonnxx`, `oonnxx.caqti`, and your Caqti SQLite driver to the application's Dune dependencies.

```ocaml
let engine =
  Oonnxx.open_model ~model:"model_O4.onnx" ~tokenizer:"tokenizer.json"

let index =
  Oonnxx_caqti.attach
    ~model_id:"e5-small-o4:<model-sha256>:<tokenizer-sha256>" conn
  |> Result.get_ok

let () =
  Oonnxx_caqti.upsert index ~id:"passage-1" ~text:"un chat noir"
    ~vector:(Oonnxx.embed_passage engine "un chat noir")
  |> Result.get_ok

let matches =
  Oonnxx_caqti.search_hybrid index ~text:"black cat"
    ~vector:(Oonnxx.embed_query engine "black cat") ~limit:10
  |> Result.get_ok
(* matches : (passage_id * fused_score) list *)
```

Replace the placeholders in `model_id` with the hashes of the exact model and tokenizer files used to create the index. The adapter records this ID and the vector dimension, and refuses to mix incompatible embeddings. `upsert` updates both the stored vector and the SQLite FTS5 text index; `delete` removes both. The caller owns and closes the Caqti connection.

`search_vector` ranks by cosine similarity; `search_fts` accepts SQLite FTS5 query syntax; `search_hybrid` treats its text as literal search terms and combines keyword and vector rankings with reciprocal rank fusion. The returned scores from the three search methods have different meanings and should not be compared across methods. The adapter uses its own tables and does not change other application tables.

For large inputs, split files into passages and give each passage a stable ID. Inputs above 16 KiB are rejected, and tokenization keeps at most 510 body tokens per passage. `Oonnxx_eio.embed_passages` embeds independent passages on Eio domains with a caller-selected concurrency limit and preserves input order; add `oonnxx.eio` to the Dune dependencies.

## Current limits

Version 0.1.0 was tested on Linux x86-64 with ONNX Runtime 1.23.2 and the model files above. The tokenizer matches the Hugging Face implementation on the French and English cases in `test/test_oonnxx.ml`. It implements Unicode NFKC and the whitespace behavior exercised by those cases, but does not decode the model's complete precompiled normalization table. Validate other scripts and unusual Unicode before relying on exact token parity.

Vector search scans every stored vector, retaining only the requested best results in memory. The Eio helper provides CPU parallelism across passages; it does not batch inputs into one ONNX tensor. Measure throughput with your workload before choosing passage size and concurrency.

The implementation uses OCaml and a small C binding to ONNX Runtime's C API. Its MIT-licensed C headers are included under `lib/vendor/` so package builds need no system ONNX Runtime headers.

## License

Oonnxx is licensed under the MIT License. See [LICENSE](LICENSE). The vendored ONNX Runtime C headers retain their own [MIT license notice](lib/vendor/ONNXRUNTIME-LICENSE).

## Run the tests

```sh
ONNXRUNTIME_LIBRARY=/path/to/libonnxruntime.so \
OONNXX_TEST_MODEL=/path/to/model_O4.onnx \
OONNXX_TEST_TOKENIZER=/path/to/tokenizer.json \
dune runtest
```

Without the two test asset variables, the vector math and blob tests run but the model integration test is skipped.
