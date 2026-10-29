# imbib

imbib is a bibliography manager: libraries of papers, each with its BibTeX,
identifiers, PDF and notes, filled from online databases (Crossref, arXiv,
ADS, SciX, OpenAlex, PubMed, Web of Science, Semantic Scholar, DBLP, INSPIRE)
and kept current by feeds.

Reading:
- `imbib-view-service_library-choices`, `paper-rows`, `paper-card` — the
  library picker, a library's or collection's papers (scope `inbox` for the
  Inbox), one paper.
- `imbib-view-service_feed-choices`, `feed-rows` — the feeds and their papers.
- `imbib-view-service_tag-tree`, `tag-rows` — the tag tree (lazy: pass the
  open paths) and a tag's papers.
- `imbib-view-service_collection-rows`, `collection-choices` — every paper
  collection with its library and count; `paper-rows` with scope
  `collection:<id>` lists one.
- `imbib-view-service_smart-search-rows` — the saved searches (smart searches
  that do not feed the Inbox) with what each has found; `paper-rows` with
  scope `collection:<search id>` lists a search's papers.

Doing:
- `imbib-triage-service_keep` / `dismiss` — triage: keep papers in a
  library (`imbib-view-service_keep-libraries` lists them) or dismiss them to
  the Dismissed library (the trash; nothing is deleted). From the Inbox
  (`scope: "inbox"`) or a feed (`"feed:<id>"`) both record the paper, so no
  feed brings it back; from `"library:<id>"` they only move it.
- `imbib-feeds-service_refresh-feed` / `refresh-inbox-feeds` — run feeds now
  (search, drop muted and dismissed, import new papers into the Inbox).
- `imbib-feeds-service_refresh-feed` with a saved search's id runs it and files
  new papers in its library; `imbib-search-service_create-smart-search` /
  `delete-smart-search` save and remove one (its papers stay).
- `imbib-pdf-service_fetch-pdf` — get a paper's PDF (arXiv, else the
  publisher's URL for its DOI, else its own PDF url; a paywall page is
  refused) and keep it with the library's files; the card's "Local PDF"
  link then opens it.
- `imbib-view-service_search-rows` + `import-ids` — search the online
  databases and import chosen papers into a library.
- `imbib-view-service_resolve-view` — resolve a bibliography line (an
  ApJ/MNRAS reference resolves exactly through its ADS bibcode).
- `imbib-library-service_set-read`, `set-starred`, `set-flag` (red, amber,
  blue, green; null clears); `imbib-tags-service_add-tag`, `remove-tag`.
- `imbib-library-service_add-to-collection`, `remove-from-collection` — file
  papers; `collection-service_create` / `rename` / `delete` with binding
  `generic` (and `kind_scope: "publication"` on create) manage collections.
  Deleting a collection never deletes its papers.

Keys (every paper list): `j`/`k` move and the card follows, `r`/`u`
read/unread, `s` star, `g` get the PDF, `m` the row menu; in the Inbox and a feed also `d`
dismiss and `*` keep in the library chosen under "Keep in", and the next
paper comes up (`imbib-view-service_paper-after`). A paper shown for two
seconds is marked read (`imbib-triage-service_viewing`).
