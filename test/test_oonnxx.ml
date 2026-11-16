let check condition message = if not condition then failwith message

let () =
  let a = [| 1.; 0. |] and b = [| 0.; 1. |] in
  check (Oonnxx.cosine a a > 0.9999) "identity cosine";
  check (abs_float (Oonnxx.cosine a b) < 0.0001) "orthogonal cosine";
  let ranked = Oonnxx.rank ~query:a [ "b", b; "a", a ] in
  check (fst (List.hd ranked) = "a") "vector ranking";
  let fused = Oonnxx.reciprocal_rank_fusion [ [ "a"; "b" ]; [ "b"; "c" ] ] in
  check (fst (List.hd fused) = "b") "rank fusion";
  let blob = Oonnxx.encode_f32le [| 1.; -0.5; 0. |] in
  check (Oonnxx.decode_f32le blob = [| 1.; -0.5; 0. |]) "f32 blob round-trip";
  match Sys.getenv_opt "OONNXX_TEST_MODEL", Sys.getenv_opt "OONNXX_TEST_TOKENIZER" with
  | Some model, Some tokenizer ->
      let engine = Oonnxx.open_model ~model ~tokenizer in
      let ids = Oonnxx.tokenize engine "query: chat noir" in
      check (ids.(0) = 0 && ids.(Array.length ids - 1) = 2) "E5 special tokens";
      check (ids = [| 0; 41; 1294; 12; 3245; 86494; 2 |])
        "E5 French tokenization matches SentencePiece";
      List.iter (fun (text, expected) ->
        let actual = Oonnxx.tokenize engine text in
        if actual <> expected then
          failwith (Printf.sprintf "token mismatch for %S: got %s" text
            (String.concat "," (List.map string_of_int (Array.to_list actual)))))
        [ "query: black cat", [| 0; 41; 1294; 12; 22556; 7515; 2 |];
          "passage: un chat noir", [| 0; 46692; 12; 51; 3245; 86494; 2 |];
          "query: Où est l’entrée ?", [| 0; 41; 1294; 12; 180; 8612; 437; 96; 26; 66989; 705; 2 |];
          "query: café\tnoir", [| 0; 41; 1294; 12; 26216; 86494; 2 |];
          "query:  déjà   vu  ", [| 0; 41; 1294; 12; 15154; 13946; 6; 2 |];
          "query: naïve façade", [| 0; 41; 1294; 12; 24; 9392; 272; 65335; 112; 2 |];
          "query: 🚀 search", [| 0; 41; 1294; 12; 6; 247206; 33938; 2 |] ];
      let query = Oonnxx.embed_query engine "black cat" in
      let related = Oonnxx.embed_passage engine "un chat noir" in
      let unrelated = Oonnxx.embed_passage engine "database schema migration" in
      check (Array.length query = 384) "E5 embedding dimensions";
      check (Oonnxx.cosine query related > Oonnxx.cosine query unrelated)
        "English-to-French semantic ranking"
  | _ -> ()
