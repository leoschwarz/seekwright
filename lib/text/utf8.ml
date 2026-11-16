type t = int array

type codepoint = { idx : int; width : int }

(* Maximal subpart byte step. Ill-formed or overlong leads ([0xC0..0xC1],
   [0xF8..0xFF]) step by 1; surrogate lead [0xED] bounds continuations to [0x80..0x9F]. *)
let lead_width s i =
  let len = String.length s in
  let byte at = Char.code s.[at] in
  let cont at lo hi = at < len && byte at >= lo && byte at <= hi in
  let c = byte i in
  if c < 0x80 then 1
  else if c < 0xC2 then 1 (* a continuation byte or an overlong lead *)
  else if c <= 0xDF then if cont (i + 1) 0x80 0xBF then 2 else 1
  else if c <= 0xEF then begin
    let lo, hi =
      if c = 0xE0 then (0xA0, 0xBF) else if c = 0xED then (0x80, 0x9F) else (0x80, 0xBF)
    in
    if not (cont (i + 1) lo hi) then 1 else if cont (i + 2) 0x80 0xBF then 3 else 2
  end
  else if c <= 0xF4 then begin
    let lo, hi =
      if c = 0xF0 then (0x90, 0xBF) else if c = 0xF4 then (0x80, 0x8F) else (0x80, 0xBF)
    in
    if not (cont (i + 1) lo hi) then 1
    else if not (cont (i + 2) 0x80 0xBF) then 2
    else if cont (i + 3) 0x80 0xBF then 4
    else 3
  end
  else 1

let next_index s i =
  let len = String.length s in
  let at = i + lead_width s i in
  if at > len then len else at

let codepoints s =
  let acc = ref [] in
  let i = ref 0 in
  let len = String.length s in
  while !i < len do
    let next = next_index s !i in
    acc := { idx = !i; width = next - !i } :: !acc;
    i := next
  done;
  List.rev !acc

let count s =
  let n = ref 0 in
  let i = ref 0 in
  let len = String.length s in
  while !i < len do
    i := next_index s !i;
    incr n
  done;
  !n

let slices s = Array.of_list (List.map (fun cp -> String.sub s cp.idx cp.width) (codepoints s))

let take limit s =
  let target = max limit 0 in
  let len = String.length s in
  let seen = ref 0 in
  let i = ref 0 in
  while !i < len && !seen < target do
    i := next_index s !i;
    incr seen
  done;
  String.sub s 0 !i

let of_string s =
  let len = String.length s in
  let cps = ref [] in
  let i = ref 0 in
  while !i < len do
    let next = next_index s !i in
    let cp =
      match next - !i with
      | 1 -> if Char.code s.[!i] < 0x80 then Char.code s.[!i] else 0xFFFD
      | 2 -> ((Char.code s.[!i] land 0x1f) lsl 6) lor (Char.code s.[!i + 1] land 0x3f)
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
    i := next
  done;
  Array.of_list (List.rev !cps)

let utf8_width cp = if cp < 0x80 then 1 else if cp < 0x800 then 2 else if cp < 0x10000 then 3 else 4

let encode cp =
  String.init (utf8_width cp) (fun i ->
      match utf8_width cp with
      | 1 -> Char.chr cp
      | 2 -> if i = 0 then Char.chr (0xc0 lor (cp lsr 6)) else Char.chr (0x80 lor (cp land 0x3f))
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
  let bytes = Array.fold_left (fun acc cp -> acc + utf8_width cp) 0 cps in
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
  | 0x09 | 0x0a | 0x0b | 0x0c | 0x0d | 0x20 | 0x1c | 0x1d | 0x1e | 0x1f | 0x85 | 0xa0 | 0x1680
  | 0x2028 | 0x2029 | 0x202f | 0x205f | 0x3000 ->
      true
  | cp -> cp >= 0x2000 && cp <= 0x200a

let lstrip s =
  let a = of_string s in
  let n = Array.length a in
  let i = ref 0 in
  while !i < n && is_python_space a.(!i) do
    incr i
  done;
  if !i = 0 then s else to_string (Array.sub a !i (n - !i))

let rstrip s =
  let a = of_string s in
  let n = Array.length a in
  let j = ref (n - 1) in
  while !j >= 0 && is_python_space a.(!j) do
    decr j
  done;
  if !j = n - 1 then s else to_string (Array.sub a 0 (!j + 1))

let strip s = lstrip (rstrip s)

let split_whitespace s =
  let a = of_string s in
  let n = Array.length a in
  let words = ref [] in
  let start = ref 0 in
  let in_word = ref false in
  for i = 0 to n - 1 do
    if is_python_space a.(i) then
      begin if !in_word then begin
        words := to_string (Array.sub a !start (i - !start)) :: !words;
        in_word := false
      end
      end
    else if not !in_word then begin
      in_word := true;
      start := i
    end
  done;
  if !in_word then words := to_string (Array.sub a !start (n - !start)) :: !words;
  List.rev !words

let is_line_boundary cp =
  match cp with
  | 0x0a | 0x0d | 0x0b | 0x0c | 0x1c | 0x1d | 0x1e | 0x85 | 0x2028 | 0x2029 -> true
  | _ -> false

let splitlines cps =
  let n = Array.length cps in
  let lines = ref [] in
  let start = ref 0 in
  let i = ref 0 in
  while !i < n do
    let cp = cps.(!i) in
    if is_line_boundary cp then begin
      let stop = if cp = 0x0d && !i + 1 < n && cps.(!i + 1) = 0x0a then !i + 2 else !i + 1 in
      lines := Array.sub cps !start (!i - !start) :: !lines;
      start := stop;
      i := stop
    end
    else incr i
  done;
  if !start < n then lines := Array.sub cps !start (n - !start) :: !lines;
  List.rev !lines

let ascii_lower cps = Array.map (fun cp -> if cp >= 0x41 && cp <= 0x5a then cp + 0x20 else cp) cps
