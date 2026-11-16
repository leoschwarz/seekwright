(* Empty variants: distinct phantom tags keep Fs and Net branches disjoint. *)
type fs = |

type net = |

type _ t =
  | Fs : Policy_fs.t * Controls_raw.t -> fs t
  | Net : Policy_net.t * Controls_raw.t -> net t

let controls : type kind. kind t -> Controls_raw.t = function
  | Fs (_, controls) -> controls
  | Net (_, controls) -> controls

let with_controls : type kind. kind t -> Controls_raw.t -> kind t =
 fun grant controls ->
  match grant with
  | Fs (policy, _) -> Fs (policy, controls)
  | Net (policy, _) -> Net (policy, controls)

module Fs = struct
  type nonrec t = fs t

  let of_confinement ~mono_clock decision =
    Fs
      ( decision,
        Controls_raw.with_operation_timeout
          (Eio.Time.Timeout.seconds mono_clock Policy_fs.default_operation_timeout_seconds)
          Controls_raw.none )

  let read_file ?max_bytes grant path =
    match grant with Fs (policy, controls) -> Policy_fs.read_file ?max_bytes ~controls policy path

  let list_dir ?max_entries grant path =
    match grant with
    | Fs (policy, controls) -> Policy_fs.list_dir ?max_entries ~controls policy path

  let read_range ?max_bytes grant ~offset path =
    match grant with
    | Fs (policy, controls) -> Policy_fs.read_range ?max_bytes ~controls ~offset policy path

  type entry_info = { size_bytes : int; accessed_at : float }

  let stat grant path =
    match grant with
    | Fs (policy, controls) ->
        Result.map
          (fun (size_bytes, accessed_at) -> { size_bytes; accessed_at })
          (Policy_fs.stat ~controls policy path)

  let atomic_write ?max_bytes grant ~path ~contents =
    match grant with
    | Fs (policy, controls) -> Policy_fs.atomic_write ?max_bytes ~controls policy ~path ~contents

  let unlink grant path =
    match grant with Fs (policy, controls) -> Policy_fs.unlink ~controls policy path
end

module Net = struct
  type nonrec t = net t

  type method_ = Policy_net.method_

  type request = Policy_net.request = {
    meth : method_;
    uri : Uri.t;
    headers : (string * string) list;
    body : string option;
  }

  type response = Policy_net.response = {
    status : int;
    headers : (string * string) list;
    body : string;
  }

  let of_confinement ~mono_clock decision =
    Net
      ( decision,
        Controls_raw.with_operation_timeout
          (Eio.Time.Timeout.seconds mono_clock Policy_net.default_operation_timeout_seconds)
          Controls_raw.none )

  let request ?max_response_bytes grant request =
    match grant with
    | Net (policy, controls) -> Policy_net.request ?max_response_bytes ~controls policy request
end

let with_log ~sink grant = with_controls grant (Controls_raw.with_log ~sink (controls grant))

let with_operation_timeout timeout grant =
  with_controls grant (Controls_raw.with_operation_timeout timeout (controls grant))

let with_operation_budget budget grant =
  with_controls grant (Controls_raw.with_operation_budget budget (controls grant))
