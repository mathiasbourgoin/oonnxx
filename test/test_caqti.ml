let ok = function Ok value -> value | Error error -> failwith error
let check condition message = if not condition then failwith message

let () =
  let path = Filename.temp_file "oonnxx-caqti-" ".sqlite" in
  Fun.protect ~finally:(fun () ->
    try Sys.remove path with Sys_error _ -> ()) (fun () ->
      let uri = Uri.make ~scheme:"sqlite3" ~path () in
      let conn = Caqti_blocking.connect uri |> Result.map_error Caqti_error.show |> ok in
      let (module C : Caqti_blocking.CONNECTION) = conn in
      Fun.protect ~finally:(fun () -> C.disconnect ()) (fun () ->
        let db = Oonnxx_caqti.attach ~model_id:"e5-test-v1" conn |> ok in
        Oonnxx_caqti.upsert db ~id:"cat" ~text:"chat noir" ~vector:[| 1.; 0. |] |> ok;
        Oonnxx_caqti.upsert db ~id:"db" ~text:"schema database" ~vector:[| 0.; 1. |] |> ok;
        (match Oonnxx_caqti.upsert db ~id:"wrong" ~text:"wrong dimension" ~vector:[| 1.; 0.; 0. |] with
         | Error _ -> ()
         | Ok () -> failwith "mixed dimensions accepted");
        (match Oonnxx_caqti.search_vector db ~query:[| 1.; 0.; 0. |] ~limit:2 with
         | Error _ -> ()
         | Ok _ -> failwith "wrong query dimension accepted");
        let fts = Oonnxx_caqti.search_fts db ~query:"chat" ~limit:5 |> ok in
        check (fts = [ "cat" ]) "FTS insertion";
        let vector = Oonnxx_caqti.search_vector db ~query:[| 1.; 0. |] ~limit:2 |> ok in
        check (fst (List.hd vector) = "cat") "vector ranking";
        let hybrid = Oonnxx_caqti.search_hybrid db ~text:"chat" ~vector:[| 1.; 0. |] ~limit:2 |> ok in
        check (fst (List.hd hybrid) = "cat") "hybrid ranking";
        let punctuation = Oonnxx_caqti.search_hybrid db ~text:"chat?" ~vector:[| 1.; 0. |] ~limit:2 |> ok in
        check (fst (List.hd punctuation) = "cat") "hybrid punctuation";
        (match Oonnxx_caqti.attach ~model_id:"other-model" conn with
         | Error _ -> ()
         | Ok _ -> failwith "model mismatch accepted");
        Oonnxx_caqti.upsert db ~id:"cat" ~text:"black feline" ~vector:[| 0.5; 0.5 |] |> ok;
        check (Oonnxx_caqti.search_fts db ~query:"chat" ~limit:5 |> ok = [])
          "FTS update removes old terms";
        Oonnxx_caqti.delete db ~id:"db" |> ok;
        check (Oonnxx_caqti.search_fts db ~query:"database" ~limit:5 |> ok = [])
          "FTS deletion"))
