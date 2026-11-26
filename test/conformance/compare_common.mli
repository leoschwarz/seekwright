(** The grammar both conformance comparators read.

    The pinned official MCP runner writes a run directory (metadata files, a [list --requirements]
    transcript, its stdout, its exit code, and one result directory per scenario holding a
    [checks.json]). Neither comparator scores anything itself: both fail closed on that material, so
    what this module owns is the parsing the two gates share — the manifest line grammar, the
    runner's list and stdout grammars, the result-directory name grammar, the [checks.json] reader,
    and the report writer.

    Every function here mirrors the sentence the retired Python comparator produced, because a
    failing gate has to name the same problem it named before: the error strings are part of the
    contract, not decoration. The one deliberate looseness is a JSON *parse* failure, whose wording
    belongs to the parser (see {!val:read_json}). *)

exception Bad of string
(** A fail-closed refusal to read something, carrying the sentence the caller quotes into its error
    list. Callers catch this where the Python original caught [ValueError], [OSError] and
    [JSONDecodeError]. *)

val failing_statuses : string list
(** The two statuses a check can carry that count as failing. *)

val check_statuses : string list
(** The five statuses a [checks.json] entry may carry. *)

type check = { id : string; status : string; error_message : string option; json : Yojson.Safe.t }
(** One entry of a [checks.json] array. [json] keeps the object as parsed, for
    {!val:observed_evidence}. *)

type run = { checks : check list; failed : string list; result : string }
(** A scenario's [checks.json] reduced to what both gates ask: the failing check IDs in file order,
    and the summary — [fail] when any check failed, [pass] when some check succeeded, [skipped]
    otherwise. *)

type errors = { mutable lines : string list }
(** The error list a gate accumulates, in the order it notices things. *)

val errors : unit -> errors
val add : errors -> string -> unit
val any : errors -> bool

val read_file : string -> (string, string) result
(** [read_file path] is the file's text, or the message the old comparator put in its error sentence
    for an unreadable file. It never raises. *)

val read_stripped : string -> (string, string) result
(** [read_stripped path] is [read_file] with the whole content trimmed, which is how the
    run-metadata files and the exit-code file are read. *)

val split_lines : string -> string list
(** [split_lines text] splits the way the Python [splitlines] did: an empty file is zero lines, a
    single trailing newline is not a line, and a [CR] before a [LF] belongs to the line ending. *)

val ids : ?allow_empty:bool -> string -> string list
(** [ids ?allow_empty path] is the pinned scenario manifest: one ID per line, comments only where
    the raw line starts with a hash, duplicates and (unless [allow_empty]) emptiness refused. *)

val runner_list : string -> string list
(** [runner_list text] is the scored server-scenario list out of a [runner list --requirements]
    transcript. Raises [Bad] when the section is not there at all, or when it runs to the end of the
    transcript without the next section header: either way a runner upgrade or a truncated
    transcript becomes a failure instead of an empty or short expected set. *)

val runner_unscored : string -> string list
(** [runner_unscored text] is the "Run and reported, but never scored" server list from the same
    transcript. *)

val scenario_of_result_dir : string -> string option
(** [scenario_of_result_dir name] is the scenario a runner result directory names:
    [server-<scenario>-<YYYY-MM-DDThh-mm-ss-<n>Z]. The timestamp is matched greedily, so a scenario
    name containing a dash keeps its own dash. *)

val executed_scenarios : string -> string list
(** [executed_scenarios stdout] is every [=== Running scenario: X ===] line, in order — a multiset,
    because the comparison counts repetitions. *)

val exact : string -> string list -> string list -> errors -> unit
(** [exact label actual expected errors] records one error when the two lists differ as sets or when
    [actual] repeats a value. *)

val multiset_diff : string -> string list -> string list -> errors -> unit
(** [multiset_diff label actual expected errors] compares occurrences rather than the ID set, for
    the runner's reused check IDs. *)

val read_json : ?dup_prefix:string -> string -> Yojson.Safe.t
(** [read_json ?dup_prefix path] parses a JSON document, refusing a duplicate object key: a baseline
    that quietly carries the same scenario twice would otherwise be scored by whichever copy the
    parser happened to keep. [dup_prefix] names the document in the refusal ([baseline],
    [classification]). Raises [Bad] for an unreadable file, an unparseable document or a duplicate.
*)

val read_checks : string -> run
(** [read_checks path] reads one scenario's [checks.json]. *)

val observed_evidence : check -> string
(** [observed_evidence check] is the evidence sentence a new untriaged failure carries: its
    [errorMessage] when there is one, and the whole check rendered as sorted, compact JSON
    otherwise. *)

val py_compact : Yojson.Safe.t -> string
(** [py_compact json] renders a document the way the retired script rendered an evidence string:
    sorted keys, [", "] and [": "] separators, ASCII-only. *)

val counter : string list -> (string, int) Hashtbl.t
(** [counter keys] tallies occurrences; [counter_get] reads one tally, [counter_add] raises it,
    [counter_total] sums it, and [counter_json]/[counter_alist] render it with sorted keys. *)

val counter_get : (string, int) Hashtbl.t -> string -> int
val counter_add : (string, int) Hashtbl.t -> string -> int -> unit
val counter_total : (string, int) Hashtbl.t -> int
val counter_json : (string, int) Hashtbl.t -> Yojson.Safe.t
val counter_alist : (string, int) Hashtbl.t -> (string * int) list

val assoc_get : Yojson.Safe.t -> string -> Yojson.Safe.t option
(** [assoc_get json key] / [get_string json key] read one field of a JSON object, answering [None]
    when the object does not carry it or it is not a string. *)

val get_string : Yojson.Safe.t -> string -> string option

val member_json : Yojson.Safe.t list -> Yojson.Safe.t
(** [member_json xs] / [assoc_json xs] build JSON values; [sort_json] sorts every object's keys,
    which is what makes a report byte-stable across runs. *)

val assoc_json : (string * Yojson.Safe.t) list -> Yojson.Safe.t
val sort_json : Yojson.Safe.t -> Yojson.Safe.t

val write_report : string -> Yojson.Safe.t -> unit
(** [write_report path json] creates the parent directory, writes the sorted pretty JSON, and ends
    the file with a newline. *)

val py_list : string list -> string
(** [py_list xs] renders a list of strings the way the retired script's error sentences did, so a
    reader comparing two runs of the same failure sees the same text. *)

val relative_path : base:string -> string -> string
(** [relative_path ~base path] drops [base] and its separator from [path], and leaves [path] alone
    when it is not underneath. Reports carry result paths relative to the run directory. *)

val list_dirs : string -> (string list, unit) result
(** [list_dirs dir] is the immediate subdirectory names of [dir] (unsorted); [Error] when [dir] is
    not there to be read. *)

val dir_exists : string -> bool
(** [dir_exists path] says whether a path is a directory. *)

val parse_args : program:string -> spec:(string * bool) list -> unit -> (string, string) Hashtbl.t
(** [parse_args ~program ~spec ()] reads [--flag value] pairs from the command line, keys spelled
    with [_] where the flag carries a [-]. A missing required flag, an unknown flag or a flag
    without its value is reported on stderr and exits 2, the way the retired argument parser did. *)

val opt : (string, string) Hashtbl.t -> string -> string option
val opt_exn : (string, string) Hashtbl.t -> string -> string
