(* The failure rows every HTTP adapter owes, driven over both keyless adapters.

   Port of the guarantee in tests/providers/test_provider_contract.py: the six
   rows docs/reference/provider-contract.md's Failures table fixes are one
   promise, and an adapter that skips one skips it silently — which is why the
   Python suite drives the table over every adapter rather than trusting each
   adapter's own file to have copied it.

   That suite reads the table out of the document so code and contract cannot
   drift in either direction. This one names the rows instead, because the
   table's {i signals} are spelled in httpx vocabulary while the port's are the
   two kinds a {!Seekwright.Provider.Net.t} grant answers with: the row that has
   to stay shared is the {i answer}, not the exception name that triggers it.

   Driven: authentication, any other [>= 400], the operation bound, a transport
   failure, a body that does not decode, and a body that decodes to something
   that is not an object. Deliberately not: the quota row's {i wording}, which
   each backend words after its own billing model — only its kind is pinned
   here, exactly as the Python suite leaves that split.

   The MCP-backed adapters ([exa], [parallel]) have no status line to map and do
   not exist in this tree yet (plans/seekwright-ocaml-port.md, open question 3),
   so the adapter set driven here is every adapter module on disk. *)

module Caps = Mcp_caps
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module A = Alcotest

(* Never sent to anything real: it is the string a leak would carry. *)
let probe_key = "contract-probe-key-4c1f"

let contains text needle =
  let n = String.length text and m = String.length needle in
  let rec from i =
    if i + m > n then false else String.sub text i m = needle || from (i + 1)
  in
  from 0

let probe_query =
  {
    Model.query = "wal";
    max_results = 3;
    include_domains = [];
    exclude_domains = [];
    country = None;
    language = None;
    recency = None;
    safe_search = None;
  }

let clock () = 1_700_000_000.

(* One adapter: its name, and how to build it behind a given Net. The keyless
   pair needs no credential, which is what lets one construction serve every
   row; a keyed adapter will need a field beside [build] when it lands. *)
type adapter = {
  name : string;
  build : Provider.Net.t -> Provider.t;
}

let adapters =
  [
    {
      name = "freeserp";
      build = (fun net -> Seekwright_providers.Freeserp.make ~now:clock ~net ());
    };
    {
      name = "anysearch";
      build = (fun net -> Seekwright_providers.Anysearch.make ~net ());
    };
  ]

(* {1 The probes}

   Each row says how to answer the adapter's grant: a status line, a body, or a
   transport failure whose own message carries [probe_key] on purpose — the
   contract is that none of it reaches the failure the engine logs. *)

type probe = {
  label : string;
  status : int;
  body : string;
  refusal : (unit, Caps.Error.t) result;
      (** [Ok ()] answers with [status] and [body]; [Error e] refuses the
          request instead, which is how the timeout and network rows are cast. *)
}

let responding label ?(status = 200) ?(body = "{}") () =
  { label; status; body; refusal = Ok () }

let refusing label kind =
  {
    label;
    status = 0;
    body = "";
    refusal =
      Error (Caps.Error.make kind ~message:(Printf.sprintf "dial failed, x-api-key: %s" probe_key));
  }

(* The rows, in the table's order, with the answer each one owes. [message] is
   [None] where the contract leaves the wording to the adapter — the quota row,
   which is pinned for its kind only. *)
type row = {
  key : string;
  expected_kind : Provider.error_kind;
  message : int -> string option;
      (** [None] for the rows whose wording is the adapter's own; otherwise a
          function of the status, because the [>= 400] row names the code. *)
  retryable : bool;
  probes : probe list;
}

let other_statuses = [ 400; 418; 500 ]

let non_object_bodies =
  [
    ("empty-array", "[]");
    ("array-of-records", {|[{"title": "t", "url": "https://x"}]|});
    ("null", "null");
    ("number", "42");
    ("bare-string", "\"a bare string\"");
  ]

let rows =
  [
    {
      key = "auth";
      expected_kind = Provider.Failure;
      message = (fun _status -> Some "authentication rejected (check API key)");
      retryable = false;
      probes = [ responding "status 401" ~status:401 (); responding "status 403" ~status:403 () ];
    };
    {
      key = "http";
      expected_kind = Provider.Failure;
      message = (fun code -> Some (Printf.sprintf "HTTP %d" code));
      retryable = true;
      probes = List.map (fun code -> responding (Printf.sprintf "status %d" code) ~status:code ()) other_statuses;
    };
    {
      key = "quota-kind-only";
      expected_kind = Provider.Quota;
      (* The table writes this row's message as [...]: which statuses mean "out
         of credits", and what that failure is called, are the per-adapter
         quirks each adapter's own suite pins. *)
      message = (fun _status -> None);
      retryable = false;
      probes = [ responding "status 402" ~status:402 (); responding "status 429" ~status:429 () ];
    };
    {
      key = "timeout";
      expected_kind = Provider.Failure;
      message = (fun _status -> Some "request timed out");
      retryable = true;
      probes = [ refusing "the grant's operation bound" Caps.Error.Timeout ];
    };
    {
      key = "network";
      expected_kind = Provider.Failure;
      message = (fun _status -> Some "network error");
      retryable = true;
      probes =
        [
          refusing "the endpoint refused the grant" Caps.Error.Denied;
          refusing "the request was invalid" Caps.Error.Invalid;
          refusing "the name did not resolve" Caps.Error.Unavailable;
          refusing "it reached the peer and still failed" Caps.Error.Failed;
        ];
    };
    {
      key = "malformed-json";
      expected_kind = Provider.Failure;
      message = (fun _status -> Some "malformed JSON response");
      retryable = true;
      probes =
        [
          responding "an html body" ~body:{|<html>not json at all</html>|} ();
          responding "an html body quoting the key"
            ~body:(Printf.sprintf "<html>upstream echoed %s</html>" probe_key) ();
          responding "an empty body" ~body:"" ();
        ];
    };
    {
      key = "non-object";
      expected_kind = Provider.Failure;
      message = (fun _status -> Some "malformed JSON response");
      retryable = true;
      probes =
        List.map
          (fun (label, body) -> responding label ~body ())
          non_object_bodies;
    };
  ]

(* {1 Driving a row over an adapter} *)

let net_of probe =
  {
    Provider.Net.request =
      (fun _ ->
        match probe.refusal with
        | Error failure -> Error failure
        | Ok () -> Ok { Caps.Authority.Net.status = probe.status; headers = []; body = probe.body });
  }

let where adapter row probe = Printf.sprintf "%s [%s: %s]" adapter.name row.key probe.label

(* Every way one adapter departs from one row. *)
let problems adapter row probe =
  let provider = adapter.build (net_of probe) in
  match Provider.search provider probe_query with
  | Ok outcome ->
      [ Printf.sprintf "%s: returned %d results instead of failing" (where adapter row probe)
          (List.length outcome.results) ]
  | Error error ->
      (* The record's [provider] field shares its name with [outcome]'s, so the
         annotation is what picks the failure's. *)
      let (failure : Provider.error) = error in
      let here = where adapter row probe in
      let kind =
        let shown k = match k with Provider.Quota -> "quota" | Provider.Failure -> "failure" in
        if failure.kind = row.expected_kind then []
        else [ Printf.sprintf "%s: answered %s, the table says %s" here (shown failure.kind) (shown row.expected_kind) ]
      in
      (* The [error_kind] is the load-bearing half of the row: it is what the
         engine branches on, so a quota failure reported as an ordinary one (or
         the reverse) benches the name in the health board or sends the fallback
         walk the wrong way, whatever the message says. *)
      let wording =
        match row.message probe.status with
        | None -> []
        | Some expected when expected = failure.message -> []
        | Some expected ->
            [ Printf.sprintf "%s: message %S, the table says %S" here failure.message expected ]
      in
      let retry =
        if failure.retryable = row.retryable then []
        else [ Printf.sprintf "%s: retryable %b, the table says %b" here failure.retryable row.retryable ]
      in
      let naming =
        if failure.provider = adapter.name then []
        else [ Printf.sprintf "%s: provider names %S" here failure.provider ]
      in
      let leak =
        if contains (Provider.render_error failure) probe_key then
          [ Printf.sprintf "%s: the request key leaked into %S" here (Provider.render_error failure) ]
        else if contains failure.message probe_key then
          [ Printf.sprintf "%s: the key is in the message" here ]
        else []
      in
      kind @ wording @ retry @ naming @ leak

let () =
  A.
    (run "seekwright/provider-contract"
       [
         ( "the Failures table, over every HTTP adapter",
             List.map
               (fun adapter ->
                 A.test_case
                   (Printf.sprintf "%s honours the failure rows" adapter.name)
                   `Quick
                   (fun () ->
                     let problems =
                       List.concat_map
                         (fun row ->
                           List.concat_map (fun probe -> problems adapter row probe) row.probes)
                         rows
                     in
                     match problems with
                     | [] -> ()
                     | found ->
                         A.failf
                           "%s departs from the Failures table:@\n%s"
                           adapter.name (String.concat "\n" found)))
               adapters );
         ( "the adapter set",
             [
               A.test_case "every adapter module on disk is driven here" `Quick (fun () ->
                   (* The guard the Python suite runs against its provider
                      directory: a new adapter that skips this suite skips the
                      contract, and a name driven here that no longer exists
                      tests nothing. [dune] and [dune-project] are not modules. *)
                   let on_disk =
                     Array.to_list (Sys.readdir "../lib/providers")
                     |> List.filter (fun name -> Filename.check_suffix name ".ml")
                     |> List.map Filename.chop_extension
                     |> List.sort Stdlib.compare
                   in
                   let driven = List.map (fun a -> a.name) adapters |> List.sort Stdlib.compare in
                   A.(check (list string)) "adapters on disk vs driven" on_disk driven);
               A.test_case "the table's rows are all driven" `Quick (fun () ->
                   (* Six shared rows plus the quota row's kind. A row dropped
                      from [rows] would leave an adapter free to skip it. *)
                   A.(check int) "rows driven" 7 (List.length rows));
             ] );
       ])
