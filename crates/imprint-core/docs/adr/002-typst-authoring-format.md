# ADR-002: Typst as Primary Authoring Format

## Status
Accepted

## Context
Academic writing requires professional typesetting with equations, figures, citations, and journal-specific formatting. Options include:

1. **LaTeX**: Industry standard, but complex syntax and slow compilation
2. **Markdown**: Simple but insufficient for academic needs
3. **Rich text (WYSIWYG)**: Familiar but poor version control and reproducibility
4. **Typst**: Modern alternative with clean syntax and fast incremental compilation

Key requirements:
- Sub-100ms compilation for live preview
- Professional typesetting quality (equations, figures, tables)
- Journal submission compatibility (LaTeX export)
- Syntax accessible to non-technical collaborators

## Decision
imprint uses **Typst** as its primary authoring format with LaTeX as the export/submission format.

Key design choices:
1. **Typst source stored in CRDT**: Plain text enables character-level merging
2. **Incremental compilation**: <100ms updates via Typst's built-in incremental mode
3. **LaTeX converter**: Typst→LaTeX for journal submission
4. **LaTeX importer**: LaTeX→Typst for migrating existing documents

Typst syntax comparison:
```typst
// Typst: Clean, readable
= Introduction

We present a method for computing $integral_0^infinity f(x) d x$
using the approach of @smith2023.

#figure(
  image("plot.png"),
  caption: [Results of our simulation]
)
```

```latex
% LaTeX: More verbose
\section{Introduction}

We present a method for computing $\int_0^\infty f(x) \, dx$
using the approach of \cite{smith2023}.

\begin{figure}
\includegraphics{plot.png}
\caption{Results of our simulation}
\end{figure}
```

## Consequences

### Positive
- Fast iteration: <100ms compile enables real-time preview
- Lower barrier: Cleaner syntax than LaTeX, more capable than Markdown
- Better errors: Typst provides line-accurate, actionable error messages
- Modern tooling: Rust-native, WASM-compatible, actively developed

### Negative
- Journal submission: Must convert to LaTeX (converter complexity)
- Ecosystem: Fewer packages than LaTeX (mitigated by most common needs being built-in)
- Adoption: Collaborators may need to learn new syntax
- Edge cases: Some LaTeX features have no Typst equivalent

## Implementation
- `imprint-render` crate wraps Typst compiler
- Incremental rendering with source hash caching
- Journal templates (MNRAS, ApJ, A&A) as Typst→LaTeX converters
- Syntax highlighting and completion in editor
