(* UTF-8 helpers for the fetch path; see utf8.mli. *)

type t = int array

let lead_len s i =
  let c = Char.code s.[i] in
  if c < 0x80 then 1
  else if c < 0xc0 then 1
  else if c < 0xe0 then 2
  else if c < 0xf0 then 3
  else 4

let count s =
  let n = ref 0 in
  let i = ref 0 in
  let len = String.length s in
  while !i < len do
    let step = lead_len s !i in
    i := !i + (if !i + step > len then len - !i else step);
    incr n
  done;
  !n

let of_string s =
  let len = String.length s in
  let cps = ref [] in
  let i = ref 0 in
  while !i < len do
    let step = lead_len s !i in
    let step = if !i + step > len then len - !i else step in
    let cp =
      match step with
      | 1 -> Char.code s.[!i]
      | 2 ->
          ((Char.code s.[!i] land 0x1f) lsl 6)
          lor (Char.code s.[!i + 1] land 0x3f)
      | 3 ->
          ((Char.code s.[!i] land 0x0f) lsl 12)
          lor ((Char.code s.[!i + 1] land 0x3f) lsl 6)
          lor (Char.code s.[!i + 2] land 0x3f)
      | _ ->
          ((Char.code s.[!i] land 0x07) lsl 18)
          lor ((Char.code s.[!i + 1] land 0x3f) lsl 12)
          lor ((Char.code s.[!i + 2] land 0x3f) lsl 6)
          lor (Char.code s.[!i + 3] land 0x3f)
    in
    cps := cp :: !cps;
    i := !i + step
  done;
  Array.of_list (List.rev !cps)

let utf8_width cp =
  if cp < 0x80 then 1 else if cp < 0x800 then 2 else if cp < 0x10000 then 3 else 4

let encode cp = String.init (utf8_width cp) (fun i ->
    match utf8_width cp with
    | 1 -> Char.chr cp
    | 2 ->
        if i = 0 then Char.chr (0xc0 lor (cp lsr 6))
        else Char.chr (0x80 lor (cp land 0x3f))
    | 3 ->
        if i = 0 then Char.chr (0xe0 lor (cp lsr 12))
        else if i = 1 then Char.chr (0x80 lor ((cp lsr 6) land 0x3f))
        else Char.chr (0x80 lor (cp land 0x3f))
    | _ ->
        if i = 0 then Char.chr (0xf0 lor (cp lsr 18))
        else if i = 1 then Char.chr (0x80 lor ((cp lsr 12) land 0x3f))
        else if i = 2 then Char.chr (0x80 lor ((cp lsr 6) land 0x3f))
        else Char.chr (0x80 lor (cp land 0x3f)))

let to_string cps =
  let bytes =
    Array.fold_left (fun acc cp -> acc + utf8_width cp) 0 cps in
  let out = Buffer.create bytes in
  Array.iter
    (fun cp ->
      if cp < 0x80 then Buffer.add_char out (Char.chr cp)
      else if cp < 0x800 then begin
        Buffer.add_char out (Char.chr (0xc0 lor (cp lsr 6)));
        Buffer.add_char out (Char.chr (0x80 lor (cp land 0x3f)))
      end
      else if cp < 0x10000 then begin
        Buffer.add_char out (Char.chr (0xe0 lor (cp lsr 12)));
        Buffer.add_char out (Char.chr (0x80 lor ((cp lsr 6) land 0x3f)));
        Buffer.add_char out (Char.chr (0x80 lor (cp land 0x3f)))
      end
      else begin
        Buffer.add_char out (Char.chr (0xf0 lor (cp lsr 18)));
        Buffer.add_char out (Char.chr (0x80 lor ((cp lsr 12) land 0x3f)));
        Buffer.add_char out (Char.chr (0x80 lor ((cp lsr 6) land 0x3f)));
        Buffer.add_char out (Char.chr (0x80 lor (cp land 0x3f)))
      end)
    cps;
  Buffer.contents out

let is_python_space cp =
  match cp with
  | 0x09 | 0x0a | 0x0b | 0x0c | 0x0d | 0x20 | 0x1c | 0x1d | 0x1e | 0x1f | 0x85
  | 0xa0 | 0x1680 | 0x2028 | 0x2029 | 0x202f | 0x205f | 0x3000 -> true
  | cp -> cp >= 0x2000 && cp <= 0x200a

let is_line_boundary cp =
  match cp with
  | 0x0a | 0x0b | 0x0c | 0x1c | 0x1d | 0x1e | 0x85 | 0x2028 | 0x2029 -> true
  | _ -> false

let splitlines cps =
  let n = Array.length cps in
  let lines = ref [] in
  let start = ref 0 in
  let i = ref 0 in
  while !i < n do
    let cp = cps.(!i) in
    if is_line_boundary cp then begin
      let stop =
        (* CR LF is one break. *)

        if cp = 0x0d && !i + 1 < n && cps.(!i + 1) = 0x0a then !i + 2 else !i + 1
      in
      lines := Array.sub cps !start (!i - !start) :: !lines;
      start := stop;
      i := stop
    end
    else incr i
  done;
  lines := Array.sub cps !start (n - !start) :: !lines;
  List.rev !lines

let ascii_lower cps =
  Array.map
    (fun cp -> if cp >= 0x41 && cp <= 0x5a then cp + 0x20 else cp)
    cps
