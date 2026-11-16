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

let literal_fts_query_contract () =
  List.iter (fun (text, expected) ->
    let actual = Oonnxx_sqlite3.literal_fts_query text in
    if actual <> expected then
      failwith (Printf.sprintf "literal_fts_query %S = %S, expected %S" text
        actual expected);
    check (Oonnxx_caqti.literal_fts_query text = expected)
      "Caqti literal_fts_query matches")
    [ "", "";
      " \t\n ", "";
      "? * - ( ) \"", "";
      "chat noir", "\"chat\" OR \"noir\"";
      "chat\tnoir\nnuit", "\"chat\" OR \"noir\" OR \"nuit\"";
      "say \"hi\"", "\"say\" OR \"\"\"hi\"\"\"";
      "a AND b", "\"a\" OR \"AND\" OR \"b\"";
      "NOT NEAR OR", "\"NOT\" OR \"NEAR\" OR \"OR\"";
      "foo* ^bar col:baz", "\"foo*\" OR \"^bar\" OR \"col:baz\"";
      "café 日本語", "\"café\" OR \"日本語\"";
      "a\000b", "\"a\" OR \"b\"";
      "drill\000", "\"drill\"";
      "\000", "";
      "a\rb\011c\012d", "\"a\" OR \"b\" OR \"c\" OR \"d\"";
      "\r\011\012", "" ]

(* Every query built by [literal_fts_query] must be accepted by FTS5 and
   match terms literally: operators and prefix markers lose their meaning. *)
let literal_fts_query_is_literal () =
  with_index (fun index ->
    Oonnxx_sqlite3.upsert_many index
      [ "not", "this is not a drill", [| 1.; 0. |];
        "foobar", "foobar baz", [| 0.; 1. |];
        "cafe", "un café au lait", [| 1.; 1. |];
        "japanese", "日本語 テキスト", [| 1.; 2. |] ] |> ok;
    let search text =
      let query = Oonnxx_sqlite3.literal_fts_query text in
      if query = "" then []
      else
        match Oonnxx_sqlite3.search_fts index ~query ~limit:10 with
        | Ok ids -> List.sort compare ids
        | Error error ->
            failwith (Printf.sprintf "FTS5 rejected literal query for %S: %s"
              text error) in
    check (search "NOT" = [ "not" ]) "NOT is a search term";
    check (search "foo*" = []) "prefix marker is literal";
    check (search "foobar AND" = [ "foobar" ]) "AND is a search term";
    check (search "cafe" = [ "cafe" ]) "unicode61 folds diacritics";
    check (search "日本語" = [ "japanese" ]) "non-ASCII term";
    List.iter (fun text -> ignore (search text))
      [ "\"unbalanced"; "a\"\"b"; "(group"; "x)"; "NEAR(a b, 2)"; "-neg";
        "+plus"; "{col}: x"; "a OR"; "AND"; "—"; "\xff\xfe"; "drill\r";
        "x:y:z"; "'single'"; "a\000b"; "drill\000"; "\000"; "x\011y\012z" ];
    check (search "drill\000" = [ "not" ]) "NUL separates words";
    List.iter (fun text ->
      match
        Oonnxx_sqlite3.search_hybrid index ~text ~vector:[| 1.; 0. |] ~limit:2
      with
      | Ok _ -> ()
      | Error error ->
          failwith (Printf.sprintf "search_hybrid failed for %S: %s" text error))
      [ "a\000b"; "drill\000"; "\000" ])

let blank_fts_query_returns_nothing () =
  with_index (fun index ->
    Oonnxx_sqlite3.upsert index ~id:"doc" ~text:"some text" ~vector:[| 1.; 0. |]
    |> ok;
    List.iter (fun query ->
      match Oonnxx_sqlite3.search_fts index ~query ~limit:5 with
      | Ok [] -> ()
      | Ok _ -> failwith (Printf.sprintf "search_fts %S returned rows" query)
      | Error error ->
          failwith (Printf.sprintf "search_fts %S failed: %s" query error))
      [ ""; " "; "\t\n " ])

let () =
  literal_fts_query_contract ();
  literal_fts_query_is_literal ();
  blank_fts_query_returns_nothing ();
  exact_search_matches_full_sort ();
  exact_search_full_depth_is_not_quadratic ()
