(** The one canonical rendering the differential corpus is written in.

    A golden is only comparable if both trees render the same fact the same way,
    so the rules that make a value safe to check in live here, once, and the
    corpus generator on the Python side states the same rules in
    [ocaml-tools/oracle/projections.py]. Three properties matter:

    - {b ASCII-only}. Every text value is escaped to printable ASCII, so a
      golden survives a checkout, a diff tool, and a locale nobody chose. The
      escape is the one [json.dumps(ensure_ascii=True)] writes: named escapes for
      the common controls, [\u] escapes with surrogate pairs above the BMP,
      lowercase hex digits.
    - {b no ambient clock, no secret}. Nothing in here reads the time or the
      environment; a golden body is a function of its corpus input alone.
    - {b total for the corpus's values}. [float_repr] follows Python's [repr]
      only for values whose shortest round-trip form is what [%.17g] prints, and
      the generator asserts that condition for every float it puts in a case, so
      a float that would need Python's shortest-repr algorithm is refused at
      generation time rather than silently pinned wrong. *)

val escape_text : string -> string
(** [escape_text s] is [s] with every character outside printable ASCII escaped
    the way [json.dumps(s, ensure_ascii=True)] escapes it, minus the surrounding
    quotes. Bytes that are not valid UTF-8 become [\ufffd], which is what
    Python's [errors="replace"] decode of the same bytes would have given. *)

val float_repr : float -> string
(** [float_repr v] is the decimal form the corpus pins a float with: [%.17g] with
    [.0] appended when that form has neither a dot nor an exponent, which is
    Python's [repr] for every value whose shortest round trip is already exact.
    Raises [Invalid_argument] on a NaN or an infinity: the corpus pins no such
    value, and a golden that said [nan] would compare equal to nothing. *)

val canon_json : Yojson.Safe.t -> string
(** [canon_json json] is [json] as one compact line with object keys sorted —
    [json.dumps(value, sort_keys=True, separators=(",", ":"))] on the Python
    side. Sorting is what makes an encoder's field order a non-issue: the claim
    under test is which fields and which values, not the order pydantic happens
    to keep. *)

val to_hex : string -> string
(** [to_hex s] is the bytes of [s] as lowercase hex. The escape the sanitize
    corpus uses, because that pass is about exact bytes around a zero-width
    space and no readable escape says anything about them. *)

val of_hex : string -> string
(** [of_hex h] is the inverse of {!to_hex}. Raises [Invalid_argument] on a string
    that is not an even number of hex digits. *)

val reset_key_environment : unit -> unit
(** Clear every variable that would make a golden depend on the machine: the
    provider key variables [Config.api_key_env_var] names, the agent key, and
    [SEEKWRIGHT_CONFIG].

    The stdlib has no [unsetenv], and [Config.api_key] reads an empty value as
    absent exactly as Python's [os.environ.get(...) or None] does, so writing
    [""] is the clear. The Python side pops the same names. Both trees therefore
    resolve the same [missing_keys] list whatever the shell that runs
    [dune runtest] or the generator happens to export. *)
