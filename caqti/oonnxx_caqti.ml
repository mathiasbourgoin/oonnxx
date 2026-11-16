open Caqti_type.Std
open Caqti_request.Infix

type connection = (module Caqti_blocking.CONNECTION)
type t = { conn : connection }

let ( let* ) = Result.bind
let lift result = Result.map_error Caqti_error.show result
let guard f =
  try f () with
  | (Out_of_memory | Stack_overflow) as e -> raise e
  | e -> Error (Printexc.to_string e)

let ddl sql =
  Caqti_request.create ~oneshot:true unit unit Caqti_mult.zero (fun _ -> Caqti_query.L sql)

let schema =
  [ ddl "CREATE TABLE IF NOT EXISTS oonnxx_documents (id TEXT PRIMARY KEY, text TEXT NOT NULL, embedding BLOB NOT NULL, dimension INTEGER NOT NULL)";
    ddl "CREATE VIRTUAL TABLE IF NOT EXISTS oonnxx_fts USING fts5(text, content='oonnxx_documents', content_rowid='rowid', tokenize='unicode61 remove_diacritics 1')";
    ddl "CREATE TRIGGER IF NOT EXISTS oonnxx_ai AFTER INSERT ON oonnxx_documents BEGIN INSERT INTO oonnxx_fts(rowid, text) VALUES (new.rowid, new.text); END";
    ddl "CREATE TRIGGER IF NOT EXISTS oonnxx_ad AFTER DELETE ON oonnxx_documents BEGIN INSERT INTO oonnxx_fts(oonnxx_fts, rowid, text) VALUES ('delete', old.rowid, old.text); END";
    ddl "CREATE TRIGGER IF NOT EXISTS oonnxx_au AFTER UPDATE ON oonnxx_documents BEGIN INSERT INTO oonnxx_fts(oonnxx_fts, rowid, text) VALUES ('delete', old.rowid, old.text); INSERT INTO oonnxx_fts(rowid, text) VALUES (new.rowid, new.text); END" ]

let attach conn =
  guard (fun () ->
    let (module C : Caqti_blocking.CONNECTION) = conn in
    let* () =
      List.fold_left (fun state request ->
        let* () = state in
        lift (C.exec request ())) (Ok ()) schema in
    Ok { conn })

let upsert_request =
  (t4 string string octets int ->. unit)
    "INSERT INTO oonnxx_documents(id, text, embedding, dimension) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET text=excluded.text, embedding=excluded.embedding, dimension=excluded.dimension"

let delete_request =
  (string ->. unit) "DELETE FROM oonnxx_documents WHERE id = ?"

let fts_request =
  (t2 string int ->* string)
    "SELECT d.id FROM oonnxx_fts JOIN oonnxx_documents d ON d.rowid=oonnxx_fts.rowid WHERE oonnxx_fts MATCH ? ORDER BY bm25(oonnxx_fts), d.id LIMIT ?"

let vectors_request =
  (unit ->* t3 string octets int)
    "SELECT id, embedding, dimension FROM oonnxx_documents ORDER BY id"

let validate_vector vector =
  if Array.length vector = 0 then invalid_arg "Oonnxx_caqti: empty vector";
  Array.iter (fun value ->
    if not (Float.is_finite value) then invalid_arg "Oonnxx_caqti: nonfinite vector") vector;
  ignore (Oonnxx.cosine vector vector)

let upsert t ~id ~text ~vector =
  guard (fun () ->
    if id = "" then invalid_arg "Oonnxx_caqti: empty id";
    validate_vector vector;
    let (module C : Caqti_blocking.CONNECTION) = t.conn in
    lift (C.exec upsert_request (id, text, Oonnxx.encode_f32le vector, Array.length vector)))

let delete t ~id =
  guard (fun () ->
    let (module C : Caqti_blocking.CONNECTION) = t.conn in
    lift (C.exec delete_request id))

let search_fts t ~query ~limit =
  guard (fun () ->
    if limit <= 0 then invalid_arg "Oonnxx_caqti: limit must be positive";
    let (module C : Caqti_blocking.CONNECTION) = t.conn in
    lift (C.collect_list fts_request (query, limit)))

let search_vector t ~query ~limit =
  guard (fun () ->
    if limit <= 0 then invalid_arg "Oonnxx_caqti: limit must be positive";
    validate_vector query;
    let (module C : Caqti_blocking.CONNECTION) = t.conn in
    let add (id, blob, dimension) best =
      let vector = Oonnxx.decode_f32le blob in
      if Array.length vector <> dimension then
        failwith ("Oonnxx_caqti: corrupt vector for " ^ id);
      if dimension <> Array.length query then best
      else
        let score = Oonnxx.cosine query vector in
        (id, score) :: best
        |> List.sort (fun (a, x) (b, y) ->
             let order = Float.compare y x in
             if order = 0 then String.compare a b else order)
        |> List.filteri (fun index _ -> index < limit) in
    lift (C.fold vectors_request add () []))

let search_hybrid t ~text ~vector ~limit =
  if limit <= 0 then Error "Oonnxx_caqti: limit must be positive"
  else
    let candidates = if limit > 3333 then 10000 else limit * 3 in
    let* fts = search_fts t ~query:text ~limit:candidates in
    let* semantic = search_vector t ~query:vector ~limit:candidates in
    let ids = List.map fst semantic in
    Ok (Oonnxx.reciprocal_rank_fusion [ fts; ids ]
        |> List.filteri (fun index _ -> index < limit))
