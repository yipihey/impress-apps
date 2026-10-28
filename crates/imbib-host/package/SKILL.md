# imbib

imbib is a bibliography manager: libraries of papers, each with its BibTeX,
identifiers, PDF and notes, filled from online databases (Crossref, arXiv,
ADS, SciX, OpenAlex, PubMed, Web of Science, Semantic Scholar, DBLP, INSPIRE)
and kept current by feeds.

Reading:
- `imbib-view-service_library-choices`, `paper-rows`, `paper-card` — the
  library picker, a library's or collection's papers, one paper.
- `imbib-view-service_feed-choices`, `feed-rows` — the feeds and their papers.
- `imbib-view-service_tag-tree`, `tag-rows` — the tag tree (lazy: pass the
  open paths) and a tag's papers.
- `imbib-view-service_collection-rows`, `collection-choices` — every paper
  collection with its library and count; `paper-rows` with scope
  `collection:<id>` lists one.

Doing:
- `imbib-feeds-service_refresh-feed` / `refresh-inbox-feeds` — run feeds now
  (search, drop muted and dismissed, import new papers into the Inbox).
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
