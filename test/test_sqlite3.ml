let ok = function Ok value -> value | Error error -> failwith error
let check condition message = if not condition then failwith message

let with_index f =
  let db = Sqlite3.db_open ":memory:" in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db)) (fun () ->
    f (Oonnxx_sqlite3.attach ~model_id:"test-model" db |> ok))

(* Components drawn from a small set so that equal cosine scores are common;
   exact copies under other ids add guaranteed ties. *)
let random_vector state dimension =
  let rec draw () =
    let vector =
      Array.init dimension (fun _ -> float (Random.State.int state 4 - 1)) in
    if Array.for_all (fun x -> x = 0.) vector then draw () else vector in
  draw ()

let reference ~query ~limit rows =
  rows
  |> List.map (fun (id, vector) ->
       let stored = Oonnxx.decode_f32le (Oonnxx.encode_f32le vector) in
       (id, Oonnxx.cosine query stored))
  |> List.sort (fun (a, x) (b, y) ->
       let order = Float.compare y x in
       if order = 0 then String.compare a b else order)
  |> List.filteri (fun index _ -> index < limit)

let exact_search_matches_full_sort () =
  List.iter (fun seed ->
    let state = Random.State.make [| seed |] in
    let dimension = 2 + Random.State.int state 6 in
    let count = Random.State.int state 300 in
    let base =
      List.init count (fun i ->
        (Printf.sprintf "doc-%04d" (Random.State.int state 10_000 * 1000 + i),
         random_vector state dimension)) in
    let copies =
      List.filteri (fun i _ -> i mod 7 = 0) base
      |> List.map (fun (id, vector) -> (id ^ "-copy", Array.copy vector)) in
    let rows = base @ copies in
    let n = List.length rows in
    with_index (fun index ->
      if rows <> [] then
        Oonnxx_sqlite3.upsert_many index
          (List.map (fun (id, vector) -> (id, "text", vector)) rows) |> ok;
      let query = random_vector state dimension in
      List.iter (fun limit ->
        let expected = reference ~query ~limit rows in
        let actual =
          Oonnxx_sqlite3.search_vector ~exact:true index ~query ~limit |> ok in
        if actual <> expected then
          failwith (Printf.sprintf
            "exact search differs from full sort (seed %d, n %d, limit %d)"
            seed n limit))
        (List.sort_uniq compare
           [ 1; 2; 3; 10; max 1 (n / 2); max 1 (n - 1); max 1 n; n + 7; 100_000;
             max_int ])))
    (List.init 12 Fun.id)

(* With the previous implementation, which re-sorted the accumulated list for
   every scanned row, this search took tens of seconds; a bounded heap takes a
   few milliseconds. The budget leaves a wide margin for a loaded machine. *)
let exact_search_full_depth_is_not_quadratic () =
  let state = Random.State.make [| 42 |] in
  let count = 16_000 in
  let rows =
    List.init count (fun i ->
      (Printf.sprintf "doc-%05d" i,
       Array.init 8 (fun _ -> Random.State.float state 2. -. 1.))) in
  with_index (fun index ->
    Oonnxx_sqlite3.upsert_many index
      (List.map (fun (id, vector) -> (id, "text", vector)) rows) |> ok;
    let query = Array.init 8 (fun _ -> Random.State.float state 2. -. 1.) in
    let started = Unix.gettimeofday () in
    let results =
      Oonnxx_sqlite3.search_vector ~exact:true index ~query ~limit:count |> ok in
    let elapsed = Unix.gettimeofday () -. started in
    check (List.length results = count) "full-depth result count";
    if elapsed > 2. then
      failwith (Printf.sprintf
        "exact search at limit %d took %.1f s; expected well under 2 s" count
        elapsed))

let () =
  exact_search_matches_full_sort ();
  exact_search_full_depth_is_not_quadratic ()
