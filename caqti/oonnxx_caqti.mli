(** SQLite persistence and hybrid search through Caqti's blocking API. *)

type t

val attach : (module Caqti_blocking.CONNECTION) -> (t, string) result
(** Create the Oonnxx tables and FTS5 index on an existing SQLite connection.
    The caller retains ownership of the connection. *)

val upsert : t -> id:string -> text:string -> vector:float array -> (unit, string) result
val delete : t -> id:string -> (unit, string) result

val search_fts : t -> query:string -> limit:int -> (string list, string) result
(** Search text with SQLite FTS5 query syntax. *)

val search_vector : t -> query:float array -> limit:int -> ((string * float) list, string) result
(** Stream stored vectors and keep the best [limit] cosine scores. *)

val search_hybrid :
  t -> text:string -> vector:float array -> limit:int ->
  ((string * float) list, string) result
(** Combine the FTS5 and vector rankings with reciprocal rank fusion. *)
