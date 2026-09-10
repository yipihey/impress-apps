# Manuscript projects (ADR-0030)

A manuscript in impress is a **project**: one entry file whose text is the manuscript body,
plus any number of other files — chapters, figures, the code that makes figures, data, styles,
one or more bibliographies — each a `manuscript-file@1.0.0` row under the manuscript. Nothing
migrates: a manuscript with no file rows is a one-file project and every existing path keeps
working. This page is the map for people and agents; the decisions are in
[ADR-0030](ADR-0030-manuscript-projects.md).

## The tree

| Role | Meaning | Typical files |
|---|---|---|
| `main` | the entry (implicit; the manuscript row itself) | `main.tex`, `main.typ`, `main.md` |
| `chapter` | text the entry includes | `chapters/intro.tex`, `sections/method.typ` |
| `supplement` | text built separately (a second target) | `supplement.tex` |
| `bibliography` | BibTeX the entry cites from | `refs.bib` |
| `figure` | an image the text places | `figures/fig1.pdf` |
| `figure-source` | code/spec that MAKES figures | `figures/fig1.py`, `figures/fig1.vsz`, `figures/fig1.plot` |
| `output` | a file a figure step produced (carries `derived_from` + `derived_from_hash`) | `figures/fig1.png` |
| `data` | what figure sources read | `data/run42.csv` |
| `style` | classes, templates, fonts | `aastex.cls`, `template.typ` |
| `aux` | everything else | `Makefile` |

Paths are project-relative, POSIX, no `..`. Ids derive from `(manuscript, path)`, so a re-import,
a second device and a working copy mint the same row for the same file. Text up to 1 MiB lives
inline (Automerge-backed: every text file has the same merge-not-overwrite history the body has);
larger text and every binary go to the workspace content store (`<workspace>/content`,
`blob:sha256:…` refs).

**The build graph is derived, never stored.** Rust scans LaTeX (`\input`, `\include`,
`\includegraphics`, `\bibliography`, `\addbibresource`, `\cite…`, `\graphicspath`), Typst
(`#include`, `#import`, `image(...)`, `#bibliography`, `read`/`csv`/`json`, `@key`) and Markdown
(images, Quarto includes, `@key`) with comments blanked, resolves each reference against the tree
(LaTeX against the entry's directory, Typst/Markdown against the file's own), and reports what it
found as edges, unresolved references (errors naming file + line), include cycles, cite keys,
figure steps in run order with staleness, reachability, and unreferenced files.

## Targets

A manuscript builds one **target** unless it declares more (`targets_json`):

```json
[{"id":"main","engine":"pdflatex","output_kind":"pdf"},
 {"id":"supplement","entry":"supplement.tex","engine":"pdflatex"}]
```

Engines: `typst` (in memory, no directory), `tectonic` (embedded when the build has it; the
`tectonic` command or `latexmk`/`pdflatex` otherwise, with a line in the log saying so),
`pdflatex` / `xelatex` / `lualatex` (BibTeX or Biber and the extra passes when the aux asks),
`latexmk`, `markdown` (converted to Typst, then Typst), `none` (figure steps only). The default
for a format is `typst` / `tectonic` / `markdown`.

## Bibliographies

A `.bib` row is either its own text or a **projection** (`bib_source_json`) resolved from imbib
at compile/build time: `{"kind":"cited"}` (every key the tree cites), `{"kind":"collection",…}`,
`{"kind":"library",…}`, `{"kind":"keys","keys":[…]}`. Raw BibTeX is used when the library row has
it, synthesized from fields otherwise; a key not in the library is a `missing-reference` warning
and a placeholder entry in the rendered bibliography, so the document still compiles.

The one-file convention survives in the tree: a Typst or Markdown manuscript that cites `@keys`
without a `.bib` of its own gets the implicit `bibliography.bib` (a `cited` projection, never a
row), and when the entry never calls `#bibliography(...)` the call is appended at compile time —
exactly what the app has done since the citation seam shipped. LaTeX trees need a real `.bib`
file (BibTeX reads it by name).

## Figure steps

A `figure-source` declares how it makes its outputs (`build_json`):

```json
{"runner":"shell","outputs":["figures/plot.png"],"inputs":["data/run42.csv"],
 "args":{"command":"python figures/plot.py"}}
```

Runners: `shell` (runs only when the build allows shell steps), `veusz` (`veusz --export`),
`impress-plot` and `implore` (native; P5). A step is **stale** when an output's
`derived_from_hash` differs from the step's input hash (source bytes + inputs + spec) or an
output has no row; a build runs stale steps first, reads the declared outputs back and records
them as `output` rows derived from the source. Fresh steps are skipped.

## Verbs (CLI, MCP, impel — the app closed is fine)

`imprint-project-service_project-*` / `impress project-*`:

- read: `tree`, `file`, `graph`, `outline`, `citations`, `builds`, `build-output`
- write: `put-file`, `delete-file`, `move-file`, `set-entry`, `set-targets`, `set-bibliography`,
  `set-figure-build`
- whole project: `import-directory` (a folder becomes a manuscript, or lands in one),
  `export` (`bundle` with `manifest.json`, or `standalone`), `materialize` (a directory for a
  toolchain, hash-compared, prunes only what it wrote), `snapshot` (a deterministic `.tar.zst`
  revision in the content store), `compile` (Typst, from memory, not recorded), `build`
  (recorded: `manuscript-build@1.0.0` rows, last 20 kept, PDF in the content store)

Writes refuse watched-folder manuscripts (ADR-0023 D4): the file on disk is the truth there.

## In imprint

- **Files** inspector: the tree by role, the entry marked, badges for unresolved / stale /
  unreferenced, add files, import a folder, rename, delete, insert a reference at the caret;
  double-click a text file to edit it in its own session (its own history; compiles build the
  whole tree with that buffer substituted).
- **Build** inspector and File ▸ Build Manuscript (⌥⌘B): pick a target, allow shell steps or
  not, read the steps, the diagnostics by file, the outputs, the log, the recorded builds.
- File ▸ Import Folder as Manuscript…: one manuscript from a directory (build residue skipped,
  the entry guessed with a reason shown in the log).
- Previews: a Typst project renders from memory; a LaTeX project builds in a per-manuscript
  cache directory through the same engine (shell steps never run from a preview).

## Not yet

Native `impress-plot` / `implore` runners (P5), working copies (`project-checkout` /
`project-checkin`, P6), retirement of the older Swift project scanner and exporter (P7).
