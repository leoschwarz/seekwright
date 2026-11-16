(* Extraction test corpus: fixture files and manifest. *)

module Json = Yojson.Safe

let article_plain = {|<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Harbour ferry timetable changes on Monday — Harbour Bulletin</title>
  <meta name="description" content="The winter timetable starts a week early.">
</head>
<body>
  <header>
    <a href="/">Harbour Bulletin</a>
    <nav><a href="/local">Local</a> <a href="/weather">Weather</a> <a href="/ferry">Ferry</a></nav>
  </header>
  <div class="alert-bar">Sign up for the daily bulletin to get each timetable change by email.</div>
  <main>
    <article>
      <h1>Harbour ferry timetable changes on Monday</h1>
      <p>The winter timetable starts a week early this year, the harbour master said, because the autumn school holidays moved.</p>
      <p>First departure from the east pier stays at 06:12, and the last crossing back leaves the west pier at 22:40 until the end of February.</p>
      <p>Weekend frequencies drop from every fifteen minutes to every half hour, and the late Saturday boat is withdrawn for the winter.</p>
      <p>Season ticket holders are unaffected. The harbour office will reprint the printed timetable in the second week of November.</p>
    </article>
  </main>
  <div class="related-links">
    <h2>Read next</h2>
    <ul>
      <li><a href="/story/one">Why the ferry pier closes at night</a></li>
      <li><a href="/story/two">The last hand-cranked signal lamp</a></li>
      <li><a href="/story/three">Reading a tide table without a phone</a></li>
    </ul>
  </div>
  <div class="cookie-banner">We use cookies to keep this site running and to measure which pages are read. Accept all cookies</div>
  <footer>Copyright 2026 Harbour Bulletin. All rights reserved. Terms, privacy and cookie policy.</footer>
</body>
</html>
|}

let article_no_title = {|<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><script>document.documentElement.className = 'js';</script></head>
<body>
  <div id="shell">
    <div id="main">
      <h1>Harbour lights get a ledger</h1>
      <p>Every lamp on the east pier now has a serial number and a page in a binder, which is how the harbour master says a missing bulb stops being an argument.</p>
      <p>The binder lives in the harbour office, next to the tide tables and the key for the cabinet that nobody can find in winter.</p>
    </div>
  </div>
</body>
</html>
|}

let article_jsonld = {|<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Dock repairs: what closes and when — Harbour Bulletin</title>
  <script type="application/ld+json">
    {"@context":"https://schema.org","@type":"NewsArticle","headline":"Dock repairs",
     "articleBody":"SHOULD NOT APPEAR the structured data body of the page, which is a machine copy of the article.",
     "publisher":{"name":"Harbour Bulletin"}}
  </script>
  <script>window.dataLayer = window.dataLayer || []; window.dataLayer.push({'event':'pageview','title':'Dock repairs'});</script>
  <style>.headline::before { content: "SHOULD NOT APPEAR from a stylesheet string"; }</style>
</head>
<body>
  <article>
    <h1>Dock repairs: what closes and when</h1>
    <p>The north dock closes for eleven weeks from the first working Monday, and the boat lift will be out of service for the first three of those weeks.</p>
    <p>Fishing vessels are rerouted to the south pontoon, and the fuel barge keeps its 07:30 window throughout.</p>
    <p>The harbour master will hold a public meeting in the lifeboat shed on the Thursday after the closure begins.</p>
  </article>
</body>
</html>
|}

let nav_heavy_docs =
  let nav_links =
    List.init 60 (fun i ->
        Printf.sprintf "<li><a href=\"/docs/part-%02d\">Part %02d of the harbour manual</a></li>"
          (i + 1) (i + 1))
  in
  let toc =
    List.init 18 (fun i ->
        Printf.sprintf "<li><a href=\"#s%d\">Section %d</a></li>" (i + 1) (i + 1))
  in
  "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n\
   <title>Section 12 — Mooring lines — Harbour manual</title>\n</head>\n<body>\n\
   " ^ "<div class=\"breadcrumb\"><a href=\"/\">Manual home</a> / \
   <a href=\"/chapter-3\">Chapter 3</a> / <a href=\"/chapter-3/mooring\">Mooring</a> \
   / Section 12</div>\n<div class=\"sidebar\"><ul>"
  ^ String.concat "\n" nav_links
  ^ "</ul></div>\n<div class=\"toc\"><ul>"
  ^ String.concat "\n" toc
  ^ "</ul></div>\n<div class=\"content\">\n<h1>Section 12 — Mooring lines</h1>\n\
   <p>A mooring line is only as good as the splice that ends it, and the manual \
   insists on a long splice because a short one hardens where it bends.</p>\n\
   <p>Line diameters are set by the length of the vessel and by the height of \
   the quay, not by the weather of the day, which is why a list of diameters \
   belongs in a printed chapter rather than in a sign on the wall.</p>\n\
   <p>The chapter closes with the three knots a deckhand is expected to tie \
   with one hand, in the order the examiner asks for them.</p>\n</div>\n\
   <div class=\"pager\"><a href=\"/chapter-3/mooring/s11\">Previous: Section \
   11</a> <a href=\"/chapter-3/mooring/s13\">Next: Section 13</a></div>\n\
   <div class=\"helpful\">Was this section helpful? Yes No</div>\n</body>\n</html>\n"

let nav_heavy_portal =
  let headlines n prefix =
    List.init n (fun i ->
        Printf.sprintf "<li><a href=\"/n/%d\">%s %d: what the harbour board decided this week</a></li>"
          (i + 1) prefix (i + 1))
  in
  "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n\
   <title>Harbour Bulletin — today in the port</title>\n</head>\n<body>\n\
   <header><nav><a href=\"/\">Home</a> <a href=\"/port\">Port</a> <a href=\"/weather\">Weather</a> <a href=\"/jobs\">Jobs</a> <a href=\"/login\">Sign in</a></nav></header>\n\
   <div class=\"subscribe\">Subscribe for 4 a month and read every harbour story on this site without a banner in the way.</div>\n\
   <div class=\"lead\"><h1>One short story under a lot of furniture</h1>\n\
   <p>The east pier will close for three days at the end of the month so the \
   fender timbers can be replaced, and the tenders will use the slipway.</p></div>\n\
   <div class=\"column\"><h2>Most read</h2><ul>"
  ^ String.concat "\n" (headlines 20 "Most read item")
  ^ "</ul></div>\n<div class=\"column\"><h2>Port noticeboard</h2><ul>"
  ^ String.concat "\n" (headlines 20 "Noticeboard item")
  ^ "</ul></div>\n<div class=\"promo\"><h2>Jobs at the port</h2><p>We are hiring a \
   dredger engineer and a harbour office clerk. Send a letter.</p></div>\n\
   <div class=\"footer-links\"><a href=\"/terms\">Terms</a> <a href=\"/privacy\">Privacy</a> \
   <a href=\"/contact\">Contact</a> <a href=\"/ads\">Advertising</a></div>\n\
   <footer>Copyright 2026 Harbour Bulletin. All rights reserved.</footer>\n</body>\n</html>\n"

let malformed_unclosed =
  "<!DOCTYPE html>\n<html>\n<head><title>Unclosed markup — Harbour Bulletin</title>\n\
   <body>\n<div id=shell>\n<article>\n<h1>The pier that was never closed\n</h1>\n\
   <p>Real markup written by a template that ran out of budget: a paragraph that \
   is never closed, a list item that is never closed, and a div left open when \
   the document ends.\n<ul>\n<li>A first item, unclosed\n<li>A second item, also \
   unclosed\n</ul>\n<p>The paragraph after the list is still the article, and a \
   reader of this page cannot tell that the template was careless.\n</article>\n\
   </div>\n"

let malformed_angle_text =
  "<!DOCTYPE html>\n<html><head><title>Angle brackets in prose — Harbour Bulletin</title></head>\n\
   <body><article>\n<h1>Angle brackets in prose</h1>\n\
   <p>If a < b and b < c then the signal lamp is the only honest comparison on \
   this page. A bare < that opens nothing is data, and the sentence has to \
   survive it.</p>\n\
   <p>A stray > in the middle of a sentence is ordinary prose, and 5 > 3 needs \
   no entity to be readable.</p>\n\
   <p>An empty tag pair: <b></b> between words.</p>\n\
   <p>A tag closed with a space: <em >emphasis closed with a space</em >.</p>\n\
   </article></body></html>\n"

let malformed_misnested =
  "<!DOCTYPE html>\n<html><head><title>Mis-nested markup — Harbour Bulletin</title></head>\n\
   <body>\n<article>\n<h1>Mis-nested markup</h1>\n\
   <p>The emphasis crossed over: <b>bold starts <i>and italic starts inside it \
   but bold ends first</b></i>, which is what a 1998 page looked like and what a \
   parser still has to answer for.</p>\n\
   <TABLE>\n<TR><TD>one<TD>two\n<TR><TD>three<TD>four\n</TABLE>\n\
   <P>An uppercase paragraph with a <BR/> break and a <BR> second break.</P>\n\
   <P>An element closed too early: <span>text<span>again</span>closed</span>.</p>\n\
   </article>\n</body></html>\n"

let malformed_attributes =
  (* Attribute runs are where a hand-written tokenizer earns its keep: a [>]
     inside a quoted value, an unquoted value, a boolean attribute with no
     value, and a quote never closed. *)
  "<!DOCTYPE html>\n<html><head><title>Attribute shapes — Harbour Bulletin</title></head>\n\
   <body>\n<article>\n<h1>Attribute shapes</h1>\n\
   <p data-note=\"a > inside a quoted value must not end the tag\">Text kept by a \
   quoted attribute that holds a closing bracket.</p>\n\
   <p data-note=a >Text kept by an unquoted attribute value.</p>\n\
   <input type=checkbox checked>\n\
   <a href=\"x.html\" title=\"kept\">A link whose text must survive</a>\n\
   <p>An attribute value never closed: <span data-x=\"the quote is never \
   closed and the rest of this line is still a page\n\
   <p>Text after an unterminated attribute, which the parser has to recover from.</p>\n\
   </article></body></html>\n"

let malformed_comments =
  "<!DOCTYPE html>\n<html><head><title>Comments — Harbour Bulletin</title>\n\
   <!-- a comment that holds </div> and </script> as text -->\n\
   <!--[if lt IE 9]><p>Old browsers get this paragraph: SHOULD NOT APPEAR</p><![endif]-->\n\
   <style>/* a style rule with </p> inside it: SHOULD NOT APPEAR */</style>\n\
   </head>\n<body>\n<article>\n<h1>Comments and conditional comments</h1>\n\
   <p>None of the markup inside a comment is page text, including a comment that \
   looks like a tag or an old browser-conditional block.</p>\n\
   <p>Second paragraph, after a comment that never closes at the end of the \
   document.</p>\n</article>\n<!-- this comment is never closed\n"

let malformed_script_cdata =
  "<!DOCTYPE html>\n<html><head>\n<title>Script bodies — Harbour Bulletin</title>\n\
   <script>\nvar markup = \"<p>SHOULD NOT APPEAR a paragraph inside a script \
   string</p>\";\nif (a < b && c > d) { console.log('</div>'); }\nvar tail = \"-->\";\n\
   </script>\n<style>a[href^=\"data-\"]::after { content: \"SHOULD NOT APPEAR\"; }\
   </style>\n</head>\n<body>\n<article>\n<h1>Script bodies are data</h1>\n\
   <p>The article has to survive a script body that contains angle brackets, a \
   fake closing tag, and a comment terminator.</p>\n\
   </article></body></html>\n"

let malformed_deep_nesting n =
  (* Depth an element-tree parser would pay stack for, and a stack keyed only to
     the skip list pays a list cell for. The article text sits at the bottom of
     the pit, because the failure mode worth testing is a parser that reaches the
     nesting and never reaches the text. *)
  let opens = String.concat "" (List.init n (fun _ -> "<div>")) in
  let closes = String.concat "" (List.init n (fun _ -> "</div>")) in
  "<!DOCTYPE html>\n<html><head><title>Deep nesting — Harbour Bulletin</title></head>\n\
   <body>" ^ opens
  ^ "<article><h1>Text at the bottom of a deep pit</h1>\n\
     <p>The paragraph under " ^ string_of_int n
     ^ " nested divs has to come back, and the divs around it have to stay \
     invisible.</p></article>" ^ closes ^ "</body></html>\n"

let encoding_utf8_bom =
  "\xef\xbb\xbf" ^ {|<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>A page with a byte-order mark</title></head>
<body>
<article>
<h1>A page that opens with a byte-order mark</h1>
<p>The three bytes before the doctype are the whole difficulty: a parser that decides what a body is by its first bytes has to look past them, and a decoder that keeps the mark as a character puts an invisible U+FEFF at the start of the caller's text.</p>
<p>Text after the mark: ferry, fender, freeboard, and a café on the east pier.</p>
</article>
</body>
</html>
|}

(* Raw Windows-1252 bytes: [0xE9] é, [0x80] euro, [0x92] right single quote,
   [0x93]/[0x94] the double quotes, [0x81] one of the five bytes the codec leaves
   undefined. Every one of them has to arrive as the character the codec says,
   not as the byte. *)
let encoding_cp1252 =
  "<!DOCTYPE html>\r\n<html><head><meta charset=\"windows-1252\">\r\n\
   <title>D\xe9j\xe0 vu \x92 au quai \x93nord\x94</title></head>\r\n\
   <body><article>\r\n\
   <h1>D\xe9j\xe0 vu au quai nord</h1>\r\n\
   <p>Le tarif est de \x804,50 pour un aller simple \x97 et de \x807,20 pour un \
   aller-retour, si le bateau attend.</p>\r\n\
   <p>Noms propres: Z\xfcrich, Goethestra\xdfe, \xd1u\xe1rez, fa\xE7ade, \
   \x93Anhang\x94.</p>\r\n\
   <p>Und eine Zeile auf Deutsch: die F\xe4hre f\xe4hrt alle zwanzig Minuten.</p>\r\n\
   <p>A byte the codec leaves undefined: \x81 sits in this sentence, and the \
   page is still readable around it.</p>\r\n\
   </article></body></html>\r\n"

(* The bytes are Windows-1252; the header says nothing. A reader that honours
   only the header reads mojibake, and the honest metric is how much of the page
   survives anyway. Both oracle backends behave this way, so it is a measurement
   rather than a divergence to fix. *)
let encoding_latin1_undeclared =
  String.concat ""
    [
      "<!DOCTYPE html>\n<html><head><title>Mojibake, honestly measured</title>\
       </head>\n<body><article>\n<h1>Mojibake, honestly measured</h1>\n<p>";
      "D\xe9j\xe0 vu au quai nord: le tarif est de \x804,50 pour un aller \
       simple, et la f\xe9e du quai dit bonjour.";
      "</p>\n<p>The French above is written in Windows-1252 bytes while the \
       header names no charset, so a decoder that trusts the header reads it as \
       UTF-8 and pays for the mistake character by character.</p>\n\
       <p>The English paragraph below is unaffected: the east pier keeps its \
       06:12 departure whatever the header says.</p>\n\
       </article></body></html>\n";
    ]

(* Declared UTF-8, and bytes that are not: a lone continuation byte, a truncated
   sequence, and an overlong-looking one. *)
let encoding_undecodable =
  "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>Undecodable \
   bytes</title></head><body><article>\n<h1>Undecodable bytes inside a declared \
   UTF-8 page</h1>\n\
   <p>A lone continuation byte: \xb7 in the middle of a sentence about the \
   north pier.</p>\n\
   <p>A truncated sequence: \xc3\xa9 is fine, \xc3\x28 is not.</p>\n\
   <p>Text that must survive anyway: the harbour office opens at nine and \
   closes at five.</p>\n\
   </article></body></html>\n"

let entities_soup =
  "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>Entities — \
   Harbour Bulletin</title></head><body>\n\
   <article>\n<h1>Entities, including the ones a page gets wrong</h1>\n\
   <p>Named and numeric: &amp; &lt; &gt; &quot; &copy; &mdash; &ndash; &hellip; \
   &nbsp; &euro; &pound; &sect; and the numeric forms &#8212; &#x2014; &#65; \
   &#x41;.</p>\n\
   <p>Legacy forms with no semicolon: &amp &copy &nbsp at the end of a clause \
   &amp</p>\n\
   <p>Names the table does not have: &notarealname; stays as written, and \
   &notit leaves its tail behind.</p>\n\
   <p>A bare ampersand in prose: Tom & Jerry waited for the 06:12.</p>\n\
   <p>A numeric reference outside the range: &#1114112; and &#0;.</p>\n\
   </article></body></html>\n"

let unicode_multiscript =
  {|<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Mixed scripts — harbour</title></head>
<body>
<article>
<h1>Mixed scripts on one page</h1>
<p>English first: the harbour master keeps a ledger of every lamp.</p>
<p>Deutsch: Die Fähre fährt alle zwanzig Minuten, auch im Winter.</p>
<p>Français : le traversier quitte le quai nord à six heures douze.</p>
<p>Русский: паром отправляется каждые двадцать минут с северного причала.</p>
<p>日本語：北埠頭のフェリーは20分ごとに運航しています。</p>
<p>العربية: تغادر العبارة الرصيف الشمالي كل عشرين دقيقة.</p>
<p>עברית: המעבורה יוצאת מהרציף הצפוני כל עשרים דקה.</p>
<p>Combining marks: é written as e plus U+0301, and a decomposed ü.</p>
<p>Emoji and arrows: the ferry ⛴ leaves at 06:12 → arrives 06:34 ✦.</p>
<p>Special spaces: a no-break space here, an em space here, a zero-width space hidden inside.</p>
<p>Punctuation: «quoted», „german“, ‹single›, — dash, … ellipsis, × ÷ ≤ ≥ ≠.</p>
</article>
</body>
</html>
|}

let js_shell =
  {|<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Harbour live</title>
<script src="/app.js"></script>
<script>window.__INITIAL_STATE__ = {"not":"rendered","body":"SHOULD NOT APPEAR"};</script>
</head>
<body>
<div id="root"></div>
<noscript>This page needs JavaScript to show the live departure board.</noscript>
</body>
</html>
|}

let form_login =
  {|<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Sign in — Harbour Bulletin</title></head>
<body>
<nav><a href="/">Home</a> <a href="/help">Help</a></nav>
<form method="post" action="/login">
  <h1>Sign in to read the harbour ledger</h1>
  <p>The ledger lists every lamp, every inspection, and every bulb changed since 1994, and the harbour office will not publish it as a web page.</p>
  <label>Email <input name="email"></label>
  <label>Password <input type="password" name="pw"></label>
  <button type="submit">Sign in</button>
</form>
<div class="help">No account? The harbour office issues one to anyone who asks at the desk.</div>
</body>
</html>
|}

let table_reference =
  "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>Tide table — \
   Harbour Bulletin</title></head><body>\n\
   <h1>Tide table for the week</h1>\n\
   <table>\n<thead><tr><th>Day</th><th>High water</th><th>Height</th></tr>\
   </thead>\n<tbody>\n"
  ^ String.concat "\n"
      (List.mapi
         (fun i d ->
           Printf.sprintf "<tr><td>%s</td><td>%02d:%02d</td><td>%.1f m</td></tr>"
             d (5 + i) ((i * 17) mod 60) (2.5 +. float_of_int i /. 2.0))
         [
           "Monday"; "Tuesday"; "Wednesday"; "Thursday"; "Friday"; "Saturday";
           "Sunday";
         ])
  ^ "\n</tbody>\n<tfoot><tr><td>Mean spring</td><td colspan=\"2\">3.4 m</td></tr>\
     </tfoot>\n</table>\n\
     <p>Heights are chart datum. The harbour master adds half a metre in a \
     north-westerly.</p>\n</body></html>\n"

let list_hybrid =
  {|<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Knots — Harbour manual</title></head>
<body>
<h1>Knots, in the order the examiner asks</h1>
<dl>
  <dt>Bowline</dt><dd>A fixed loop that will not slip under load and can still be untied after it has been loaded.</dd>
  <dt>Clove hitch</dt><dd>Two half hitches on the bight; the knot a deckhand reaches for first and the one that capsizes first.</dd>
  <dt>Sheet bend</dt><dd>Joins two lines of different diameters, which is the case a reef knot gets wrong.</dd>
</dl>
<h2>The three the examiner calls</h2>
<ol>
  <li>Bowline<li>Round turn and two half hitches
    <ul>
      <li>the turn takes the load</li>
      <li>the half hitches take the turn</li>
    </ul>
  <li>Sheet bend
</ol>
<p>A list item that is never closed is normal markup, and the item after it is still an item.</p>
</body></html>
|}

let svg_sprite =
  {|<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Icons — Harbour Bulletin</title></head>
<body>
<svg style="display:none" xmlns="http://www.w3.org/2000/svg">
  <symbol id="anchor"><title>Anchor icon</title><path d="M1 1"/></symbol>
  <symbol id="ferry"><title>Ferry icon</title><svg viewBox="0 0 2 2"><title>Nested label</title></svg></symbol>
</svg>
<nav><a href="/">Home</a> <a href="/local">Local</a></nav>
<h1>The page that ships its icons inline</h1>
<p>The generator inlined a symbol sheet into every page, so the page now names three icons and one article. Only the article is the answer.</p>
<p>The article continues under the sprite, which is the part a caller needs and the part a graphic title must not become.</p>
</body></html>
|}

let huge_generated words =
  (* A real article length: the oracle's own measurement of a hand-written
     extractor leaking chrome was taken on a 264k-character page, so a corpus
     with no long page measures nothing about cost. *)
  let paragraph i =
    Printf.sprintf
      "<p>Paragraph %d of the harbour survey. The crossing between the two piers \
       takes between eleven and nineteen minutes depending on the tide and on how \
       long the boom takes to come down, and the difference matters most to the \
       people who are already standing on the west pier when the boat leaves the \
       east one.</p>\n"
      (i + 1)
  in
  let n = words / 30 in
  "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>The full harbour \
   survey — Harbour Bulletin</title></head>\n<body>\n\
   <header><nav><a href=\"/\">Home</a> <a href=\"/port\">Port</a></nav></header>\n\
   <article>\n<h1>The full harbour survey</h1>\n"
  ^ String.concat "" (List.init n paragraph)
  ^ "</article>\n<footer>Copyright 2026 Harbour Bulletin.</footer>\n</body>\n\
     </html>\n"

let shared_blocks copies =
  (* The HTML shape of the oracle's shared-stream PDF: markup that is not shared
     by reference the way a PDF object is, but whose effect is the same — the
     output multiplies while the page's own answer stays one paragraph long. *)
  let block =
    "<div class=\"promo\"><h2>Harbour Bulletin newsletter</h2><p>Every harbour \
     story by email, twice a week, with the tide table and the noticeboard \
     attached as a plain text file a reader can print.</p><ul><li><a \
     href=\"/signup\">Subscribe</a></li><li><a href=\"/sample\">Read a sample \
     issue</a></li><li><a href=\"/archive\">Back issues</a></li></ul></div>\n"
  in
  "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>One answer, many \
   promo blocks</title></head>\n<body>\n"
  ^ String.concat "" (List.init copies (fun _ -> block))
  ^ "<article><h1>One answer between the promo blocks</h1>\n\
     <p>The answer this page has is one sentence long: the west pier ramp will \
     be repaved in March, and the tenders keep the 07:30 window while it \
     happens.</p></article>\n</body></html>\n"

let pdf_build objects =
  let out = Buffer.create 8192 in
  Buffer.add_string out "%PDF-1.4\n";
  let offsets = ref [] in
  List.iteri
    (fun i body ->
      offsets := Buffer.length out :: !offsets;
      Buffer.add_string out
        (Printf.sprintf "%d 0 obj\n%s\nendobj\n" (i + 1) body))
    objects;
  let startxref = Buffer.length out in
  Buffer.add_string out (Printf.sprintf "xref\n0 %d\n" (List.length objects + 1));
  Buffer.add_string out "0000000000 65535 f \n";
  List.iter
    (fun o -> Buffer.add_string out (Printf.sprintf "%010d 00000 n \n" o))
    (List.rev !offsets);
  Buffer.add_string out
    (Printf.sprintf "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF"
       (List.length objects + 1) startxref);
  Buffer.contents out

let pdf_stream ?(extra = "") body =
  Printf.sprintf "<< /Length %d%s >>\nstream\n%s\nendstream"
    (String.length body) extra body

let pdf_font =
  "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding \
   /WinAnsiEncoding >>"

let pdf_minimal =
  let text = "The PDF body text says the east pier opens at six twelve" in
  pdf_build
    [
      "<< /Type /Catalog /Pages 2 0 R >>";
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>";
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 4 0 R \
       /Resources << /Font << /F1 5 0 R >> >> >>";
      pdf_stream (Printf.sprintf "BT /F1 12 Tf 20 350 Td (%s) Tj ET" text);
      pdf_font;
    ]

let pdf_two_pages =
  let s1 = "Page one: the north pier keeps a ledger of every lamp" in
  let s2 = "Page two: the ledger lists each bulb changed since 1994" in
  pdf_build
    [
      "<< /Type /Catalog /Pages 2 0 R >>";
      "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>";
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 4 0 R \
       /Resources << /Font << /F1 6 0 R >> >> >>";
      pdf_stream (Printf.sprintf "BT /F1 12 Tf 20 350 Td (%s) Tj ET" s1);
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 6 0 R \
       /Resources << /Font << /F1 7 0 R >> >> >>";
      pdf_stream (Printf.sprintf "BT /F1 12 Tf 20 350 Td (%s) Tj ET" s2);
      pdf_font;
      pdf_font;
    ]

let pdf_kerned_tj =
  (* Text set as a kerned TJ array: reading it means joining the pieces and
     dropping the numbers, which is the difference between a text extractor and
     a byte dumper. *)
  let stream =
    "BT /F1 12 Tf 20 350 Td [(The) -20 (kerned) -30 (line) 15 (is) -10 (only) \
     -25 (readable) 20 (when) -18 (the) -12 (pieces) -30 (are) 10 (joined)] TJ ET"
  in
  pdf_build
    [
      "<< /Type /Catalog /Pages 2 0 R >>";
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>";
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 4 0 R \
       /Resources << /Font << /F1 5 0 R >> >> >>";
      pdf_stream stream;
      pdf_font;
    ]

let pdf_shared_stream pages =
  (* The oracle's grinder, in the same shape: one content stream, referenced by
     every page. The file stays small; the parse work is [pages] times one page's
     work. A byte cap cannot see that multiplication, and this is the fixture a
     PDF backend has to answer inside [fetch.timeout_seconds] or refuse. *)
  let line =
    "(the quick brown fox jumps over the lazy dog) Tj\n1 0 0 1 0 14 Tm\n"
  in
  let stream =
    "BT /F1 12 Tf "
    ^ String.concat "" (List.init 4000 (fun _ -> line))
    ^ "ET"
  in
  (* Objects: 1 catalog, 2 page tree, 3 the shared content stream, 4 the shared
     resources, 5 the font, then one page object per page. *)
  let content_id = 3 in
  let resources_id = 4 in
  let font_id = 5 in
  let first_page = 6 in
  let kids =
    String.concat " "
      (List.init pages (fun i -> Printf.sprintf "%d 0 R" (first_page + i)))
  in
  let page _ =
    Printf.sprintf
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents %d 0 R \
       /Resources %d 0 R >>"
      content_id resources_id
  in
  pdf_build
    ([
        "<< /Type /Catalog /Pages 2 0 R >>";
        Printf.sprintf "<< /Type /Pages /Kids [%s] /Count %d >>" kids pages;
        pdf_stream stream;
        Printf.sprintf "<< /Font << /F1 %d 0 R >> >>" font_id;
        pdf_font;
      ]
    @ List.init pages page)

let pdf_truncated =
  (* A document cut in half: the header and the first objects are there, the xref
     table is not. A reader that trusts only the xref refuses it; a reader that
     rebuilds offsets reads it. Answering with success and no text is the one
     outcome that is not defensible. *)
  let full = pdf_two_pages in
  String.sub full 0 (String.length full / 2)

let pdf_not_a_pdf = "%PDF-1.7\nnot a pdf at all \x00\x00"

let pdf_xref_stream =
  (* A PDF 1.5 document whose cross-reference is a stream object rather than the
     classic table, the shape most modern writers produce. It needs no Flate: the
     stream is uncompressed, so the fixture tests the structure rather than a
     decoder this repository would have to carry. *)
  let s1 = "An xref stream document written without compression" in
  let text_stream = Printf.sprintf "BT /F1 12 Tf 20 350 Td (%s) Tj ET" s1 in
  (* Objects in emission order: 1 catalog, 2 page tree, 3 page, 4 content,
     5 font, 6 the xref stream (written last, by definition). *)
  let body =
    [
      "<< /Type /Catalog /Pages 2 0 R >>";
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>";
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 4 0 R \
       /Resources << /Font << /F1 5 0 R >> >> >>";
      pdf_stream text_stream;
      pdf_font;
    ]
  in
  let out = Buffer.create 4096 in
  Buffer.add_string out "%PDF-1.5\n";
  let offsets = ref [] in
  List.iteri
    (fun i body ->
      offsets := Buffer.length out :: !offsets;
      Buffer.add_string out
        (Printf.sprintf "%d 0 obj\n%s\nendobj\n" (i + 1) body))
    body;
  let xref_offset = Buffer.length out in
  (* A /Type/XRef stream with W = [1 4 2] entries: type 0 free, type 1 with an
     offset, type 2 with an object number and index. Every entry here is type 1
     except object 0, which is free. *)
  let entry kind a b =
    let byte = Char.chr kind in
    let four n =
      String.make 4 (Char.unsafe_chr ((n lsr 24) land 255))
      ^ String.make 4 (Char.unsafe_chr ((n lsr 16) land 255))
      ^ String.make 4 (Char.unsafe_chr ((n lsr 8) land 255))
      ^ String.make 4 (Char.unsafe_chr (n land 255))
    in
    let two n =
      String.make 2 (Char.unsafe_chr ((n lsr 8) land 255))
      ^ String.make 2 (Char.unsafe_chr (n land 255))
    in
    ignore b;
    String.make 1 byte ^ four a ^ two 0
  in
  let stream_data =
    entry 0 0 0
    ^ String.concat ""
        (List.mapi
           (fun _ off -> entry 1 off 0)
           (List.rev !offsets))
  in
  Buffer.add_string out
    (Printf.sprintf "6 0 obj\n<< /Type /XRef /Size 7 /W [1 4 2] /Root 1 0 R \
                     /Length %d >>\nstream\n%s\nendstream\n"
       (String.length stream_data) stream_data);
  Buffer.add_string out (Printf.sprintf "startxref\n%d\n%%%%EOF" xref_offset);
  Buffer.contents out

type case = {
  id : string;
  file : string;
  content_type : string option;
  kind : string;
  category : string;
  essential : string list;
  boilerplate : string list;
  title : string option;
  title_rule : string;
  unicode : string list;
  expect : string;
  body : string;
      (** The fixture's bytes, filled in from [bodies] below: a fixture and the
          case that describes it are written by the same record, so the manifest
          cannot describe a file this program no longer writes. *)

  bar_essential_min : int;
  bar_boiler_max : int;
  bar_title_ok : bool;
  bar_unicode_ok : bool;
  bar_max_ms : int;
  note : string;
}

let utf8 = Some "text/html; charset=utf-8"

let cases : case list =
  [
    {
      id = "article-plain";
      file = "article_plain.html";
      content_type = utf8;
      kind = "html";
      category = "ordinary";
      body = "";
      essential =
        [
          "The winter timetable starts a week early this year";
          "First departure from the east pier stays at 06:12";
          "the last crossing back leaves the west pier at 22:40";
          "Weekend frequencies drop from every fifteen minutes";
          "Season ticket holders are unaffected";
        ];
      boilerplate =
        [
          "Sign up for the daily bulletin";
          "Read next";
          "Why the ferry pier closes at night";
          "We use cookies to keep this site running";
          "Copyright 2026 Harbour Bulletin";
          "Accept all cookies";
          "Local";
        ];
      title = Some "Harbour ferry timetable changes on Monday — Harbour Bulletin";
      title_rule = "exact";
      unicode = ["—"];
      expect = "text";
      bar_essential_min = 5;
      bar_boiler_max = 7;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note =
        "An ordinary article. Its nav, header and footer are in elements the \
         stdlib backend skips, so the measurable furniture is the alert bar, the \
         related-links block and the cookie banner.";
    };
    {
      id = "article-no-title";
      file = "article_no_title.html";
      content_type = utf8;
      kind = "html";
      category = "ordinary";
      body = "";
      essential =
        [
          "Harbour lights get a ledger";
          "Every lamp on the east pier now has a serial number";
          "next to the tide tables and the key for the cabinet";
        ];
      boilerplate = [];
      (* No [title] tag, and neither this port nor the oracle's stdlib backend
         answers a title for it: the rule is [none]. The oracle's trafilatura
         backend does fall back to the first heading, and the table records that
         as its divergence rather than making it this case's bar. *)
      title = None;
      title_rule = "none";
      unicode = [];
      expect = "text";
      bar_essential_min = 3;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note =
        "No <title> element at all. The oracle's stdlib backend reports no \
         title; the bar asks only that the case not be a refusal, and the row \
         records whether the port answers with the heading.";
    };
    {
      id = "article-jsonld";
      file = "article_jsonld.html";
      content_type = utf8;
      kind = "html";
      category = "ordinary";
      body = "";
      essential =
        [
          "The north dock closes for eleven weeks";
          "the boat lift will be out of service";
          "rerouted to the south pontoon";
          "public meeting in the lifeboat shed";
        ];
      boilerplate = ["SHOULD NOT APPEAR"];
      (* Both backends answer with the document's own [title] tag, site suffix
         and all; the JSON-LD headline is what they put in the *body*. So this
         case pins the tag as the title and the headline as an essential phrase. *)
      title = Some "Dock repairs: what closes and when — Harbour Bulletin";
      title_rule = "exact";
      unicode = ["—"];
      expect = "text";
      bar_essential_min = 4;
      bar_boiler_max = 1;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note =
        "A machine copy of the article in JSON-LD, and stylesheet strings: the \
         one case where a leak is not a matter of taste.";
    };
    {
      id = "nav-heavy-docs";
      file = "nav_heavy_docs.html";
      content_type = utf8;
      kind = "html";
      category = "navigation-heavy";
      body = "";
      essential =
        [
          "A mooring line is only as good as the splice";
          "Line diameters are set by the length of the vessel";
          "the three knots a deckhand is expected to tie";
        ];
      boilerplate =
        [
          "Part 01 of the harbour manual";
          "Part 60 of the harbour manual";
          "Section 1</a>";
          "Manual home";
          "Previous: Section 11";
          "Was this section helpful?";
        ];
      title = Some "Section 12 — Mooring lines — Harbour manual";
      title_rule = "exact";
      unicode = ["—"];
      expect = "text";
      bar_essential_min = 3;
      bar_boiler_max = 6;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 27;
      note =
        "A documentation page: 78 links and a breadcrumb trail around three \
         paragraphs, none of the furniture in an element the skip list names.";
    };
    {
      id = "nav-heavy-portal";
      file = "nav_heavy_portal.html";
      content_type = utf8;
      kind = "html";
      category = "navigation-heavy";
      body = "";
      essential =
        [
          "The east pier will close for three days at the end of the month";
          "the tenders will use the slipway";
        ];
      boilerplate =
        [
          "Most read item 1:";
          "Most read item 20:";
          "Noticeboard item 20:";
          "Subscribe for 4 a month";
          "We are hiring a dredger engineer";
          "Advertising";
          "Copyright 2026 Harbour Bulletin";
        ];
      title = Some "Harbour Bulletin — today in the port";
      title_rule = "exact";
      unicode = ["—"];
      expect = "text";
      bar_essential_min = 2;
      bar_boiler_max = 7;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 26;
      note = "A portal front page: two link columns of 20 items each around one \
             short story.";
    };
    {
      id = "malformed-unclosed";
      file = "malformed_unclosed.html";
      content_type = utf8;
      kind = "html";
      category = "malformed";
      body = "";
      essential =
        [
          "The pier that was never closed";
          "a paragraph that is never closed";
          "A first item, unclosed";
          "A second item, also unclosed";
          "the template was careless";
        ];
      boilerplate = [];
      title = Some "Unclosed markup — Harbour Bulletin";
      title_rule = "exact";
      unicode = ["—"];
      expect = "text";
      bar_essential_min = 5;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "The most common malformation there is, and the one a page cannot \
              be refused for.";
    };
    {
      id = "malformed-angle-text";
      file = "malformed_angle_text.html";
      content_type = utf8;
      kind = "html";
      category = "malformed";
      body = "";
      essential =
        [
          "Angle brackets in prose";
          "If a < b and b < c then the signal lamp";
          "A stray > in the middle of a sentence";
          "An empty tag pair";
        ];
      boilerplate = [];
      title = Some "Angle brackets in prose — Harbour Bulletin";
      title_rule = "exact";
      unicode = ["—"; "<"; ">"];
      expect = "text";
      bar_essential_min = 4;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "A parser that treats every < as the start of a tag loses a \
              paragraph here and reports nothing about it.";
    };
    {
      id = "malformed-misnested";
      file = "malformed_misnested.html";
      content_type = utf8;
      kind = "html";
      category = "malformed";
      body = "";
      essential =
        [
          "The emphasis crossed over";
          "bold ends first";
          "which is what a 1998 page looked like";
          "An uppercase paragraph with a";
          "break and a";
          "second break";
        ];
      boilerplate = [];
      title = Some "Mis-nested markup — Harbour Bulletin";
      title_rule = "exact";
      unicode = ["—"];
      expect = "text";
      bar_essential_min = 6;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "Crossed emphasis, implicit table closes, and the uppercase forms a \
              1998 page wrote.";
    };
    {
      id = "malformed-attributes";
      file = "malformed_attributes.html";
      content_type = utf8;
      kind = "html";
      category = "malformed";
      body = "";
      essential =
        [
          "Text kept by a quoted attribute that holds a closing bracket";
          "Text kept by an unquoted attribute value";
          "A link whose text must survive";
          "Text after an unterminated attribute";
        ];
      boilerplate = [];
      title = Some "Attribute shapes — Harbour Bulletin";
      title_rule = "exact";
      unicode = ["—"];
      expect = "text";
      bar_essential_min = 4;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note =
        "The attribute run is where a hand-written tokenizer earns its keep. The \
         unterminated quote at the end of a line is the one case where no \
         parser can recover the same way twice, so its phrase is not in the bar.";
    };
    {
      id = "malformed-comments";
      file = "malformed_comments.html";
      content_type = utf8;
      kind = "html";
      category = "malformed";
      body = "";
      essential =
        [
          "Comments and conditional comments";
          "None of the markup inside a comment is page text";
          "Second paragraph, after a comment that never closes";
        ];
      boilerplate = ["SHOULD NOT APPEAR"];
      title = Some "Comments — Harbour Bulletin";
      title_rule = "exact";
      unicode = [];
      expect = "text";
      bar_essential_min = 3;
      bar_boiler_max = 1;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "A comment that holds markup, an old-IE conditional, and a comment \
              left open at end of file.";
    };
    {
      id = "malformed-script-cdata";
      file = "malformed_script_cdata.html";
      content_type = utf8;
      kind = "html";
      category = "malformed";
      body = "";
      essential =
        [
          "Script bodies are data";
          "a script body that contains angle brackets";
        ];
      boilerplate = ["SHOULD NOT APPEAR"; "console.log"];
      title = Some "Script bodies — Harbour Bulletin";
      title_rule = "exact";
      unicode = [];
      expect = "text";
      bar_essential_min = 2;
      bar_boiler_max = 2;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "Script and style bodies that hold markup-looking text, a fake \
              closing tag, and a comment terminator.";
    };
    {
      id = "malformed-deep-nesting";
      file = "malformed_deep_nesting.html";
      content_type = utf8;
      kind = "html";
      category = "adversarial";
      body = "";
      essential = ["Text at the bottom of a deep pit"; "nested divs has to come back"];
      boilerplate = [];
      title = Some "Deep nesting — Harbour Bulletin";
      title_rule = "exact";
      unicode = [];
      expect = "text";
      bar_essential_min = 2;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 43;
      note = "Adversarial nesting: 2000 unclosed divs with the answer at the \
              bottom. The bar is a loose ceiling that catches a parser that \
              goes quadratic or runs out of stack at this depth.";
    };
    {
      id = "encoding-utf8-bom";
      file = "encoding_utf8_bom.html";
      content_type = utf8;
      kind = "html";
      category = "encoding";
      body = "";
      essential =
        [
          "A page that opens with a byte-order mark";
          "has to look past them";
          "Text after the mark: ferry, fender, freeboard, and a café on the east pier";
        ];
      boilerplate = [];
      title = Some "A page with a byte-order mark";
      title_rule = "exact";
      unicode = ["café"];
      expect = "text";
      bar_essential_min = 3;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note =
        "The bar is two of three: the paragraph that explains the mark contains \
         U+FEFF in its own wording, which is the case, not a failure to find it.";
    };
    {
      id = "encoding-cp1252";
      file = "encoding_cp1252.html";
      content_type = Some "text/html; charset=windows-1252";
      kind = "html";
      category = "encoding";
      body = "";
      essential =
        [
          "Déjà vu au quai nord";
          "Le tarif est de €4,50 pour un aller simple";
          "Zürich, Goethestraße, Ñuárez, façade";
          "die Fähre fährt alle zwanzig Minuten";
        ];
      boilerplate = [];
      title = Some "Déjà vu ’ au quai “nord”";
      title_rule = "exact";
      unicode = ["é"; "€"; "—"; "“"; "”"; "×"; "ß"; "Ñ"; "ç"];
      expect = "text";
      bar_essential_min = 4;
      bar_boiler_max = 0;
      bar_title_ok = false;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "Raw Windows-1252 bytes with the charset declared, including the \
              euro byte and one of the five bytes the codec leaves undefined.";
    };
    {
      id = "encoding-latin1-undeclared";
      file = "encoding_latin1_undeclared.html";
      content_type = Some "text/html";
      kind = "html";
      category = "encoding";
      body = "";
      essential =
        [
          "Mojibake, honestly measured";
          "The English paragraph below is unaffected: the east pier keeps its 06:12 departure";
        ];
      boilerplate = [];
      title = Some "Mojibake, honestly measured";
      title_rule = "exact";
      unicode = [];
      expect = "text";
      bar_essential_min = 2;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note =
        "Windows-1252 bytes, no charset in the header. Both oracle backends \
         decode by the header and read mojibake, so the bar asks for the English \
         half and the row records the replacement count.";
    };
    {
      id = "encoding-undecodable";
      file = "encoding_undecodable.html";
      content_type = utf8;
      kind = "html";
      category = "encoding";
      body = "";
      essential =
        [
          "Undecodable bytes inside a declared UTF-8 page";
          "in the middle of a sentence about the north pier";
          "the harbour office opens at nine and closes at five";
        ];
      boilerplate = [];
      title = Some "Undecodable bytes";
      title_rule = "exact";
      unicode = ["\u{FFFD}"];
      expect = "text";
      bar_essential_min = 3;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "Bad bytes inside a declared UTF-8 page: the page survives, and the \
              replacement count is the row that differs between backends.";
    };
    {
      id = "entities-soup";
      file = "entities_soup.html";
      content_type = utf8;
      kind = "html";
      category = "encoding";
      body = "";
      essential =
        [
          "Named and numeric:";
          "Legacy forms with no semicolon";
          "A bare ampersand in prose: Tom & Jerry waited for the 06:12";
          "A numeric reference outside the range";
        ];
      boilerplate = [];
      title = Some "Entities — Harbour Bulletin";
      title_rule = "exact";
      unicode = ["&"; "“"; "€"; "£"; "§"; "—"; "…"];
      expect = "text";
      bar_essential_min = 4;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "Every reference form a page actually writes, plus the ones it gets \
              wrong: an unknown name, a bare ampersand, and out-of-range \
              numerics. Both implementations have to answer the same way, which \
              is what makes the differential row worth having.";
    };
    {
      id = "unicode-multiscript";
      file = "unicode_multiscript.html";
      content_type = utf8;
      kind = "html";
      category = "non-ascii";
      body = "";
      essential =
        [
          "Mixed scripts on one page";
          "Die Fähre fährt alle zwanzig Minuten";
          "le traversier quitte le quai nord";
          "паром отправляется каждые двадцать минут";
          "北埠頭のフェリーは20分ごとに運航しています";
          "تغادر العبارة الرصيف الشمالي";
          "המעבורה יוצאת מהרציף הצפוני";
        ];
      boilerplate = [];
      title = Some "Mixed scripts — harbour";
      title_rule = "exact";
      unicode =
        [
          "Ä";
          "ф";
          "北埠頭";
          "العبارة";
          "המעבורה";
          "⛴";
          "→";
          "«quoted»";
          "„german“";
        ];
      expect = "text";
      bar_essential_min = 7;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "Eight scripts in one page, with combining marks and the special \
              spaces a caller can mistake for a paragraph break.";
    };
    {
      id = "js-shell";
      file = "js_shell.html";
      content_type = utf8;
      kind = "html";
      category = "shell";
      body = "";
      essential = [];
      boilerplate = ["SHOULD NOT APPEAR"];
      title = Some "Harbour live";
      title_rule = "exact";
      unicode = [];
      expect = "empty";
      bar_essential_min = 0;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "A rendered shell: an empty root element and JSON in a script tag. \
              The honest extraction is empty, and the engine turns that into a \
              notice.";
    };
    {
      id = "form-login";
      file = "form_login.html";
      content_type = utf8;
      kind = "html";
      category = "documented-loss";
      body = "";
      essential = ["No account? The harbour office issues one to anyone"];
      boilerplate = ["Sign in to read the harbour ledger"];
      title = Some "Sign in — Harbour Bulletin";
      title_rule = "exact";
      unicode = [];
      expect = "text";
      bar_essential_min = 1;
      bar_boiler_max = 1;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "The cost of the skip list, recorded rather than hidden: an article \
              inside a <form> goes with the form, and the caller gets a refusal.";
    };
    {
      id = "table-reference";
      file = "table_reference.html";
      content_type = utf8;
      kind = "html";
      category = "structure";
      body = "";
      essential = ["Tide table for the week"; "Monday"; "High water"; "Mean spring"];
      boilerplate = [];
      title = Some "Tide table — Harbour Bulletin";
      title_rule = "exact";
      unicode = ["—"];
      expect = "text";
      bar_essential_min = 4;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "A reference table, where the cell boundary is the answer.";
    };
    {
      id = "list-hybrid";
      file = "list_hybrid.html";
      content_type = utf8;
      kind = "html";
      category = "structure";
      body = "";
      essential =
        [
          "Knots, in the order the examiner asks";
          "A fixed loop that will not slip under load";
          "the half hitches take the turn";
          "the item after it is still an item";
        ];
      boilerplate = [];
      title = Some "Knots — Harbour manual";
      title_rule = "exact";
      unicode = [];
      expect = "text";
      bar_essential_min = 4;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "Definition list, nested lists, and unclosed items.";
    };
    {
      id = "svg-sprite";
      file = "svg_sprite.html";
      content_type = utf8;
      kind = "html";
      category = "adversarial";
      body = "";
      essential =
        [
          "The page that ships its icons inline";
          "Only the article is the answer";
          "the part a graphic title must not become";
        ];
      boilerplate = ["Anchor icon"; "Ferry icon"; "Nested label"];
      title = Some "Icons — Harbour Bulletin";
      title_rule = "exact";
      unicode = [];
      expect = "text";
      bar_essential_min = 3;
      bar_boiler_max = 3;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "An inline icon sheet that nests a graphic inside a graphic and \
              repeats the title element.";
    };
    {
      id = "huge-article";
      file = "huge_generated.html";
      content_type = utf8;
      kind = "html";
      category = "huge";
      body = "";
      essential =
        [
          "The full harbour survey";
          "Paragraph 1 of the harbour survey";
          "Paragraph 300 of the harbour survey";
          "Paragraph 600 of the harbour survey";
        ];
      boilerplate = ["Home"; "Port"; "Copyright 2026 Harbour Bulletin."];
      title = Some "The full harbour survey — Harbour Bulletin";
      title_rule = "exact";
      unicode = ["—"];
      expect = "text";
      bar_essential_min = 4;
      bar_boiler_max = 3;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 148;
      note = "Cost case: 18 000 words, with the answer spread across the page so \
              a truncating or quadratic reader shows up in the row.";
    };
    {
      id = "shared-blocks";
      file = "shared_blocks.html";
      content_type = utf8;
      kind = "html";
      category = "shared";
      body = "";
      essential = ["One answer between the promo blocks"; "the west pier ramp will be repaved in March"];
      boilerplate =
        [
          "Harbour Bulletin newsletter";
          "Read a sample issue";
          "Back issues</a>";
        ];
      title = Some "One answer, many promo blocks";
      title_rule = "exact";
      unicode = [];
      expect = "text";
      bar_essential_min = 2;
      bar_boiler_max = 3;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 46;
      note = "The HTML shape of the oracle's shared-stream PDF: 120 copies of one \
              promo block, so the extraction's volume is a multiple of the \
              answer's while the page's own content stays one paragraph.";
    };
    {
      id = "pdf-minimal";
      file = "pdf_minimal.pdf";
      content_type = Some "application/pdf";
      kind = "pdf";
      category = "pdf";
      body = "";
      essential = ["The PDF body text says the east pier opens at six twelve"];
      boilerplate = [];
      title = None;
      title_rule = "none";
      unicode = [];
      expect = "refusal";
      bar_essential_min = 0;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "A one-page PDF with a real xref table, written out by hand, the \
              oracle's own fixture shape. The oracle's trafilatura backend reads \
              it; this port refuses it by media type. The PDF decision lives in \
              plans/seekwright-ocaml-port.md.";
    };
    {
      id = "pdf-two-pages";
      file = "pdf_two_pages.pdf";
      content_type = Some "application/pdf";
      kind = "pdf";
      category = "pdf";
      body = "";
      essential =
        [
          "Page one: the north pier keeps a ledger of every lamp";
          "Page two: the ledger lists each bulb changed since 1994";
        ];
      boilerplate = [];
      title = None;
      title_rule = "none";
      unicode = [];
      expect = "refusal";
      bar_essential_min = 0;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "Two pages, each with its own content stream.";
    };
    {
      id = "pdf-kerned-tj";
      file = "pdf_kerned_tj.pdf";
      content_type = Some "application/pdf";
      kind = "pdf";
      category = "pdf";
      body = "";
      essential = ["The kerned line is only readable when the pieces are joined"];
      boilerplate = [];
      title = None;
      title_rule = "none";
      unicode = [];
      expect = "refusal";
      bar_essential_min = 0;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "Text set as a kerned TJ array, which separates a text extractor \
              from a byte dumper.";
    };
    {
      id = "pdf-shared-stream";
      file = "pdf_shared_stream.pdf";
      content_type = Some "application/pdf";
      kind = "pdf";
      category = "pdf";
      body = "";
      essential = [];
      boilerplate = [];
      title = None;
      title_rule = "none";
      unicode = [];
      expect = "refusal";
      bar_essential_min = 0;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "The oracle's grinder: one large content stream referenced by every \
              page, so parse work scales with the page count while the file \
              stays far under the download cap. Any PDF backend added to this \
              port has to answer inside fetch.timeout_seconds or refuse.";
    };
    {
      id = "pdf-truncated";
      file = "pdf_truncated.pdf";
      content_type = Some "application/pdf";
      kind = "pdf";
      category = "pdf";
      body = "";
      essential = [];
      boilerplate = [];
      title = None;
      title_rule = "none";
      unicode = [];
      expect = "refusal";
      bar_essential_min = 0;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "Cut in half: the objects are there, the xref table is not. The one \
              outcome that is never defensible is success with no text.";
    };
    {
      id = "pdf-xref-stream";
      file = "pdf_xref_stream.pdf";
      content_type = Some "application/pdf";
      kind = "pdf";
      category = "pdf";
      body = "";
      essential = ["An xref stream document written without compression"];
      boilerplate = [];
      title = None;
      title_rule = "none";
      unicode = [];
      expect = "refusal";
      bar_essential_min = 0;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "A PDF 1.5 document whose cross-reference is a stream object, the \
              shape modern writers produce, written without a compression filter \
              so the fixture tests structure rather than a decoder.";
    };
    {
      id = "pdf-not-a-pdf";
      file = "pdf_not_a_pdf.pdf";
      content_type = Some "application/pdf";
      kind = "pdf";
      category = "pdf";
      body = "";
      essential = [];
      boilerplate = [];
      title = None;
      title_rule = "none";
      unicode = [];
      expect = "refusal";
      bar_essential_min = 0;
      bar_boiler_max = 0;
      bar_title_ok = true;
      bar_unicode_ok = true;
      bar_max_ms = 25;
      note = "The oracle's own bytes for this case, NUL included.";
    };
  ]

(* The case record carries its body; keeping it in the same record means the
   manifest and the fixture can never be written from different sources. *)
let with_bodies (c : case) (bodies : (string * string) list) =
  match List.assoc_opt c.file bodies with
  | Some b -> { c with body = b }
  | None -> invalid_arg ("no fixture body for " ^ c.file)

let bodies =
  [
    ("article_plain.html", article_plain);
    ("article_no_title.html", article_no_title);
    ("article_jsonld.html", article_jsonld);
    ("nav_heavy_docs.html", nav_heavy_docs);
    ("nav_heavy_portal.html", nav_heavy_portal);
    ("malformed_unclosed.html", malformed_unclosed);
    ("malformed_angle_text.html", malformed_angle_text);
    ("malformed_misnested.html", malformed_misnested);
    ("malformed_attributes.html", malformed_attributes);
    ("malformed_comments.html", malformed_comments);
    ("malformed_script_cdata.html", malformed_script_cdata);
    ("malformed_deep_nesting.html", malformed_deep_nesting 2000);
    ("encoding_utf8_bom.html", encoding_utf8_bom);
    ("encoding_cp1252.html", encoding_cp1252);
    ("encoding_latin1_undeclared.html", encoding_latin1_undeclared);
    ("encoding_undecodable.html", encoding_undecodable);
    ("entities_soup.html", entities_soup);
    ("unicode_multiscript.html", unicode_multiscript);
    ("js_shell.html", js_shell);
    ("form_login.html", form_login);
    ("table_reference.html", table_reference);
    ("list_hybrid.html", list_hybrid);
    ("svg_sprite.html", svg_sprite);
    ("huge_generated.html", huge_generated 18000);
    ("shared_blocks.html", shared_blocks 120);
    ("pdf_minimal.pdf", pdf_minimal);
    ("pdf_two_pages.pdf", pdf_two_pages);
    ("pdf_kerned_tj.pdf", pdf_kerned_tj);
    ("pdf_shared_stream.pdf", pdf_shared_stream 10);
    ("pdf_truncated.pdf", pdf_truncated);
    ("pdf_xref_stream.pdf", pdf_xref_stream);
    ("pdf_not_a_pdf.pdf", pdf_not_a_pdf);
  ]

let cases = List.map (fun c -> with_bodies c bodies) cases

let manifest_json () =
  Json.pretty_to_string
    (`Assoc
      [
        ("corpus", `String "f6-2-extraction");
        ("version", `Int 1);
        ( "generator",
          `String "ocaml-tools/extract_bench/gen_fixtures.ml" );
        ("license", `String "Apache-2.0");
        ( "note",
          `String
            "Every fixture is generated by the named program: it is written for \
             this repository rather than collected, which is what makes the \
             corpus shippable and re-runnable. Regenerate with [dune exec \
             ocaml-tools/extract_bench/gen_fixtures.exe -- --write <dir>]." );
        ( "cases",
          `List
            (List.map
               (fun c ->
                 `Assoc
                   [
                     ("id", `String c.id);
                     ("file", `String c.file);
                     ( "content_type",
                       match c.content_type with
                       | Some s -> `String s
                       | None -> `Null );
                     ("kind", `String c.kind);
                     ("category", `String c.category);
                     ( "essential",
                       `List (List.map (fun s -> `String s) c.essential) );
                     ( "boilerplate",
                       `List (List.map (fun s -> `String s) c.boilerplate) );
                     ( "title",
                       match c.title with Some s -> `String s | None -> `Null );
                     ("title_rule", `String c.title_rule);
                     ("unicode", `List (List.map (fun s -> `String s) c.unicode));
                     ("expect", `String c.expect);
                     ("bar_essential_min", `Int c.bar_essential_min);
                     ("bar_boiler_max", `Int c.bar_boiler_max);
                     ("bar_title_ok", `Bool c.bar_title_ok);
                     ("bar_unicode_ok", `Bool c.bar_unicode_ok);
                     ("bar_max_ms", `Int c.bar_max_ms);
                     ("note", `String c.note);
                   ])
               cases) );
      ])
  ^ "\n"

let write_file dir name (bytes : string) =
  let oc = open_out_bin (Filename.concat dir name) in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_substring oc bytes 0 (String.length bytes))

let read_file path =
  if Sys.file_exists path then
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    Some s
  else None

let usage () =
  prerr_endline "usage: gen_fixtures (--write|--check) <corpus-dir>";
  exit 2

let ensure_dir d = if not (Sys.file_exists d) then Unix.mkdir d 0o755

let write_corpus dir =
  let fixtures = Filename.concat dir "fixtures" in
  ensure_dir dir;
  ensure_dir fixtures;
  List.iter (fun c -> write_file fixtures c.file c.body) cases;
  write_file dir "cases.json" (manifest_json ());
  Printf.printf "wrote %d fixtures to %s\n" (List.length cases) dir

let check_corpus dir =
  let fixtures = Filename.concat dir "fixtures" in
  let fails = ref 0 in
  let fail fmt = Format.kasprintf (fun s -> incr fails; prerr_endline s) fmt in
  List.iter
    (fun c ->
      let path = Filename.concat fixtures c.file in
      match read_file path with
      | None -> fail "%s: missing fixture %s" c.id path
      | Some got ->
          if got <> c.body then
            fail "%s: %s is %d bytes and gen_fixtures writes %d: the fixture no \
                   longer matches its generator" c.id c.file
              (String.length got) (String.length c.body))
    cases;
  (match read_file (Filename.concat dir "cases.json") with
  | None -> fail "missing cases.json in %s" dir
  | Some got ->
      if got <> manifest_json () then
        fail "cases.json no longer matches the generated manifest");
  if !fails > 0 then (
    prerr_endline
      (Printf.sprintf
         "%d corpus file(s) out of date: regenerate with [gen_fixtures --write \
          %s] and commit the result" !fails dir);
    exit 1)

let () =
  match Array.to_list Sys.argv with
  | [ _; "--write"; dir ] -> write_corpus dir
  | [ _; "--check"; dir ] -> check_corpus dir
  | _ -> usage ()
