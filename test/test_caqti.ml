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
        Oonnxx_caqti.upsert db ~id:"long" ~text:"long vector"
          ~vector:[| 10.; 0. |] |> ok;
        let before_training = Oonnxx_caqti.search_vector db
          ~query:[| 1.; 0. |] ~limit:3 |> ok in
        check (abs_float (List.assoc "long" before_training -. 1.) < 0.000001)
          "untrained search uses cosine";
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
          "FTS deletion";
        for i = 1 to 16 do
          let x = float i /. 16. in
          Oonnxx_caqti.upsert db ~id:("sample-" ^ string_of_int i)
            ~text:"sample" ~vector:[| x; 1. -. x |] |> ok
        done;
        Oonnxx_caqti.rebuild_ann db ~nbucket:2 ~training_limit:16 |> ok;
        let approx = Oonnxx_caqti.search_vector db ~query:[| 1.; 0. |] ~limit:3 |> ok in
        let exact = Oonnxx_caqti.search_vector ~exact:true db ~query:[| 1.; 0. |] ~limit:3 |> ok in
        check (List.length approx = 3) "ANN result count";
        check (List.length exact = 3) "exact result count";
        check (List.mem (fst (List.hd approx)) (List.map fst exact)) "ANN nearest neighbor";
        Oonnxx_caqti.delete db ~id:"sample-16" |> ok;
        let after_delete = Oonnxx_caqti.search_vector db ~query:[| 1.; 0. |] ~limit:3 |> ok in
        check (not (List.mem_assoc "sample-16" after_delete)) "ANN incremental delete");
      let reopened = Caqti_blocking.connect uri |> Result.map_error Caqti_error.show |> ok in
      let (module C2 : Caqti_blocking.CONNECTION) = reopened in
      Fun.protect ~finally:(fun () -> C2.disconnect ()) (fun () ->
        let db = Oonnxx_caqti.attach ~model_id:"e5-test-v1" reopened |> ok in
        let after_reopen = Oonnxx_caqti.search_vector db ~query:[| 1.; 0. |] ~limit:3 |> ok in
        check (List.length after_reopen = 3) "ANN persists across reopen");
      let raw = Sqlite3.db_open path in
      Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close raw)) (fun () ->
        let index = Oonnxx_sqlite3.attach ~model_id:"e5-test-v1" raw |> ok in
        check (Sqlite3.exec raw "BEGIN IMMEDIATE" = Sqlite3.Rc.OK) "outer transaction begins";
        ignore (Oonnxx_sqlite3.attach ~model_id:"e5-test-v1" raw |> ok);
        Oonnxx_sqlite3.upsert index ~id:"rolled-back" ~text:"temporary"
          ~vector:[| 0.8; 0.2 |] |> ok;
        Oonnxx_sqlite3.rebuild_ann index ~nbucket:2 ~training_limit:16 |> ok;
        check (Sqlite3.exec raw "ROLLBACK" = Sqlite3.Rc.OK) "outer transaction rolls back";
        check (not (List.mem_assoc "rolled-back"
          (Oonnxx_sqlite3.search_vector index ~query:[| 1.; 0. |] ~limit:20 |> ok)))
          "nested upsert follows caller rollback";
        Oonnxx_sqlite3.upsert index ~id:"raw" ~text:"raw sqlite connection"
          ~vector:[| 0.8; 0.2 |] |> ok;
        check (List.mem_assoc "raw"
          (Oonnxx_sqlite3.search_vector index ~query:[| 1.; 0. |] ~limit:5 |> ok))
          "raw SQLite connection writes");
      let raw_readonly = Sqlite3.db_open ~mode:`READONLY path in
      Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close raw_readonly)) (fun () ->
        let index = Oonnxx_sqlite3.open_readonly ~model_id:"e5-test-v1" raw_readonly |> ok in
        check (List.length (Oonnxx_sqlite3.search_vector index
          ~query:[| 1.; 0. |] ~limit:3 |> ok) = 3) "raw read-only search";
        match Oonnxx_sqlite3.upsert index ~id:"forbidden" ~text:"x"
          ~vector:[| 1.; 0. |] with
        | Error _ -> ()
        | Ok () -> failwith "read-only upsert accepted"));
  let legacy_path = Filename.temp_file "oonnxx-legacy-" ".sqlite" in
  Fun.protect ~finally:(fun () -> try Sys.remove legacy_path with Sys_error _ -> ()) (fun () ->
    let raw = Sqlite3.db_open legacy_path in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close raw)) (fun () ->
      let legacy =
        "CREATE TABLE oonnxx_metadata(name TEXT PRIMARY KEY,value TEXT NOT NULL);" ^
        "INSERT INTO oonnxx_metadata VALUES('model_id','legacy-model'),('dimension','2');" ^
        "CREATE TABLE oonnxx_documents(id TEXT PRIMARY KEY,text TEXT NOT NULL,embedding BLOB NOT NULL,dimension INTEGER NOT NULL);" ^
        "CREATE VIRTUAL TABLE oonnxx_fts USING fts5(text,content='oonnxx_documents',content_rowid='rowid');" ^
        "CREATE TRIGGER oonnxx_ai AFTER INSERT ON oonnxx_documents BEGIN INSERT INTO oonnxx_fts(rowid,text) VALUES(new.rowid,new.text); END;" ^
        "INSERT INTO oonnxx_documents VALUES('old','legacy passage',x'0000803f00000000',2);" in
      check (Sqlite3.exec raw legacy = Sqlite3.Rc.OK) "create legacy database";
      let index = Oonnxx_sqlite3.attach ~model_id:"legacy-model" raw |> ok in
      check (List.mem_assoc "old" (Oonnxx_sqlite3.search_vector index
        ~query:[| 1.; 0. |] ~limit:2 |> ok)) "legacy vector backfill";
      Oonnxx_sqlite3.upsert index ~id:"new" ~text:"new passage"
        ~vector:[| 0.; 1. |] |> ok;
      check (List.mem_assoc "new" (Oonnxx_sqlite3.search_vector index
        ~query:[| 0.; 1. |] ~limit:2 |> ok)) "legacy trigger migration"))
