(* The grant type and the decorators over it. authority.mli states the claim;
   the parts worth pointing at in this file are the GADT, the defaults it
   installs, and why the decorators need no GADT machinery at all. *)

(* Distinct tags, and deliberately not [type fs = unit] and [type net = unit]:
   with the two phantoms aliased to the same type, the [Fs] and [Net] branches
   are not typewise disjoint and every operation below needs an unreachable
   branch of its own. As two type constructors, a grant of kind [fs] cannot
   match a [Net] pattern at all, so each operation names the one branch it
   can ever see. Empty variants: no value of either kind is ever built, the kind
   exists only in the grant's type. *)
type fs = |

type net = |

(* The confinement decision and the bounds, side by side (§3). The decorators
  below change only the second component, which is why [with_log],
  [with_operation_timeout] and [with_operation_budget] are one function each for
  every kind rather than one per kind: a new kind inherits them by carrying a
  [Controls.t], and a kind cannot quietly opt out of being audited or bounded. *)
type _ t =
  | Fs : Policy_fs.t * Controls_raw.t -> fs t
  | Net : Policy_net.t * Controls_raw.t -> net t

(* The two accessors are the only GADT-sensitive code here: a plain [function]
   would refine the parameter's kind in the first branch and then reject the
   second, so both are written with a locally abstract [kind] and the equation
   [kind t = fs t] is solved per branch. *)
let controls : type kind. kind t -> Controls_raw.t = function
  | Fs (_, controls) -> controls
  | Net (_, controls) -> controls

(* Both branches return the parameter they were given, so this generalises over
   [kind] and the grant's kind is preserved by every decorator. *)
let with_controls : type kind. kind t -> Controls_raw.t -> kind t =
 fun grant controls ->
  match grant with
  | Fs (policy, _) -> Fs (policy, controls)
  | Net (policy, _) -> Net (policy, controls)

module Fs = struct
  type nonrec t = fs t

  (* A grant with no controls would be silent and unbounded, so construction
     installs this kind's default bound and nothing else. Every way of changing
     that bound — [with_log], [with_operation_timeout], a different budget — is
     one of the three decorators at the bottom of this module, and each one
     starts from a grant, which is why the controls record has no producer here
     either: the raw record and the [run] that applies it are in the private
     [Controls_raw], and an application has no way to hand a grant a bounds set
     of its own at construction. *)
  let of_confinement ~mono_clock decision =
    Fs
      (decision,
        Controls_raw.with_operation_timeout
          (Eio.Time.Timeout.seconds mono_clock Policy_fs.default_operation_timeout_seconds)
          Controls_raw.none)

  let read_file ?max_bytes grant path =
    match grant with Fs (policy, controls) -> Policy_fs.read_file ?max_bytes ~controls policy path

  let list_dir ?max_entries grant path =
    match grant with Fs (policy, controls) -> Policy_fs.list_dir ?max_entries ~controls policy path
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

  (* The https path of a grant that can speak it is already configured inside
     [decision] ([Policy_net.with_endpoints] fails construction when it is not),
     so the only thing to add here is the time bound. *)
  let of_confinement ~mono_clock decision =
    Net
      (decision,
        Controls_raw.with_operation_timeout
          (Eio.Time.Timeout.seconds mono_clock Policy_net.default_operation_timeout_seconds)
          Controls_raw.none)

  let request ?max_response_bytes grant request =
    match grant with
    | Net (policy, controls) -> Policy_net.request ?max_response_bytes ~controls policy request
end

let with_log ~sink grant =
  with_controls grant (Controls_raw.with_log ~sink (controls grant))

let with_operation_timeout timeout grant =
  with_controls grant (Controls_raw.with_operation_timeout timeout (controls grant))

let with_operation_budget budget grant =
  with_controls grant (Controls_raw.with_operation_budget budget (controls grant))
