# Extraction corpus: the three backends measured

> Printed on 2026-11-14 by [ocaml-tools/extract_bench/metrics_table.py], a script
> that went with the implementation it ran.
> Tree 413a853 (dirty); Linux 6.12.113+deb13-amd64, x86_64; trafilatura 2.3.1; Python 3.14.10.
> Timing is a property of that machine, not of the tree; the content columns are.
> The bar the gate enforces is per case in [cases.json]; this table is the
> measurement that bar was derived from, beside the two oracle backends.

`essential` is the share of the page's essential phrases the answer holds;
`boiler` is the furniture it leaked (lower is better); `codepoints` is the volume it
returned; `U+FFFD` is what its decoder gave up on. `answer` is the shape of the
reply: text, empty, or a named refusal.

| backend       | case                       | family           | fixture B | answer  | essential | boiler | title | unicode | codepoints | U+FFFD | median ms |
| ------------- | -------------------------- | ---------------- | --------- | ------- | --------- | ------ | ----- | ------- | ---------- | ------ | --------- |
| ocaml-stdlib  | article-plain              | ordinary         | 1728      | text    | 5/5       | 7/7    | ok    | ok      | 846        | 0      | 0.13      |
| python-stdlib | article-plain              | ordinary         | 1728      | text    | 5/5       | 5/7    | ok    | ok      | 846        | 0      | 0.33      |
| trafilatura   | article-plain              | ordinary         | 1728      | text    | 5/5       | 0/7    | -     | MISS    | 547        | 0      | 4.04      |
| ocaml-stdlib  | article-no-title           | ordinary         | 556       | text    | 3/3       | 0/0    | ok    | -       | 306        | 0      | 0.06      |
| python-stdlib | article-no-title           | ordinary         | 556       | text    | 3/3       | 0/0    | ok    | -       | 306        | 0      | 0.15      |
| trafilatura   | article-no-title           | ordinary         | 556       | text    | 3/3       | 0/0    | ok    | -       | 304        | 0      | 2.32      |
| ocaml-stdlib  | article-jsonld             | ordinary         | 1160      | text    | 4/4       | 1/1    | ok    | ok      | 398        | 0      | 0.09      |
| python-stdlib | article-jsonld             | ordinary         | 1160      | text    | 4/4       | 0/1    | ok    | ok      | 398        | 0      | 0.16      |
| trafilatura   | article-jsonld             | ordinary         | 1160      | text    | 4/4       | 0/1    | -     | MISS    | 395        | 0      | 2.85      |
| ocaml-stdlib  | nav-heavy-docs             | navigation-heavy | 5844      | text    | 3/3       | 6/6    | ok    | ok      | 2852       | 0      | 0.59      |
| python-stdlib | nav-heavy-docs             | navigation-heavy | 5844      | text    | 3/3       | 5/6    | ok    | ok      | 2852       | 0      | 1.44      |
| trafilatura   | nav-heavy-docs             | navigation-heavy | 5844      | text    | 3/3       | 0/6    | -     | ok      | 505        | 0      | 11.22     |
| ocaml-stdlib  | nav-heavy-portal           | navigation-heavy | 4686      | text    | 2/2       | 7/7    | ok    | ok      | 2979       | 0      | 0.43      |
| python-stdlib | nav-heavy-portal           | navigation-heavy | 4686      | text    | 2/2       | 6/7    | ok    | ok      | 2979       | 0      | 1.00      |
| trafilatura   | nav-heavy-portal           | navigation-heavy | 4686      | text    | 2/2       | 1/7    | -     | MISS    | 216        | 0      | 15.03     |
| ocaml-stdlib  | malformed-unclosed         | malformed        | 540       | text    | 5/5       | 0/0    | ok    | ok      | 381        | 0      | 0.07      |
| python-stdlib | malformed-unclosed         | malformed        | 540       | text    | 5/5       | 0/0    | ok    | ok      | 381        | 0      | 0.11      |
| trafilatura   | malformed-unclosed         | malformed        | 540       | text    | 5/5       | 0/0    | -     | MISS    | 377        | 0      | 2.68      |
| ocaml-stdlib  | malformed-angle-text       | malformed        | 563       | text    | 4/4       | 0/0    | ok    | ok      | 374        | 0      | 0.05      |
| python-stdlib | malformed-angle-text       | malformed        | 563       | text    | 4/4       | 0/0    | ok    | ok      | 374        | 0      | 0.13      |
| trafilatura   | malformed-angle-text       | malformed        | 563       | text    | 4/4       | 0/0    | -     | MISS    | 355        | 0      | 2.37      |
| ocaml-stdlib  | malformed-misnested        | malformed        | 560       | text    | 6/6       | 0/0    | ok    | ok      | 316        | 0      | 0.06      |
| python-stdlib | malformed-misnested        | malformed        | 560       | text    | 6/6       | 0/0    | ok    | ok      | 316        | 0      | 0.20      |
| trafilatura   | malformed-misnested        | malformed        | 560       | text    | 6/6       | 0/0    | -     | MISS    | 323        | 0      | 3.22      |
| ocaml-stdlib  | malformed-attributes       | malformed        | 642       | text    | 4/4       | 0/0    | ok    | ok      | 188        | 0      | 0.04      |
| python-stdlib | malformed-attributes       | malformed        | 642       | text    | 3/4       | 0/0    | ok    | ok      | 188        | 0      | 0.12      |
| trafilatura   | malformed-attributes       | malformed        | 642       | text    | 3/4       | 0/0    | -     | MISS    | 184        | 0      | 3.27      |
| ocaml-stdlib  | malformed-comments         | malformed        | 628       | text    | 3/3       | 1/1    | ok    | -       | 244        | 0      | 0.05      |
| python-stdlib | malformed-comments         | malformed        | 628       | text    | 3/3       | 0/1    | ok    | -       | 244        | 0      | 0.10      |
| trafilatura   | malformed-comments         | malformed        | 628       | text    | 3/3       | 0/1    | -     | -       | 242        | 0      | 3.03      |
| ocaml-stdlib  | malformed-script-cdata     | malformed        | 518       | text    | 2/2       | 2/2    | ok    | -       | 140        | 0      | 0.04      |
| python-stdlib | malformed-script-cdata     | malformed        | 518       | text    | 2/2       | 0/2    | ok    | -       | 140        | 0      | 0.10      |
| trafilatura   | malformed-script-cdata     | malformed        | 518       | text    | 2/2       | 0/2    | -     | -       | 139        | 0      | 2.88      |
| ocaml-stdlib  | malformed-deep-nesting     | adversarial      | 22274     | text    | 2/2       | 0/0    | ok    | -       | 135        | 0      | 4.60      |
| python-stdlib | malformed-deep-nesting     | adversarial      | 22274     | text    | 2/2       | 0/0    | ok    | -       | 135        | 0      | 11.44     |
| trafilatura   | malformed-deep-nesting     | adversarial      | 22274     | empty   | 0/2       | 0/0    | -     | -       | 0          | 0      | 54.91     |
| ocaml-stdlib  | encoding-utf8-bom          | encoding         | 550       | text    | 3/3       | 0/0    | ok    | ok      | 370        | 0      | 0.05      |
| python-stdlib | encoding-utf8-bom          | encoding         | 550       | text    | 3/3       | 0/0    | ok    | ok      | 370        | 0      | 0.12      |
| trafilatura   | encoding-utf8-bom          | encoding         | 550       | text    | 3/3       | 0/0    | -     | ok      | 365        | 0      | 2.10      |
| ocaml-stdlib  | encoding-cp1252            | encoding         | 544       | text    | 4/4       | 0/0    | -     | ok      | 354        | 1      | 0.07      |
| python-stdlib | encoding-cp1252            | encoding         | 544       | text    | 0/4       | 0/0    | -     | MISS    | 354        | 15     | 0.13      |
| trafilatura   | encoding-cp1252            | encoding         | 544       | text    | 0/4       | 0/0    | -     | MISS    | 350        | 15     | 2.54      |
| ocaml-stdlib  | encoding-latin1-undeclared | encoding         | 571       | text    | 2/2       | 0/0    | ok    | -       | 424        | 4      | 0.09      |
| python-stdlib | encoding-latin1-undeclared | encoding         | 571       | text    | 2/2       | 0/0    | ok    | -       | 424        | 4      | 0.11      |
| trafilatura   | encoding-latin1-undeclared | encoding         | 571       | text    | 2/2       | 0/0    | ok    | -       | 421        | 4      | 2.46      |
| ocaml-stdlib  | encoding-undecodable       | encoding         | 414       | text    | 3/3       | 0/0    | ok    | ok      | 255        | 2      | 0.04      |
| python-stdlib | encoding-undecodable       | encoding         | 414       | text    | 3/3       | 0/0    | ok    | ok      | 255        | 2      | 0.11      |
| trafilatura   | encoding-undecodable       | encoding         | 414       | text    | 3/3       | 0/0    | -     | ok      | 252        | 2      | 2.48      |
| ocaml-stdlib  | entities-soup              | encoding         | 687       | text    | 4/4       | 0/0    | ok    | ok      | 390        | 2      | 0.20      |
| python-stdlib | entities-soup              | encoding         | 687       | text    | 4/4       | 0/0    | ok    | MISS    | 390        | 2      | 0.17      |
| trafilatura   | entities-soup              | encoding         | 687       | text    | 4/4       | 0/0    | -     | MISS    | 381        | 2      | 2.79      |
| ocaml-stdlib  | unicode-multiscript        | non-ascii        | 1181      | text    | 7/7       | 0/0    | ok    | ok      | 725        | 0      | 0.12      |
| python-stdlib | unicode-multiscript        | non-ascii        | 1181      | text    | 7/7       | 0/0    | ok    | MISS    | 725        | 0      | 0.22      |
| trafilatura   | unicode-multiscript        | non-ascii        | 1181      | text    | 7/7       | 0/0    | -     | MISS    | 714        | 0      | 3.96      |
| ocaml-stdlib  | js-shell                   | shell            | 347       | empty   | 0/0       | 0/1    | ok    | -       | 0          | 0      | 0.02      |
| python-stdlib | js-shell                   | shell            | 347       | empty   | 0/0       | 0/1    | ok    | -       | 0          | 0      | 0.09      |
| trafilatura   | js-shell                   | shell            | 347       | empty   | 0/0       | 0/1    | ok    | -       | 0          | 0      | 2.57      |
| ocaml-stdlib  | form-login                 | documented-loss  | 675       | text    | 1/1       | 1/1    | ok    | -       | 73         | 0      | 0.03      |
| python-stdlib | form-login                 | documented-loss  | 675       | text    | 1/1       | 0/1    | ok    | -       | 73         | 0      | 0.15      |
| trafilatura   | form-login                 | documented-loss  | 675       | text    | 0/1       | 1/1    | -     | -       | 139        | 0      | 3.93      |
| ocaml-stdlib  | table-reference            | structure        | 803       | text    | 4/4       | 0/0    | ok    | ok      | 297        | 0      | 0.12      |
| python-stdlib | table-reference            | structure        | 803       | text    | 4/4       | 0/0    | ok    | ok      | 297        | 0      | 0.33      |
| trafilatura   | table-reference            | structure        | 803       | text    | 4/4       | 0/0    | -     | MISS    | 358        | 0      | 5.32      |
| ocaml-stdlib  | list-hybrid                | structure        | 859       | text    | 4/4       | 0/0    | ok    | -       | 591        | 0      | 0.11      |
| python-stdlib | list-hybrid                | structure        | 859       | text    | 4/4       | 0/0    | ok    | -       | 591        | 0      | 0.20      |
| trafilatura   | list-hybrid                | structure        | 859       | text    | 4/4       | 0/0    | -     | -       | 601        | 0      | 4.23      |
| ocaml-stdlib  | svg-sprite                 | adversarial      | 751       | text    | 3/3       | 3/3    | ok    | -       | 294        | 0      | 0.05      |
| python-stdlib | svg-sprite                 | adversarial      | 751       | text    | 3/3       | 0/3    | ok    | -       | 294        | 0      | 0.20      |
| trafilatura   | svg-sprite                 | adversarial      | 751       | text    | 3/3       | 0/3    | -     | -       | 255        | 0      | 2.88      |
| ocaml-stdlib  | huge-article               | huge             | 186810    | text    | 4/4       | 3/3    | ok    | ok      | 182915     | 0      | 30.77     |
| python-stdlib | huge-article               | huge             | 186810    | text    | 4/4       | 0/3    | ok    | ok      | 182915     | 0      | 17.02     |
| trafilatura   | huge-article               | huge             | 186810    | text    | 4/4       | 0/3    | -     | MISS    | 182315     | 0      | 170.81    |
| ocaml-stdlib  | shared-blocks              | shared           | 41623     | text    | 2/2       | 3/3    | ok    | -       | 25744      | 0      | 5.42      |
| python-stdlib | shared-blocks              | shared           | 41623     | text    | 2/2       | 2/3    | ok    | -       | 25744      | 0      | 9.21      |
| trafilatura   | shared-blocks              | shared           | 41623     | text    | 2/2       | 0/3    | -     | -       | 317        | 0      | 101.06    |
| ocaml-stdlib  | pdf-minimal                | pdf              | 657       | refusal | 0/1       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| python-stdlib | pdf-minimal                | pdf              | 657       | refusal | 0/1       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| trafilatura   | pdf-minimal                | pdf              | 657       | text    | 1/1       | 0/0    | ok    | -       | 56         | 0      | 0.81      |
| ocaml-stdlib  | pdf-two-pages              | pdf              | 1079      | refusal | 0/2       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| python-stdlib | pdf-two-pages              | pdf              | 1079      | refusal | 0/2       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| trafilatura   | pdf-two-pages              | pdf              | 1079      | text    | 2/2       | 0/0    | ok    | -       | 110        | 0      | 1.28      |
| ocaml-stdlib  | pdf-kerned-tj              | pdf              | 720       | refusal | 0/1       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| python-stdlib | pdf-kerned-tj              | pdf              | 720       | refusal | 0/1       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| trafilatura   | pdf-kerned-tj              | pdf              | 720       | text    | 0/1       | 0/0    | ok    | -       | 49         | 0      | 0.98      |
| ocaml-stdlib  | pdf-shared-stream          | pdf              | 261818    | refusal | 0/0       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| python-stdlib | pdf-shared-stream          | pdf              | 261818    | refusal | 0/0       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| trafilatura   | pdf-shared-stream          | pdf              | 261818    | text    | 0/0       | 0/0    | ok    | -       | 1720028    | 0      | 4955.43   |
| ocaml-stdlib  | pdf-truncated              | pdf              | 539       | refusal | 0/0       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| python-stdlib | pdf-truncated              | pdf              | 539       | refusal | 0/0       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| trafilatura   | pdf-truncated              | pdf              | 539       | refusal | 0/0       | 0/0    | ok    | -       | 0          | 0      | 0.10      |
| ocaml-stdlib  | pdf-xref-stream            | pdf              | 702       | refusal | 0/1       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| python-stdlib | pdf-xref-stream            | pdf              | 702       | refusal | 0/1       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| trafilatura   | pdf-xref-stream            | pdf              | 702       | text    | 1/1       | 0/0    | ok    | -       | 51         | 0      | 1.01      |
| ocaml-stdlib  | pdf-not-a-pdf              | pdf              | 28        | refusal | 0/0       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| python-stdlib | pdf-not-a-pdf              | pdf              | 28        | refusal | 0/0       | 0/0    | ok    | -       | 0          | 0      | 0.00      |
| trafilatura   | pdf-not-a-pdf              | pdf              | 28        | refusal | 0/0       | 0/0    | ok    | -       | 0          | 0      | 0.03      |

## Totals, per backend

| backend       | case                       | family           | fixture B | answer  | essential | boiler | title | unicode | codepoints | U+FFFD | median ms |
| ------------- | -------------------------- | ---------------- | --------- | ------- | --------- | ------ | ----- | ------- | ---------- | ------ | --------- |
| ocaml-stdlib  | 32 cases                   |                  | 541057    | 24t/7r  | 84/89     | 34/35  | 31    | 32      | 221591     | 9      | 43.3      |
| python-stdlib | 32 cases                   |                  | 541057    | 24t/7r  | 79/89     | 18/35  | 31    | 29      | 221591     | 23     | 43.3      |
| trafilatura   | 32 cases                   |                  | 541057    | 28t/2r  | 80/89     | 2/35   | 10    | 20      | 1910349    | 23     | 5374.6    |

