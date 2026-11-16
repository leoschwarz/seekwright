(* The CLI entry point: dispatching verbs or flag sets, running the Eio main
   event loop with network grants, and exiting with status. *)

module Caps = Mcp_caps
module Config = Seekwright.Config
module Factory = Seekwright_factory.Factory
module Log = Seekwright.Log
module Model = Seekwright.Model
module Provider = Seekwright.Provider
module Server = Seekwright.Server
module Usage = Seekwright.Usage

let print_line line = print_endline line

let usage_error message =
  prerr_endline ("seekwright: " ^ message);
  exit 2

let tls_client_config =
  lazy
    (match Ca_certs.authenticator () with
    | Error _ -> None
    | Ok authenticator -> (
        match Tls.Config.client ~authenticator () with
        | Ok config -> Some config
        | Error _ -> None))

let make_post ~env ~sw ~path body =
  let uri = Uri.of_string path in
  let client =
    match Uri.scheme uri with
    | Some "https" -> (
        match Lazy.force tls_client_config with
        | Some config ->
            let host_of uri =
              Domain_name.host_exn (Domain_name.of_string_exn (Option.value ~default:"" (Uri.host uri)))
            in
            Ok
              (Cohttp_eio.Client.make
                 ~https:(Some (fun uri flow -> Tls_eio.client_of_flow config ~host:(host_of uri) flow))
                 env#net)
        | None -> Error "https needs the system trust store, which is missing")
    | _ -> Ok (Cohttp_eio.Client.make ~https:None env#net)
  in
  match client with
  | Error message -> Error message
  | Ok client -> (
      let headers =
        Http.Header.of_list [ ("content-type", "application/json"); ("accept", "application/json") ]
      in
      match
        Cohttp_eio.Client.call client ~sw ~headers
          ~body:(Cohttp_eio.Body.of_string body)
          `POST uri
      with
      | exception exn -> Error (Printexc.to_string exn)
      | response, response_body ->
          let status = Http.Status.to_int (Http.Response.status response) in
          let text =
            Eio.Buf_read.(take_all (of_flow response_body ~max_size:(64 * 1024 * 1024)))
          in
          Ok (status, text))

let run_client ~env verb argv =
  Mirage_crypto_rng_unix.use_default ();
  match Cli_client.verb_of_string verb with
  | None -> usage_error ("unknown verb " ^ verb)
  | Some verb ->
      Eio.Switch.run @@ fun sw ->
      let post = make_post ~env ~sw in
      match Cli_client.run ~post ~verb ~argv with
      | Ok (Some line) ->
          print_line line;
          0
      | Ok None -> 0
      | Error (sentence, code) ->
          prerr_endline ("seekwright: " ^ sentence);
          code

let run_metrics ~env as_json =
  match Config.load None with
  | Error message ->
      prerr_endline ("seekwright: " ^ message);
      1
  | Ok config -> (
      let history_path =
        match config.Config.dashboard.Config.history_path with
        | None -> None
        | Some path -> Some Eio.Path.(env#fs / path)
      in
      match Usage.create ~now:Unix.gettimeofday ?history_path () with
      | Error message ->
          prerr_endline ("seekwright: dashboard.history_path: " ^ message);
          1
      | Ok recorder -> (
          let snapshot = Usage.snapshot recorder in
          let json_field key = function
            | `Assoc fields -> ( match List.assoc_opt key fields with Some v -> v | None -> `Null)
            | _ -> `Null
          in
          let endpoints = json_field "endpoints" snapshot in
          let journal = json_field "journal" snapshot in
          if as_json then begin
            print_endline (Yojson.Safe.pretty_to_string endpoints);
            0
          end
          else begin
            Cli_metrics.print_report ~emit:print_line ~now:(Unix.gettimeofday ()) endpoints journal;
            0
          end))

let run_check ~env ~sw live =
  match Config.load None with
  | Error message ->
      prerr_endline ("seekwright: " ^ message);
      1
  | Ok config -> Cli_check.run ~env ~sw ~config ~emit:print_line ~live

let startup_log log config (built : Factory.providers) =
  log Config.Log_info "startup"
    [
      ("providers", `String (String.concat "," (List.map fst built.Factory.built)));
      ( "unsupported",
        (match built.Factory.unsupported with
        | [] -> `Null
        | names -> `String (String.concat "," names)) );
      ( "default_provider",
        (match config.Config.default_provider with
        | Some name -> `String name
        | None -> `Null) );
      ("providers_defaulted", `Bool config.Config.providers_defaulted);
      ("fetch", `Bool config.Config.fetch.Config.enabled);
      ("fetch_extractor", `String config.Config.fetch.Config.extractor);
      ("fetch_primary", `String config.Config.fetch.Config.primary);
      ( "agent",
        (match config.Config.agent.Config.model with
        | Some model -> `String model
        | None -> `Null) );
    ]

let close_providers (built : Factory.providers) () =
  List.iter (fun (_, provider) -> Provider.aclose provider) built.Factory.built

let run_server ~env ~sw opts =
  Mirage_crypto_rng_unix.use_default ();
  match Config.load None with
  | Error message ->
      prerr_endline ("seekwright: " ^ message);
      exit 1
  | Ok config ->
      (match Cli_flags.startup_refusal config opts with
      | Ok () -> ()
      | Error sentence ->
          prerr_endline ("seekwright: " ^ sentence);
          exit 1);
      let logging =
        Log.apply_overrides config.Config.logging opts.log_level opts.log_format
      in
      let log = Log.sink (Log.make logging) in
      match
        Factory.build_app ~sw ~env ~now:Unix.gettimeofday ~log ~allowed_hosts:opts.allowed_hosts config
      with
      | Error message ->
          prerr_endline ("seekwright: " ^ message);
          exit 1
      | Ok (app, built) ->
          startup_log log config built;
          if built.Factory.unsupported <> [] then
            log Config.Log_warning "startup.providers_unsupported"
              [ ( "unsupported", `String (String.concat "," built.Factory.unsupported) ) ];
          (match Server.mcp_server app with
          | Error (Caps.Server.Duplicate_tool name) ->
              close_providers built ();
              prerr_endline ("seekwright: duplicate tool: " ^ name);
              exit 1
          | Error (Caps.Server.Invalid_declaration message) ->
              close_providers built ();
              prerr_endline ("seekwright: " ^ message);
              exit 1
          | Ok server ->
              if opts.http then begin
                let host = Option.value ~default:"127.0.0.1" opts.host in
                let port = Option.value ~default:8000 opts.port in
                log Config.Log_info "http.listening"
                  [ ("host", `String host); ("port", `Int port) ];
                (match
                   Cli_serve.run_http ~env ~sw ~log ~app ~server ~host ~port
                     ~close:(close_providers built) ()
                 with
                | Ok Server.Drained -> ()
                | Ok Server.Grace_expired -> ()
                | Error Server.Bind_address_unresolved ->
                    prerr_endline
                      "seekwright: cannot resolve the HTTP bind address";
                    exit 1
                | Error Server.Listener_unavailable ->
                    prerr_endline "seekwright: cannot open the HTTP listener";
                    exit 1)
              end
              else Mcp_kit_stdio.run_channels server stdin stdout)

let () =
  let argv = List.tl (Array.to_list Sys.argv) in
  match argv with
  | verb :: rest when List.mem verb Server.cli_verbs ->
      Eio_main.run @@ fun env -> exit (run_client ~env verb rest)
  | _ ->
      (match Cli_flags.parse argv with
      | Error sentence -> usage_error sentence
      | Ok opts ->
          Mirage_crypto_rng_unix.use_default ();
          if opts.metrics then
            Eio_main.run @@ fun env ->
            exit (run_metrics ~env opts.json)
          else if opts.check then
            Eio_main.run @@ fun env ->
            Eio.Switch.run @@ fun sw -> exit (run_check ~env ~sw opts.live)
          else
            Eio_main.run @@ fun env ->
            Eio.Switch.run @@ fun sw -> run_server ~env ~sw opts)
