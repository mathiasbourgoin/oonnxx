type t = Oonnxx_sqlite3.t

let raw_db (module C : Caqti_blocking.CONNECTION) =
  match C.driver_connection with
  | Some (Caqti_driver_sqlite3.Driver_connection db) -> Ok db
  | _ -> Error "Oonnxx_caqti: expected the Caqti SQLite3 driver"

let attach ~model_id conn =
  match raw_db conn with
  | Error _ as error -> error
  | Ok db -> Oonnxx_sqlite3.attach ~model_id db

let open_readonly ~model_id conn =
  match raw_db conn with
  | Error _ as error -> error
  | Ok db -> Oonnxx_sqlite3.open_readonly ~model_id db

let upsert = Oonnxx_sqlite3.upsert
let upsert_many = Oonnxx_sqlite3.upsert_many
let delete = Oonnxx_sqlite3.delete
let search_fts = Oonnxx_sqlite3.search_fts
let literal_fts_query = Oonnxx_sqlite3.literal_fts_query
let search_vector = Oonnxx_sqlite3.search_vector
let rebuild_ann = Oonnxx_sqlite3.rebuild_ann
let search_hybrid = Oonnxx_sqlite3.search_hybrid
