(* Sorted disjoint non-printable ranges: Unicode 16.0 categories
   [Cc Cf Cs Co Zl Zp Zs] minus U+0020 for binary search. *)
let non_printable =
  [|
    (0x0000, 0x001f);
    (0x007f, 0x00a0);
    (0x00ad, 0x00ad);
    (0x0600, 0x0605);
    (0x061c, 0x061c);
    (0x06dd, 0x06dd);
    (0x070f, 0x070f);
    (0x0890, 0x0891);
    (0x08e2, 0x08e2);
    (0x1680, 0x1680);
    (0x180e, 0x180e);
    (0x2000, 0x200f);
    (0x2028, 0x202f);
    (0x205f, 0x2064);
    (0x2066, 0x206f);
    (0x3000, 0x3000);
    (0xd800, 0xf8ff);
    (0xfeff, 0xfeff);
    (0xfff9, 0xfffb);
    (0x110bd, 0x110bd);
    (0x110cd, 0x110cd);
    (0x13430, 0x1343f);
    (0x1bca0, 0x1bca3);
    (0x1d173, 0x1d17a);
    (0xe0001, 0xe0001);
    (0xe0020, 0xe007f);
    (0xf0000, 0xffffd);
    (0x100000, 0x10fffd);
  |]

let is_non_printable cp =
  let lo = ref 0 and hi = ref (Array.length non_printable - 1) in
  let found = ref false in
  while !lo <= !hi && not !found do
    let mid = (!lo + !hi) / 2 in
    let a, b = non_printable.(mid) in
    if cp < a then hi := mid - 1 else if cp > b then lo := mid + 1 else found := true
  done;
  !found

let py_repr (value : string) : string =
  let cps = Utf8.of_string value in
  let has_single = Array.exists (fun cp -> cp = 0x27) cps in
  let has_double = Array.exists (fun cp -> cp = 0x22) cps in
  let quote = if has_single && not has_double then '"' else '\'' in
  let quote_code = Char.code quote in
  let buffer = Buffer.create (String.length value + 8) in
  Buffer.add_char buffer quote;
  Array.iter
    (fun cp ->
      if cp = quote_code then begin
        Buffer.add_char buffer '\\';
        Buffer.add_char buffer quote
      end
      else
        match cp with
        | 0x0a -> Buffer.add_string buffer "\\n"
        | 0x0d -> Buffer.add_string buffer "\\r"
        | 0x09 -> Buffer.add_string buffer "\\t"
        | 0x5c -> Buffer.add_string buffer "\\\\"
        | cp when is_non_printable cp ->
            Buffer.add_string buffer
              (if cp < 0x100 then Printf.sprintf "\\x%02x" cp
               else if cp < 0x10000 then Printf.sprintf "\\u%04x" cp
               else Printf.sprintf "\\U%08x" cp)
        | cp -> Buffer.add_string buffer (Utf8.encode cp))
    cps;
  Buffer.add_char buffer quote;
  Buffer.contents buffer
