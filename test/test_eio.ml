let () =
  match Sys.getenv_opt "OONNXX_TEST_MODEL", Sys.getenv_opt "OONNXX_TEST_TOKENIZER" with
  | Some model, Some tokenizer ->
      let engine = Oonnxx.open_model ~model ~tokenizer in
      let texts = [ "un chat noir"; "database schema"; "a black cat" ] in
      let serial = List.map (Oonnxx.embed_passage engine) texts in
      let parallel =
        Eio_main.run (fun env ->
          Oonnxx_eio.embed_passages
            ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~max_fibers:2 engine texts) in
      List.iter2 (fun a b ->
        if Oonnxx.cosine a b < 0.99999 then failwith "parallel embedding differs")
        serial parallel
  | _ -> ()
