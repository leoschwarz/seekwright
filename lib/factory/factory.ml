(* The construction surface. The four building modules are [include]d, not re-exported name by name:
   a value's type and contract live once, in the interface of the module that owns it, and
   [factory.mli] derives from those interfaces. [App] is the one exception in the implementation —
   its module has eight internal aliases beside [build_app], and a façade that [include]d them would
   resolve [Factory.build_providers] through [App] rather than through its owner. [Grants] is not
   [include]d at all: [grant_of_decision] and [fs_grant_of_written_root] turn a confinement decision
   into a grant, and that stays library-internal, which is why the three grant names this layer does
   export are bound by hand below. *)
include Providers_build
include Verdict
include Fetch_stack

let build_app = App.build_app
let audit_sink = Grants.audit_sink
let grant_of_endpoint = Grants.grant_of_endpoint
let probe_net = Grants.probe_net
