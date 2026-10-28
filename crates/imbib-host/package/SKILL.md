# imbib

imbib is a bibliography manager: libraries of papers, each with its BibTeX,
identifiers, PDF and notes, filled from online databases (Crossref, arXiv,
ADS, SciX, OpenAlex, PubMed, Web of Science, Semantic Scholar, DBLP, INSPIRE).

- `imbib-library-service_list-libraries` lists the libraries.
- `imbib-library-service_list-publications` / `search-publications` read papers;
  `get-publication-detail` reads one.
- `imbib-sources-service_search-sources` searches the online databases;
  `imbib-library-service_import-work` imports a row into a library.
- `imbib-sources-service_resolve-citation` turns a reference string into a paper.
