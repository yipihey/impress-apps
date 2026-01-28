//! Built-in journal and conference templates
//!
//! This module contains all templates bundled with imprint.

use super::{
    JournalInfo, PageDefaults, PageMargins, Template, TemplateCategory, TemplateMetadata,
    TemplateSource, TypstRequirements,
};

/// Get all built-in templates
pub fn builtin_templates() -> Vec<Template> {
    vec![
        // Generic starter
        generic_template(),
        // Astrophysics & Cosmology
        mnras_template(),
        apj_template(),
        apjs_template(),
        jcap_template(),
        aa_template(),
        araa_template(),
        // Physics
        prd_template(),
        prl_template(),
        jhep_template(),
        // Computational & ML
        neurips_template(),
        icml_template(),
        jcp_template(),
        // General Science
        nature_template(),
        science_template(),
        // Biomedical
        pnas_template(),
        plos_template(),
        elife_template(),
        cell_template(),
        nejm_template(),
        lancet_template(),
        bmj_template(),
        jama_template(),
        bioinformatics_template(),
        nature_medicine_template(),
    ]
}

// =============================================================================
// Generic Template
// =============================================================================

fn generic_template() -> Template {
    let metadata = TemplateMetadata {
        id: "generic".to_string(),
        name: "Generic Article".to_string(),
        version: "1.0.0".to_string(),
        description: "A clean, minimal template for academic writing. Good starting point for any document.".to_string(),
        author: "imprint".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Custom,
        tags: vec!["general".to_string(), "starter".to_string(), "minimal".to_string()],
        journal: None,
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "a4".to_string(),
            margins: PageMargins { top: 25.0, right: 25.0, bottom: 25.0, left: 25.0 },
            columns: 1,
            font_size: 11.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: Generic Article
// A clean starting point for academic writing

#let article(
  title: none,
  authors: (),
  abstract: none,
  keywords: (),
  date: datetime.today(),
  body
) = {
  // Page setup
  set page(
    paper: "a4",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
  )

  // Typography
  set text(font: "New Computer Modern", size: 11pt)
  set par(justify: true, leading: 0.65em, first-line-indent: 1em)

  // Headings
  set heading(numbering: "1.1")
  show heading.where(level: 1): it => {
    v(1em)
    text(size: 14pt, weight: "bold", it)
    v(0.5em)
  }
  show heading.where(level: 2): it => {
    v(0.8em)
    text(size: 12pt, weight: "bold", it)
    v(0.4em)
  }

  // Title block
  if title != none {
    align(center)[
      #text(size: 18pt, weight: "bold", title)
      #v(1em)
      #for (i, author) in authors.enumerate() {
        if type(author) == str {
          text(author)
        } else {
          text(author.name)
          if "affiliation" in author {
            super(str(author.affiliation))
          }
        }
        if i < authors.len() - 1 { ", " }
      }
      #v(0.5em)
      #text(size: 10pt, style: "italic", date.display("[month repr:long] [day], [year]"))
    ]
    v(2em)
  }

  // Abstract
  if abstract != none {
    block(width: 100%, inset: (left: 2em, right: 2em))[
      #text(weight: "bold")[Abstract.] #abstract
    ]
    v(1em)
  }

  // Keywords
  if keywords.len() > 0 {
    block(width: 100%, inset: (left: 2em, right: 2em))[
      #text(weight: "bold")[Keywords:] #keywords.join(", ")
    ]
    v(1em)
  }

  // Body
  body
}

// Usage: #show: article.with(title: "...", authors: (...), abstract: [...])
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass[11pt,a4paper]{article}
\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}
\usepackage{amsmath,amssymb}
\usepackage{graphicx}
\usepackage[margin=2.5cm]{geometry}
\usepackage{hyperref}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

// =============================================================================
// Astrophysics & Cosmology
// =============================================================================

fn mnras_template() -> Template {
    let metadata = TemplateMetadata {
        id: "mnras".to_string(),
        name: "Monthly Notices of the Royal Astronomical Society".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for MNRAS submissions following Oxford style guidelines."
            .to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "astronomy".to_string(),
            "astrophysics".to_string(),
            "oxford".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "Oxford University Press".to_string(),
            url: Some("https://academic.oup.com/mnras".to_string()),
            latex_class: Some("mnras".to_string()),
            issn: Some("0035-8711".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "a4".to_string(),
            margins: PageMargins {
                top: 20.0,
                right: 20.0,
                bottom: 20.0,
                left: 20.0,
            },
            columns: 2,
            font_size: 9.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: MNRAS
// Monthly Notices of the Royal Astronomical Society style

#let mnras(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  keywords: (),
  accepted: none,
  body
) = {
  // MNRAS uses A4 with specific margins
  set page(
    paper: "a4",
    margin: (top: 2cm, bottom: 2cm, left: 2cm, right: 2cm),
    columns: 2,
    column-gutter: 5mm,
  )

  // MNRAS typography
  set text(font: "Times New Roman", size: 9pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.5em)

  // Section headings (MNRAS style: bold, numbered, uppercase for L1)
  set heading(numbering: "1")
  show heading.where(level: 1): it => {
    v(0.8em)
    text(size: 10pt, weight: "bold", upper(
      numbering("1", ..counter(heading).get()) + h(0.5em) + it.body
    ))
    v(0.4em)
  }
  show heading.where(level: 2): it => {
    v(0.6em)
    text(size: 9pt, weight: "bold",
      numbering("1.1", ..counter(heading).get()) + h(0.5em) + it.body
    )
    v(0.3em)
  }

  // Title block (spans both columns)
  place(top + center, float: true, scope: "parent", clearance: 1em)[
    #block(width: 100%)[
      #align(center)[
        #text(size: 14pt, weight: "bold", title)
        #v(0.8em)
        // Authors with superscript affiliations
        #text(size: 10pt)[
          #for (i, author) in authors.enumerate() {
            if type(author) == str {
              author
            } else {
              author.name
              if "affil" in author {
                super(str(author.affil))
              }
            }
            if i < authors.len() - 1 { ", " }
          }
        ]
        #v(0.5em)
        // Affiliations
        #set text(size: 8pt, style: "italic")
        #for (i, affil) in affiliations.enumerate() {
          super(str(i + 1)) + affil
          linebreak()
        }
        #v(0.5em)
        #if accepted != none {
          text(size: 8pt)[Accepted #accepted]
        }
      ]
    ]
  ]

  // Abstract
  v(1em)
  block(width: 100%)[
    #text(weight: "bold", size: 9pt)[ABSTRACT]
    #v(0.3em)
    #text(size: 9pt)[#abstract]
    #v(0.5em)
    #text(weight: "bold", size: 8pt)[Key words:] #text(size: 8pt)[#keywords.join(" -- ")]
  ]

  v(1em)
  body
}

// Usage: #show: mnras.with(title: "...", authors: (...), affiliations: (...), abstract: [...], keywords: (...))
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass[fleqn,usenatbib]{mnras}
\usepackage{graphicx}
\usepackage{amsmath}
\usepackage{amssymb}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn apj_template() -> Template {
    let metadata = TemplateMetadata {
        id: "apj".to_string(),
        name: "Astrophysical Journal".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for ApJ submissions using AASTeX style.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "astronomy".to_string(),
            "astrophysics".to_string(),
            "aas".to_string(),
            "aastex".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "American Astronomical Society".to_string(),
            url: Some("https://iopscience.iop.org/journal/0004-637X".to_string()),
            latex_class: Some("aastex63".to_string()),
            issn: Some("0004-637X".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "letter".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 2,
            font_size: 10.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: ApJ (Astrophysical Journal)
// AASTeX-style template for ApJ submissions

#let apj(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  keywords: (),
  body
) = {
  set page(
    paper: "us-letter",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
    columns: 2,
    column-gutter: 6mm,
  )

  set text(font: "Times New Roman", size: 10pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.52em)

  // AAS-style headings
  set heading(numbering: "1.")
  show heading.where(level: 1): it => {
    v(1em)
    text(size: 11pt, weight: "bold", upper(it.body))
    v(0.5em)
  }
  show heading.where(level: 2): it => {
    v(0.8em)
    text(size: 10pt, weight: "bold", style: "italic", it.body)
    v(0.4em)
  }

  // Title block
  place(top + center, float: true, scope: "parent", clearance: 1em)[
    #block(width: 100%)[
      #align(center)[
        #text(size: 16pt, weight: "bold", title)
        #v(1em)
        #for (i, author) in authors.enumerate() {
          if type(author) == str { author } else {
            author.name
            if "affil" in author { super(str(author.affil)) }
            if "orcid" in author { text(size: 7pt)[ #link("https://orcid.org/" + author.orcid)[ORCID]] }
          }
          if i < authors.len() - 1 { ", " }
        }
        #v(0.5em)
        #set text(size: 9pt, style: "italic")
        #for (i, affil) in affiliations.enumerate() {
          super(str(i + 1)) + affil
          linebreak()
        }
      ]
    ]
  ]

  // Abstract
  v(1em)
  block(width: 100%)[
    #text(weight: "bold", size: 10pt)[ABSTRACT]
    #v(0.3em)
    #abstract
    #v(0.5em)
    #text(style: "italic")[Keywords:] #keywords.join(", ")
  ]
  v(1em)

  body
}

// Usage: #show: apj.with(...)
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass[twocolumn]{aastex63}
\usepackage{graphicx}
\usepackage{amsmath}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn apjs_template() -> Template {
    let metadata = TemplateMetadata {
        id: "apjs".to_string(),
        name: "Astrophysical Journal Supplement".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for ApJS submissions using AASTeX style.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "astronomy".to_string(),
            "astrophysics".to_string(),
            "aas".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "American Astronomical Society".to_string(),
            url: Some("https://iopscience.iop.org/journal/0067-0049".to_string()),
            latex_class: Some("aastex63".to_string()),
            issn: Some("0067-0049".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "letter".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 2,
            font_size: 10.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    // ApJS uses same style as ApJ
    let typst_source = r##"// imprint template: ApJS (Astrophysical Journal Supplement)
// Uses same AASTeX style as ApJ

#let apjs(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  keywords: (),
  body
) = {
  set page(
    paper: "us-letter",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
    columns: 2,
    column-gutter: 6mm,
  )

  set text(font: "Times New Roman", size: 10pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.52em)

  set heading(numbering: "1.")
  show heading.where(level: 1): it => {
    v(1em)
    text(size: 11pt, weight: "bold", upper(it.body))
    v(0.5em)
  }
  show heading.where(level: 2): it => {
    v(0.8em)
    text(size: 10pt, weight: "bold", style: "italic", it.body)
    v(0.4em)
  }

  // Title block
  place(top + center, float: true, scope: "parent", clearance: 1em)[
    #block(width: 100%)[
      #align(center)[
        #text(size: 16pt, weight: "bold", title)
        #v(1em)
        #for (i, author) in authors.enumerate() {
          if type(author) == str { author } else {
            author.name
            if "affil" in author { super(str(author.affil)) }
          }
          if i < authors.len() - 1 { ", " }
        }
        #v(0.5em)
        #set text(size: 9pt, style: "italic")
        #for (i, affil) in affiliations.enumerate() {
          super(str(i + 1)) + affil
          linebreak()
        }
      ]
    ]
  ]

  v(1em)
  block(width: 100%)[
    #text(weight: "bold")[ABSTRACT]
    #v(0.3em)
    #abstract
    #v(0.5em)
    #text(style: "italic")[Keywords:] #keywords.join(", ")
  ]
  v(1em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass[twocolumn]{aastex63}
\usepackage{graphicx}
\usepackage{amsmath}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn jcap_template() -> Template {
    let metadata = TemplateMetadata {
        id: "jcap".to_string(),
        name: "Journal of Cosmology and Astroparticle Physics".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for JCAP submissions following IOP style.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "cosmology".to_string(),
            "astroparticle".to_string(),
            "physics".to_string(),
            "iop".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "IOP Publishing / SISSA".to_string(),
            url: Some("https://iopscience.iop.org/journal/1475-7516".to_string()),
            latex_class: Some("jcappub".to_string()),
            issn: Some("1475-7516".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "a4".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 1,
            font_size: 11.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: JCAP
// Journal of Cosmology and Astroparticle Physics

#let jcap(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  keywords: (),
  arxiv: none,
  body
) = {
  set page(
    paper: "a4",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
  )

  set text(font: "Times New Roman", size: 11pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.58em)

  set heading(numbering: "1")
  show heading.where(level: 1): it => {
    v(1em)
    text(size: 12pt, weight: "bold", numbering("1", ..counter(heading).get()) + h(0.5em) + it.body)
    v(0.5em)
  }
  show heading.where(level: 2): it => {
    v(0.8em)
    text(size: 11pt, weight: "bold", numbering("1.1", ..counter(heading).get()) + h(0.5em) + it.body)
    v(0.4em)
  }

  // Title block
  align(center)[
    #v(1em)
    #text(size: 16pt, weight: "bold", title)
    #v(1.5em)
    #for (i, author) in authors.enumerate() {
      if type(author) == str { text(size: 11pt, author) } else {
        text(size: 11pt, author.name)
        if "affil" in author { super(str(author.affil)) }
      }
      if i < authors.len() - 1 { ", " }
    }
    #v(0.8em)
    #set text(size: 10pt, style: "italic")
    #for (i, affil) in affiliations.enumerate() {
      super(str(i + 1)) + affil
      linebreak()
    }
    #v(0.5em)
    #if arxiv != none {
      text(size: 9pt)[arXiv:#arxiv]
    }
  ]

  v(1.5em)
  block(stroke: (top: 0.5pt, bottom: 0.5pt), inset: (y: 0.8em), width: 100%)[
    #text(weight: "bold", size: 10pt)[Abstract.] #abstract
  ]
  v(0.5em)
  text(size: 10pt)[#text(weight: "bold")[Keywords:] #keywords.join(", ")]
  v(1.5em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass[a4paper,11pt]{jcappub}
\usepackage{graphicx}
\usepackage{amsmath,amssymb}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn aa_template() -> Template {
    let metadata = TemplateMetadata {
        id: "aa".to_string(),
        name: "Astronomy & Astrophysics".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for A&A submissions following EDP Sciences style.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "astronomy".to_string(),
            "astrophysics".to_string(),
            "europe".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "EDP Sciences".to_string(),
            url: Some("https://www.aanda.org".to_string()),
            latex_class: Some("aa".to_string()),
            issn: Some("0004-6361".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "a4".to_string(),
            margins: PageMargins {
                top: 20.0,
                right: 20.0,
                bottom: 20.0,
                left: 20.0,
            },
            columns: 2,
            font_size: 9.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: A&A
// Astronomy & Astrophysics

#let aa(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  keywords: (),
  received: none,
  accepted: none,
  body
) = {
  set page(
    paper: "a4",
    margin: (top: 2cm, bottom: 2cm, left: 2cm, right: 2cm),
    columns: 2,
    column-gutter: 5mm,
  )

  set text(font: "Times New Roman", size: 9pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.5em)

  set heading(numbering: "1.")
  show heading.where(level: 1): it => {
    v(0.8em)
    text(size: 10pt, weight: "bold", numbering("1.", ..counter(heading).get()) + h(0.3em) + it.body)
    v(0.4em)
  }
  show heading.where(level: 2): it => {
    v(0.6em)
    text(size: 9pt, weight: "bold", numbering("1.1.", ..counter(heading).get()) + h(0.3em) + it.body)
    v(0.3em)
  }

  // Title block
  place(top + center, float: true, scope: "parent", clearance: 1em)[
    #block(width: 100%)[
      #align(center)[
        #text(size: 14pt, weight: "bold", title)
        #v(0.8em)
        #for (i, author) in authors.enumerate() {
          if type(author) == str { author } else {
            author.name
            if "affil" in author { super(str(author.affil)) }
          }
          if i < authors.len() - 1 { ", " }
        }
        #v(0.5em)
        #set text(size: 8pt, style: "italic")
        #for (i, affil) in affiliations.enumerate() {
          super(str(i + 1)) + affil
          linebreak()
        }
        #if received != none or accepted != none {
          v(0.3em)
          text(size: 8pt)[
            #if received != none [Received #received]
            #if received != none and accepted != none [; ]
            #if accepted != none [accepted #accepted]
          ]
        }
      ]
    ]
  ]

  v(1em)
  block(width: 100%)[
    #text(weight: "bold", size: 9pt)[ABSTRACT]
    #v(0.2em)
    #abstract
    #v(0.3em)
    #text(weight: "bold", size: 8pt)[Key words.] #text(size: 8pt)[#keywords.join(" – ")]
  ]
  v(1em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass{aa}
\usepackage{graphicx}
\usepackage{amsmath}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn araa_template() -> Template {
    let metadata = TemplateMetadata {
        id: "araa".to_string(),
        name: "Annual Review of Astronomy & Astrophysics".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for ARA&A review articles.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "astronomy".to_string(),
            "astrophysics".to_string(),
            "review".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "Annual Reviews".to_string(),
            url: Some("https://www.annualreviews.org/journal/astro".to_string()),
            latex_class: None,
            issn: Some("0066-4146".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "letter".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 1,
            font_size: 11.0,
        },
        exports: vec!["pdf".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: ARA&A
// Annual Review of Astronomy & Astrophysics

#let araa(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  keywords: (),
  body
) = {
  set page(
    paper: "us-letter",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
  )

  set text(font: "Times New Roman", size: 11pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.6em)

  set heading(numbering: "1.")
  show heading.where(level: 1): it => {
    v(1.2em)
    text(size: 14pt, weight: "bold", upper(it.body))
    v(0.6em)
  }
  show heading.where(level: 2): it => {
    v(1em)
    text(size: 12pt, weight: "bold", it.body)
    v(0.5em)
  }

  // Title block
  align(center)[
    #text(size: 18pt, weight: "bold", title)
    #v(1.5em)
    #for (i, author) in authors.enumerate() {
      if type(author) == str { text(size: 12pt, author) } else {
        text(size: 12pt, author.name)
        if "affil" in author { super(str(author.affil)) }
      }
      if i < authors.len() - 1 { ", " }
    }
    #v(0.8em)
    #set text(size: 10pt, style: "italic")
    #for (i, affil) in affiliations.enumerate() {
      super(str(i + 1)) + affil
      linebreak()
    }
  ]

  v(2em)
  block(stroke: (left: 2pt + rgb("#1a5276")), inset: (left: 1em, y: 0.5em))[
    #text(weight: "bold", size: 11pt)[Abstract]
    #v(0.3em)
    #abstract
  ]
  v(0.8em)
  text(size: 10pt)[#text(weight: "bold")[Keywords:] #keywords.join(", ")]
  v(2em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: None,
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

// =============================================================================
// Physics
// =============================================================================

fn prd_template() -> Template {
    let metadata = TemplateMetadata {
        id: "prd".to_string(),
        name: "Physical Review D".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for Phys. Rev. D submissions using REVTeX style.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "physics".to_string(),
            "hep".to_string(),
            "gravity".to_string(),
            "cosmology".to_string(),
            "revtex".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "American Physical Society".to_string(),
            url: Some("https://journals.aps.org/prd/".to_string()),
            latex_class: Some("revtex4-2".to_string()),
            issn: Some("2470-0010".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "letter".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 20.0,
                bottom: 25.0,
                left: 20.0,
            },
            columns: 2,
            font_size: 10.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: Physical Review D
// REVTeX-style template

#let prd(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  pacs: (),
  body
) = {
  set page(
    paper: "us-letter",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2cm, right: 2cm),
    columns: 2,
    column-gutter: 5mm,
  )

  set text(font: "Times New Roman", size: 10pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.52em)

  set heading(numbering: "I.A.1.")
  show heading.where(level: 1): it => {
    v(0.8em)
    text(size: 11pt, weight: "bold", upper(
      numbering("I.", ..counter(heading).get()) + h(0.3em) + it.body
    ))
    v(0.4em)
  }
  show heading.where(level: 2): it => {
    v(0.6em)
    text(size: 10pt, weight: "bold", style: "italic",
      numbering("A.", ..counter(heading).get().slice(1)) + h(0.3em) + it.body
    )
    v(0.3em)
  }

  // Title block
  place(top + center, float: true, scope: "parent", clearance: 1em)[
    #block(width: 100%)[
      #align(center)[
        #text(size: 14pt, weight: "bold", title)
        #v(0.8em)
        #for (i, author) in authors.enumerate() {
          if type(author) == str { author } else {
            author.name
            if "affil" in author { super(str(author.affil)) }
          }
          if i < authors.len() - 1 { ", " }
        }
        #v(0.5em)
        #set text(size: 9pt, style: "italic")
        #for (i, affil) in affiliations.enumerate() {
          super(str(i + 1)) + affil
          linebreak()
        }
      ]
    ]
  ]

  v(1em)
  block(width: 100%, inset: (x: 1em))[
    #abstract
    #if pacs.len() > 0 {
      v(0.3em)
      text(size: 9pt)[PACS numbers: #pacs.join(", ")]
    }
  ]
  v(1em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass[prd,twocolumn,nofootinbib]{revtex4-2}
\usepackage{graphicx}
\usepackage{amsmath,amssymb}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn prl_template() -> Template {
    let metadata = TemplateMetadata {
        id: "prl".to_string(),
        name: "Physical Review Letters".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for PRL submissions. Strict 4-page limit.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "physics".to_string(),
            "letters".to_string(),
            "revtex".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "American Physical Society".to_string(),
            url: Some("https://journals.aps.org/prl/".to_string()),
            latex_class: Some("revtex4-2".to_string()),
            issn: Some("0031-9007".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "letter".to_string(),
            margins: PageMargins {
                top: 20.0,
                right: 18.0,
                bottom: 20.0,
                left: 18.0,
            },
            columns: 2,
            font_size: 10.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: Physical Review Letters
// Compact format with strict page limits

#let prl(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  body
) = {
  set page(
    paper: "us-letter",
    margin: (top: 2cm, bottom: 2cm, left: 1.8cm, right: 1.8cm),
    columns: 2,
    column-gutter: 4mm,
  )

  set text(font: "Times New Roman", size: 10pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.5em)

  // PRL uses minimal section formatting
  set heading(numbering: none)
  show heading.where(level: 1): it => {
    v(0.6em)
    text(size: 10pt, weight: "bold", style: "italic", it.body)
    text[.—]
  }

  // Compact title block
  place(top + center, float: true, scope: "parent", clearance: 0.8em)[
    #block(width: 100%)[
      #align(center)[
        #text(size: 12pt, weight: "bold", title)
        #v(0.6em)
        #text(size: 10pt)[
          #for (i, author) in authors.enumerate() {
            if type(author) == str { author } else {
              author.name
              if "affil" in author { super(str(author.affil)) }
            }
            if i < authors.len() - 1 { ", " }
          }
        ]
        #v(0.4em)
        #set text(size: 8pt, style: "italic")
        #for (i, affil) in affiliations.enumerate() {
          super(str(i + 1)) + affil
          if i < affiliations.len() - 1 { linebreak() }
        }
      ]
    ]
  ]

  v(0.8em)
  block(width: 100%, inset: (x: 0.5em))[
    #text(size: 9pt)[#abstract]
  ]
  v(0.8em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass[prl,twocolumn,nofootinbib,superscriptaddress]{revtex4-2}
\usepackage{graphicx}
\usepackage{amsmath}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn jhep_template() -> Template {
    let metadata = TemplateMetadata {
        id: "jhep".to_string(),
        name: "Journal of High Energy Physics".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for JHEP submissions.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "physics".to_string(),
            "hep".to_string(),
            "particle".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "Springer / SISSA".to_string(),
            url: Some("https://jhep.sissa.it".to_string()),
            latex_class: Some("jheppub".to_string()),
            issn: Some("1029-8479".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "a4".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 1,
            font_size: 11.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: JHEP
// Journal of High Energy Physics

#let jhep(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  keywords: (),
  arxiv: none,
  body
) = {
  set page(
    paper: "a4",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
  )

  set text(font: "Times New Roman", size: 11pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.58em)

  set heading(numbering: "1")
  show heading.where(level: 1): it => {
    v(1em)
    text(size: 12pt, weight: "bold", numbering("1", ..counter(heading).get()) + h(0.5em) + it.body)
    v(0.5em)
  }
  show heading.where(level: 2): it => {
    v(0.8em)
    text(size: 11pt, weight: "bold", numbering("1.1", ..counter(heading).get()) + h(0.5em) + it.body)
    v(0.4em)
  }

  // Title block
  align(center)[
    #text(size: 16pt, weight: "bold", title)
    #v(1.5em)
    #for (i, author) in authors.enumerate() {
      if type(author) == str { text(size: 11pt, author) } else {
        text(size: 11pt, author.name)
        if "affil" in author { super(str(author.affil)) }
      }
      if i < authors.len() - 1 { ", " }
    }
    #v(0.8em)
    #set text(size: 10pt, style: "italic")
    #for (i, affil) in affiliations.enumerate() {
      super(str(i + 1)) + affil
      linebreak()
    }
  ]

  v(1.5em)
  block(fill: rgb("#f5f5f5"), inset: 1em, width: 100%, radius: 2pt)[
    #text(weight: "bold", size: 10pt)[Abstract:] #abstract
    #if keywords.len() > 0 {
      v(0.5em)
      text(size: 10pt)[#text(weight: "bold")[Keywords:] #keywords.join(", ")]
    }
    #if arxiv != none {
      v(0.3em)
      text(size: 9pt)[ArXiv ePrint: #arxiv]
    }
  ]
  v(1.5em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass[a4paper,11pt]{article}
\usepackage{jheppub}
\usepackage{graphicx}
\usepackage{amsmath,amssymb}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

// =============================================================================
// Computational & ML
// =============================================================================

fn neurips_template() -> Template {
    let metadata = TemplateMetadata {
        id: "neurips".to_string(),
        name: "NeurIPS".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for NeurIPS conference submissions.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Conference,
        tags: vec![
            "machine-learning".to_string(),
            "ai".to_string(),
            "conference".to_string(),
            "neural-networks".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "NeurIPS Foundation".to_string(),
            url: Some("https://neurips.cc".to_string()),
            latex_class: Some("neurips".to_string()),
            issn: None,
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "letter".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 1,
            font_size: 10.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: NeurIPS
// Conference on Neural Information Processing Systems

#let neurips(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  anonymous: false,
  body
) = {
  set page(
    paper: "us-letter",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
  )

  set text(font: "Times New Roman", size: 10pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.55em)

  set heading(numbering: "1")
  show heading.where(level: 1): it => {
    v(0.8em)
    text(size: 12pt, weight: "bold", numbering("1", ..counter(heading).get()) + h(0.5em) + it.body)
    v(0.4em)
  }
  show heading.where(level: 2): it => {
    v(0.6em)
    text(size: 11pt, weight: "bold", numbering("1.1", ..counter(heading).get()) + h(0.5em) + it.body)
    v(0.3em)
  }

  // Title block
  align(center)[
    #text(size: 17pt, weight: "bold", title)
    #v(1.5em)
    #if anonymous {
      text(size: 11pt)[Anonymous Author(s)]
    } else {
      for (i, author) in authors.enumerate() {
        if type(author) == str { text(size: 11pt, author) } else {
          text(size: 11pt, weight: "bold", author.name)
          if "affil" in author {
            linebreak()
            text(size: 10pt, affiliations.at(author.affil - 1, default: ""))
          }
          if "email" in author {
            linebreak()
            text(size: 9pt, style: "italic", author.email)
          }
        }
        if i < authors.len() - 1 {
          h(2em)
        }
      }
    }
  ]

  v(1.5em)
  block(width: 100%, inset: (x: 2em))[
    #text(weight: "bold", size: 11pt)[Abstract]
    #v(0.3em)
    #abstract
  ]
  v(1.5em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass{article}
\usepackage[final]{neurips_2024}
\usepackage{graphicx}
\usepackage{amsmath,amssymb}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn icml_template() -> Template {
    let metadata = TemplateMetadata {
        id: "icml".to_string(),
        name: "ICML".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for ICML conference submissions.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Conference,
        tags: vec![
            "machine-learning".to_string(),
            "ai".to_string(),
            "conference".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "PMLR".to_string(),
            url: Some("https://icml.cc".to_string()),
            latex_class: Some("icml".to_string()),
            issn: None,
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "letter".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 2,
            font_size: 10.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: ICML
// International Conference on Machine Learning

#let icml(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  anonymous: false,
  body
) = {
  set page(
    paper: "us-letter",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
    columns: 2,
    column-gutter: 6mm,
  )

  set text(font: "Times New Roman", size: 10pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.52em)

  set heading(numbering: "1.")
  show heading.where(level: 1): it => {
    v(0.8em)
    text(size: 11pt, weight: "bold", numbering("1.", ..counter(heading).get()) + h(0.3em) + it.body)
    v(0.4em)
  }
  show heading.where(level: 2): it => {
    v(0.6em)
    text(size: 10pt, weight: "bold", numbering("1.1.", ..counter(heading).get()) + h(0.3em) + it.body)
    v(0.3em)
  }

  // Title block
  place(top + center, float: true, scope: "parent", clearance: 1em)[
    #block(width: 100%)[
      #align(center)[
        #text(size: 14pt, weight: "bold", title)
        #v(1em)
        #if anonymous {
          text(size: 10pt)[Anonymous Author(s)]
        } else {
          for (i, author) in authors.enumerate() {
            if type(author) == str { author } else {
              author.name
              if "affil" in author { super(str(author.affil)) }
            }
            if i < authors.len() - 1 { ", " }
          }
          v(0.5em)
          set text(size: 9pt, style: "italic")
          for (i, affil) in affiliations.enumerate() {
            super(str(i + 1)) + affil
            linebreak()
          }
        }
      ]
    ]
  ]

  v(1em)
  block(width: 100%)[
    #text(weight: "bold", size: 10pt)[Abstract]
    #v(0.2em)
    #abstract
  ]
  v(1em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass{article}
\usepackage[accepted]{icml2024}
\usepackage{graphicx}
\usepackage{amsmath}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn jcp_template() -> Template {
    let metadata = TemplateMetadata {
        id: "jcp".to_string(),
        name: "Journal of Computational Physics".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for J. Comp. Phys. submissions (Elsevier style).".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "computational".to_string(),
            "physics".to_string(),
            "numerical".to_string(),
            "elsevier".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "Elsevier".to_string(),
            url: Some("https://www.journals.elsevier.com/journal-of-computational-physics"
                .to_string()),
            latex_class: Some("elsarticle".to_string()),
            issn: Some("0021-9991".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "a4".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 1,
            font_size: 11.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: Journal of Computational Physics
// Elsevier style

#let jcp(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  keywords: (),
  body
) = {
  set page(
    paper: "a4",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
  )

  set text(font: "Times New Roman", size: 11pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.58em)

  set heading(numbering: "1.")
  show heading.where(level: 1): it => {
    v(1em)
    text(size: 12pt, weight: "bold", numbering("1.", ..counter(heading).get()) + h(0.5em) + it.body)
    v(0.5em)
  }
  show heading.where(level: 2): it => {
    v(0.8em)
    text(size: 11pt, weight: "bold", style: "italic", numbering("1.1.", ..counter(heading).get()) + h(0.5em) + it.body)
    v(0.4em)
  }

  // Title block
  align(center)[
    #text(size: 16pt, weight: "bold", title)
    #v(1.5em)
    #for (i, author) in authors.enumerate() {
      if type(author) == str { text(size: 11pt, author) } else {
        text(size: 11pt, author.name)
        if "affil" in author { super(str(author.affil)) }
      }
      if i < authors.len() - 1 { ", " }
    }
    #v(0.8em)
    #set text(size: 10pt, style: "italic")
    #for (i, affil) in affiliations.enumerate() {
      super(str(i + 1)) + affil
      linebreak()
    }
  ]

  v(1.5em)
  block(width: 100%)[
    #text(weight: "bold", size: 11pt)[Abstract]
    #v(0.3em)
    #abstract
    #v(0.5em)
    #text(style: "italic")[Keywords:] #keywords.join(", ")
  ]
  v(1.5em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass[preprint,12pt]{elsarticle}
\usepackage{graphicx}
\usepackage{amsmath,amssymb}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

// =============================================================================
// General Science
// =============================================================================

fn nature_template() -> Template {
    let metadata = TemplateMetadata {
        id: "nature".to_string(),
        name: "Nature".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for Nature journal submissions.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "multidisciplinary".to_string(),
            "science".to_string(),
            "high-impact".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "Springer Nature".to_string(),
            url: Some("https://www.nature.com".to_string()),
            latex_class: None,
            issn: Some("0028-0836".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "a4".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 1,
            font_size: 11.0,
        },
        exports: vec!["pdf".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: Nature
// Nature journal family style

#let nature(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  body
) = {
  set page(
    paper: "a4",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
  )

  set text(font: "Arial", size: 11pt)
  set par(justify: false, leading: 0.65em)

  // Nature uses unnumbered sections with bold headings
  set heading(numbering: none)
  show heading.where(level: 1): it => {
    v(1em)
    text(size: 12pt, weight: "bold", it.body)
    v(0.5em)
  }
  show heading.where(level: 2): it => {
    v(0.8em)
    text(size: 11pt, weight: "bold", it.body)
    v(0.4em)
  }

  // Title block (Nature style - clean, minimal)
  align(center)[
    #text(size: 18pt, weight: "bold", title)
    #v(1.5em)
    #for (i, author) in authors.enumerate() {
      if type(author) == str { author } else {
        author.name
        if "affil" in author { super(str(author.affil)) }
      }
      if i < authors.len() - 1 { ", " }
    }
    #v(0.8em)
    #set text(size: 10pt)
    #for (i, affil) in affiliations.enumerate() {
      super(str(i + 1)) + affil
      linebreak()
    }
  ]

  v(2em)
  // Nature abstract is a single paragraph, no heading
  block(width: 100%)[
    #text(weight: "bold")[#abstract]
  ]
  v(1.5em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass[11pt]{article}
\usepackage[utf8]{inputenc}
\usepackage{graphicx}
\usepackage{amsmath}
\usepackage[margin=2.5cm]{geometry}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn science_template() -> Template {
    let metadata = TemplateMetadata {
        id: "science".to_string(),
        name: "Science".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for AAAS Science journal submissions.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "multidisciplinary".to_string(),
            "science".to_string(),
            "aaas".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "American Association for the Advancement of Science".to_string(),
            url: Some("https://www.science.org".to_string()),
            latex_class: None,
            issn: Some("0036-8075".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "letter".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 1,
            font_size: 11.0,
        },
        exports: vec!["pdf".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: Science
// AAAS Science journal style

#let science(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  one_sentence: none,
  body
) = {
  set page(
    paper: "us-letter",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
  )

  set text(font: "Times New Roman", size: 11pt)
  set par(justify: true, leading: 0.6em)

  set heading(numbering: none)
  show heading.where(level: 1): it => {
    v(1em)
    text(size: 12pt, weight: "bold", it.body)
    v(0.5em)
  }
  show heading.where(level: 2): it => {
    v(0.8em)
    text(size: 11pt, weight: "bold", style: "italic", it.body)
    v(0.4em)
  }

  // Title block
  align(center)[
    #text(size: 16pt, weight: "bold", title)
    #v(1.2em)
    #for (i, author) in authors.enumerate() {
      if type(author) == str { author } else {
        author.name
        if "affil" in author { super(str(author.affil)) }
        if "corresponding" in author and author.corresponding { text[*] }
      }
      if i < authors.len() - 1 { ", " }
    }
    #v(0.6em)
    #set text(size: 9pt)
    #for (i, affil) in affiliations.enumerate() {
      super(str(i + 1)) + affil
      linebreak()
    }
  ]

  v(1.5em)
  // One-sentence summary (Science requirement)
  if one_sentence != none {
    block(width: 100%)[
      #text(weight: "bold", size: 10pt)[One-sentence summary:] #one_sentence
    ]
    v(0.8em)
  }

  block(width: 100%)[
    #text(weight: "bold", size: 11pt)[Abstract]
    #v(0.2em)
    #abstract
  ]
  v(1.5em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass[11pt]{article}
\usepackage[utf8]{inputenc}
\usepackage{graphicx}
\usepackage{amsmath}
\usepackage[margin=2.5cm]{geometry}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

// =============================================================================
// Biomedical
// =============================================================================

fn pnas_template() -> Template {
    let metadata = TemplateMetadata {
        id: "pnas".to_string(),
        name: "PNAS".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for Proceedings of the National Academy of Sciences.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "biology".to_string(),
            "multidisciplinary".to_string(),
            "usa".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "National Academy of Sciences".to_string(),
            url: Some("https://www.pnas.org".to_string()),
            latex_class: Some("pnas".to_string()),
            issn: Some("0027-8424".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "letter".to_string(),
            margins: PageMargins {
                top: 20.0,
                right: 20.0,
                bottom: 20.0,
                left: 20.0,
            },
            columns: 2,
            font_size: 9.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: PNAS
// Proceedings of the National Academy of Sciences

#let pnas(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  significance: none,
  keywords: (),
  body
) = {
  set page(
    paper: "us-letter",
    margin: (top: 2cm, bottom: 2cm, left: 2cm, right: 2cm),
    columns: 2,
    column-gutter: 5mm,
  )

  set text(font: "Times New Roman", size: 9pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.5em)

  set heading(numbering: none)
  show heading.where(level: 1): it => {
    v(0.6em)
    text(size: 10pt, weight: "bold", it.body)
    v(0.3em)
  }
  show heading.where(level: 2): it => {
    v(0.5em)
    text(size: 9pt, weight: "bold", style: "italic", it.body)
    v(0.2em)
  }

  // Title block
  place(top + center, float: true, scope: "parent", clearance: 1em)[
    #block(width: 100%)[
      #align(center)[
        #text(size: 14pt, weight: "bold", title)
        #v(0.8em)
        #text(size: 9pt)[
          #for (i, author) in authors.enumerate() {
            if type(author) == str { author } else {
              author.name
              if "affil" in author { super(str(author.affil)) }
            }
            if i < authors.len() - 1 { ", " }
          }
        ]
        #v(0.5em)
        #set text(size: 8pt)
        #for (i, affil) in affiliations.enumerate() {
          super(str(i + 1)) + affil
          linebreak()
        }
      ]
    ]
  ]

  v(1em)
  // Significance statement (PNAS requirement)
  if significance != none {
    block(fill: rgb("#f0f0f0"), inset: 0.5em, width: 100%, radius: 2pt)[
      #text(weight: "bold", size: 8pt)[Significance]
      #v(0.2em)
      #text(size: 8pt)[#significance]
    ]
    v(0.5em)
  }

  block(width: 100%)[
    #text(size: 8pt)[#abstract]
    #if keywords.len() > 0 {
      v(0.3em)
      text(size: 8pt)[#text(weight: "bold")[Keywords:] #keywords.join(" | ")]
    }
  ]
  v(1em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass[twocolumn]{pnas-new}
\usepackage{graphicx}
\usepackage{amsmath}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn plos_template() -> Template {
    let metadata = TemplateMetadata {
        id: "plos".to_string(),
        name: "PLOS ONE".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for PLOS ONE open-access submissions.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "open-access".to_string(),
            "multidisciplinary".to_string(),
            "biology".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "Public Library of Science".to_string(),
            url: Some("https://journals.plos.org/plosone/".to_string()),
            latex_class: Some("plos".to_string()),
            issn: Some("1932-6203".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "letter".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 1,
            font_size: 10.0,
        },
        exports: vec!["pdf".to_string(), "latex".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: PLOS ONE
// Open-access multidisciplinary journal

#let plos(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  body
) = {
  set page(
    paper: "us-letter",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
  )

  set text(font: "Times New Roman", size: 10pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.55em)

  set heading(numbering: none)
  show heading.where(level: 1): it => {
    v(1em)
    text(size: 12pt, weight: "bold", it.body)
    v(0.5em)
  }
  show heading.where(level: 2): it => {
    v(0.8em)
    text(size: 11pt, weight: "bold", it.body)
    v(0.4em)
  }

  // Title block
  text(size: 16pt, weight: "bold", title)
  v(1em)
  for (i, author) in authors.enumerate() {
    if type(author) == str { author } else {
      author.name
      if "affil" in author { super(str(author.affil)) }
    }
    if i < authors.len() - 1 { ", " }
  }
  v(0.5em)
  set text(size: 9pt)
  for (i, affil) in affiliations.enumerate() {
    text(weight: "bold")[#(i + 1)] + h(0.3em) + affil
    linebreak()
  }

  v(1.5em)
  block(width: 100%)[
    #text(weight: "bold", size: 11pt)[Abstract]
    #v(0.3em)
    #abstract
  ]
  v(1.5em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: Some(
            r##"\documentclass{plos}
\usepackage{graphicx}
\usepackage{amsmath}
"##
            .to_string(),
        ),
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn elife_template() -> Template {
    let metadata = TemplateMetadata {
        id: "elife".to_string(),
        name: "eLife".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for eLife open-access life sciences journal.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "open-access".to_string(),
            "life-sciences".to_string(),
            "biology".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "eLife Sciences Publications".to_string(),
            url: Some("https://elifesciences.org".to_string()),
            latex_class: None,
            issn: Some("2050-084X".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "a4".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 1,
            font_size: 11.0,
        },
        exports: vec!["pdf".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: eLife
// Open-access life sciences journal

#let elife(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  digest: none,
  body
) = {
  set page(
    paper: "a4",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
  )

  set text(font: "Noto Sans", size: 11pt)
  set par(justify: true, leading: 0.6em)

  set heading(numbering: none)
  show heading.where(level: 1): it => {
    v(1em)
    text(size: 14pt, weight: "bold", it.body)
    v(0.5em)
  }
  show heading.where(level: 2): it => {
    v(0.8em)
    text(size: 12pt, weight: "bold", it.body)
    v(0.4em)
  }

  // Title block
  align(center)[
    #text(size: 18pt, weight: "bold", fill: rgb("#0067a0"), title)
    #v(1.5em)
    #for (i, author) in authors.enumerate() {
      if type(author) == str { author } else {
        author.name
        if "affil" in author { super(str(author.affil)) }
      }
      if i < authors.len() - 1 { ", " }
    }
    #v(0.6em)
    #set text(size: 9pt)
    #for (i, affil) in affiliations.enumerate() {
      super(str(i + 1)) + affil
      linebreak()
    }
  ]

  v(1.5em)
  block(width: 100%)[
    #text(weight: "bold", size: 12pt)[Abstract]
    #v(0.3em)
    #abstract
  ]

  // eLife digest (plain language summary)
  if digest != none {
    v(1em)
    block(fill: rgb("#e8f4f8"), inset: 1em, width: 100%, radius: 4pt)[
      #text(weight: "bold", size: 11pt, fill: rgb("#0067a0"))[eLife digest]
      #v(0.3em)
      #digest
    ]
  }

  v(1.5em)
  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: None,
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn cell_template() -> Template {
    let metadata = TemplateMetadata {
        id: "cell".to_string(),
        name: "Cell".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for Cell Press journals.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "biology".to_string(),
            "cell-biology".to_string(),
            "high-impact".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "Cell Press / Elsevier".to_string(),
            url: Some("https://www.cell.com".to_string()),
            latex_class: None,
            issn: Some("0092-8674".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "letter".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 1,
            font_size: 11.0,
        },
        exports: vec!["pdf".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: Cell
// Cell Press journal style

#let cell(
  title: none,
  authors: (),
  affiliations: (),
  summary: none,
  highlights: (),
  body
) = {
  set page(
    paper: "us-letter",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
  )

  set text(font: "Arial", size: 11pt)
  set par(justify: true, leading: 0.6em)

  set heading(numbering: none)
  show heading.where(level: 1): it => {
    v(1em)
    text(size: 13pt, weight: "bold", it.body)
    v(0.5em)
  }
  show heading.where(level: 2): it => {
    v(0.8em)
    text(size: 11pt, weight: "bold", it.body)
    v(0.4em)
  }

  // Title block
  text(size: 18pt, weight: "bold", title)
  v(1.2em)
  for (i, author) in authors.enumerate() {
    if type(author) == str { author } else {
      author.name
      if "affil" in author { super(str(author.affil)) }
    }
    if i < authors.len() - 1 { ", " }
  }
  v(0.6em)
  set text(size: 9pt)
  for (i, affil) in affiliations.enumerate() {
    super(str(i + 1)) + affil
    linebreak()
  }

  v(1.5em)
  // Highlights (Cell requirement)
  if highlights.len() > 0 {
    block(stroke: (left: 3pt + rgb("#1a5276")), inset: (left: 1em, y: 0.5em))[
      #text(weight: "bold", size: 11pt)[Highlights]
      #v(0.3em)
      #for highlight in highlights {
        [• #highlight]
        linebreak()
      }
    ]
    v(1em)
  }

  block(width: 100%)[
    #text(weight: "bold", size: 11pt)[Summary]
    #v(0.3em)
    #summary
  ]
  v(1.5em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: None,
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn nejm_template() -> Template {
    let metadata = TemplateMetadata {
        id: "nejm".to_string(),
        name: "New England Journal of Medicine".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for NEJM submissions.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "medicine".to_string(),
            "clinical".to_string(),
            "high-impact".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "Massachusetts Medical Society".to_string(),
            url: Some("https://www.nejm.org".to_string()),
            latex_class: None,
            issn: Some("0028-4793".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "letter".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 2,
            font_size: 9.0,
        },
        exports: vec!["pdf".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: NEJM
// New England Journal of Medicine

#let nejm(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  body
) = {
  set page(
    paper: "us-letter",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
    columns: 2,
    column-gutter: 5mm,
  )

  set text(font: "Times New Roman", size: 9pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.5em)

  set heading(numbering: none)
  show heading.where(level: 1): it => {
    v(0.8em)
    text(size: 10pt, weight: "bold", upper(it.body))
    v(0.4em)
  }
  show heading.where(level: 2): it => {
    v(0.6em)
    text(size: 9pt, weight: "bold", it.body)
    v(0.3em)
  }

  // Title block
  place(top + center, float: true, scope: "parent", clearance: 1em)[
    #block(width: 100%)[
      #align(center)[
        #text(size: 14pt, weight: "bold", title)
        #v(0.8em)
        #for (i, author) in authors.enumerate() {
          if type(author) == str { author } else {
            author.name
            if "affil" in author { super(str(author.affil)) }
          }
          if i < authors.len() - 1 { ", " }
        }
        #v(0.5em)
        #set text(size: 8pt)
        #for (i, affil) in affiliations.enumerate() {
          super(str(i + 1)) + affil
          linebreak()
        }
      ]
    ]
  ]

  v(1em)
  block(width: 100%)[
    #text(weight: "bold", size: 9pt)[ABSTRACT]
    #v(0.2em)
    #abstract
  ]
  v(1em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: None,
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn lancet_template() -> Template {
    let metadata = TemplateMetadata {
        id: "lancet".to_string(),
        name: "The Lancet".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for The Lancet family journals.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "medicine".to_string(),
            "clinical".to_string(),
            "elsevier".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "Elsevier".to_string(),
            url: Some("https://www.thelancet.com".to_string()),
            latex_class: None,
            issn: Some("0140-6736".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "a4".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 2,
            font_size: 9.0,
        },
        exports: vec!["pdf".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: The Lancet
// Lancet family journals

#let lancet(
  title: none,
  authors: (),
  affiliations: (),
  summary: none,
  body
) = {
  set page(
    paper: "a4",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
    columns: 2,
    column-gutter: 5mm,
  )

  set text(font: "Times New Roman", size: 9pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.5em)

  set heading(numbering: none)
  show heading.where(level: 1): it => {
    v(0.8em)
    text(size: 10pt, weight: "bold", it.body)
    v(0.4em)
  }
  show heading.where(level: 2): it => {
    v(0.6em)
    text(size: 9pt, weight: "bold", it.body)
    v(0.3em)
  }

  // Title block
  place(top + center, float: true, scope: "parent", clearance: 1em)[
    #block(width: 100%)[
      #text(size: 14pt, weight: "bold", title)
      #v(0.8em)
      #for (i, author) in authors.enumerate() {
        if type(author) == str { author } else {
          author.name
          if "affil" in author { super(str(author.affil)) }
        }
        if i < authors.len() - 1 { ", " }
      }
      #v(0.5em)
      #set text(size: 8pt)
      #for (i, affil) in affiliations.enumerate() {
        super(str(i + 1)) + affil
        linebreak()
      }
    ]
  ]

  v(1em)
  block(width: 100%)[
    #text(weight: "bold", size: 10pt)[Summary]
    #v(0.2em)
    #summary
  ]
  v(1em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: None,
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn bmj_template() -> Template {
    let metadata = TemplateMetadata {
        id: "bmj".to_string(),
        name: "BMJ".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for British Medical Journal submissions.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "medicine".to_string(),
            "clinical".to_string(),
            "uk".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "BMJ Publishing Group".to_string(),
            url: Some("https://www.bmj.com".to_string()),
            latex_class: None,
            issn: Some("0959-8138".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "a4".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 2,
            font_size: 9.0,
        },
        exports: vec!["pdf".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: BMJ
// British Medical Journal

#let bmj(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  what_is_known: none,
  what_this_adds: none,
  body
) = {
  set page(
    paper: "a4",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
    columns: 2,
    column-gutter: 5mm,
  )

  set text(font: "Times New Roman", size: 9pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.5em)

  set heading(numbering: none)
  show heading.where(level: 1): it => {
    v(0.8em)
    text(size: 10pt, weight: "bold", it.body)
    v(0.4em)
  }
  show heading.where(level: 2): it => {
    v(0.6em)
    text(size: 9pt, weight: "bold", it.body)
    v(0.3em)
  }

  // Title block
  place(top + center, float: true, scope: "parent", clearance: 1em)[
    #block(width: 100%)[
      #align(center)[
        #text(size: 14pt, weight: "bold", title)
        #v(0.8em)
        #for (i, author) in authors.enumerate() {
          if type(author) == str { author } else {
            author.name
            if "affil" in author { super(str(author.affil)) }
          }
          if i < authors.len() - 1 { ", " }
        }
        #v(0.5em)
        #set text(size: 8pt)
        #for (i, affil) in affiliations.enumerate() {
          super(str(i + 1)) + affil
          linebreak()
        }
      ]
    ]
  ]

  v(1em)
  // What is already known / What this study adds (BMJ boxes)
  if what_is_known != none or what_this_adds != none {
    block(stroke: 1pt, inset: 0.8em, width: 100%)[
      #if what_is_known != none {
        text(weight: "bold", size: 8pt)[What is already known on this topic]
        v(0.2em)
        text(size: 8pt)[#what_is_known]
        v(0.5em)
      }
      #if what_this_adds != none {
        text(weight: "bold", size: 8pt)[What this study adds]
        v(0.2em)
        text(size: 8pt)[#what_this_adds]
      }
    ]
    v(0.5em)
  }

  block(width: 100%)[
    #text(weight: "bold", size: 9pt)[Abstract]
    #v(0.2em)
    #abstract
  ]
  v(1em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: None,
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn jama_template() -> Template {
    let metadata = TemplateMetadata {
        id: "jama".to_string(),
        name: "JAMA".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for Journal of the American Medical Association.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "medicine".to_string(),
            "clinical".to_string(),
            "usa".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "American Medical Association".to_string(),
            url: Some("https://jamanetwork.com".to_string()),
            latex_class: None,
            issn: Some("0098-7484".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "letter".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 2,
            font_size: 9.0,
        },
        exports: vec!["pdf".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: JAMA
// Journal of the American Medical Association

#let jama(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  key_points: (),
  body
) = {
  set page(
    paper: "us-letter",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
    columns: 2,
    column-gutter: 5mm,
  )

  set text(font: "Times New Roman", size: 9pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.5em)

  set heading(numbering: none)
  show heading.where(level: 1): it => {
    v(0.8em)
    text(size: 10pt, weight: "bold", it.body)
    v(0.4em)
  }
  show heading.where(level: 2): it => {
    v(0.6em)
    text(size: 9pt, weight: "bold", it.body)
    v(0.3em)
  }

  // Title block
  place(top + center, float: true, scope: "parent", clearance: 1em)[
    #block(width: 100%)[
      #align(center)[
        #text(size: 14pt, weight: "bold", title)
        #v(0.8em)
        #for (i, author) in authors.enumerate() {
          if type(author) == str { author } else {
            author.name
            if "affil" in author { super(str(author.affil)) }
          }
          if i < authors.len() - 1 { ", " }
        }
        #v(0.5em)
        #set text(size: 8pt)
        #for (i, affil) in affiliations.enumerate() {
          super(str(i + 1)) + affil
          linebreak()
        }
      ]
    ]
  ]

  v(1em)
  // Key Points box (JAMA requirement)
  if key_points.len() > 0 {
    block(fill: rgb("#f5f5f5"), inset: 0.8em, width: 100%, radius: 2pt)[
      #text(weight: "bold", size: 9pt)[Key Points]
      #v(0.3em)
      #for point in key_points {
        text(size: 8pt)[• #point]
        linebreak()
      }
    ]
    v(0.5em)
  }

  block(width: 100%)[
    #text(weight: "bold", size: 9pt)[Abstract]
    #v(0.2em)
    #abstract
  ]
  v(1em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: None,
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn bioinformatics_template() -> Template {
    let metadata = TemplateMetadata {
        id: "bioinformatics".to_string(),
        name: "Bioinformatics".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for Oxford Bioinformatics journal.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "bioinformatics".to_string(),
            "computational-biology".to_string(),
            "oxford".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "Oxford University Press".to_string(),
            url: Some("https://academic.oup.com/bioinformatics".to_string()),
            latex_class: None,
            issn: Some("1367-4803".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "a4".to_string(),
            margins: PageMargins {
                top: 20.0,
                right: 20.0,
                bottom: 20.0,
                left: 20.0,
            },
            columns: 2,
            font_size: 9.0,
        },
        exports: vec!["pdf".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: Bioinformatics
// Oxford Bioinformatics journal

#let bioinformatics(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  motivation: none,
  results: none,
  availability: none,
  contact: none,
  body
) = {
  set page(
    paper: "a4",
    margin: (top: 2cm, bottom: 2cm, left: 2cm, right: 2cm),
    columns: 2,
    column-gutter: 5mm,
  )

  set text(font: "Times New Roman", size: 9pt)
  set par(justify: true, first-line-indent: 1em, leading: 0.5em)

  set heading(numbering: "1")
  show heading.where(level: 1): it => {
    v(0.8em)
    text(size: 10pt, weight: "bold", numbering("1", ..counter(heading).get()) + h(0.3em) + it.body)
    v(0.4em)
  }
  show heading.where(level: 2): it => {
    v(0.6em)
    text(size: 9pt, weight: "bold", numbering("1.1", ..counter(heading).get()) + h(0.3em) + it.body)
    v(0.3em)
  }

  // Title block
  place(top + center, float: true, scope: "parent", clearance: 1em)[
    #block(width: 100%)[
      #align(center)[
        #text(size: 14pt, weight: "bold", title)
        #v(0.8em)
        #for (i, author) in authors.enumerate() {
          if type(author) == str { author } else {
            author.name
            if "affil" in author { super(str(author.affil)) }
          }
          if i < authors.len() - 1 { ", " }
        }
        #v(0.5em)
        #set text(size: 8pt, style: "italic")
        #for (i, affil) in affiliations.enumerate() {
          super(str(i + 1)) + affil
          linebreak()
        }
      ]
    ]
  ]

  v(1em)
  // Structured abstract (Bioinformatics format)
  block(width: 100%)[
    #text(weight: "bold", size: 9pt)[Abstract]
    #v(0.3em)
    #if motivation != none {
      text(weight: "bold", size: 8pt)[Motivation:] + h(0.3em) + text(size: 8pt)[#motivation]
      linebreak()
    }
    #if results != none {
      text(weight: "bold", size: 8pt)[Results:] + h(0.3em) + text(size: 8pt)[#results]
      linebreak()
    }
    #if availability != none {
      text(weight: "bold", size: 8pt)[Availability:] + h(0.3em) + text(size: 8pt)[#availability]
      linebreak()
    }
    #if contact != none {
      text(weight: "bold", size: 8pt)[Contact:] + h(0.3em) + text(size: 8pt)[#contact]
    }
  ]
  v(1em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: None,
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

fn nature_medicine_template() -> Template {
    let metadata = TemplateMetadata {
        id: "naturemed".to_string(),
        name: "Nature Medicine".to_string(),
        version: "1.0.0".to_string(),
        description: "Template for Nature Medicine submissions.".to_string(),
        author: "imprint community".to_string(),
        license: "MIT".to_string(),
        category: TemplateCategory::Journal,
        tags: vec![
            "medicine".to_string(),
            "nature".to_string(),
            "high-impact".to_string(),
        ],
        journal: Some(JournalInfo {
            publisher: "Springer Nature".to_string(),
            url: Some("https://www.nature.com/nm/".to_string()),
            latex_class: None,
            issn: Some("1078-8956".to_string()),
        }),
        typst: TypstRequirements {
            min_version: Some("0.14.0".to_string()),
        },
        page_defaults: PageDefaults {
            size: "a4".to_string(),
            margins: PageMargins {
                top: 25.0,
                right: 25.0,
                bottom: 25.0,
                left: 25.0,
            },
            columns: 1,
            font_size: 11.0,
        },
        exports: vec!["pdf".to_string()],
        created_at: Some("2026-01-27".to_string()),
        modified_at: Some("2026-01-27".to_string()),
    };

    let typst_source = r##"// imprint template: Nature Medicine
// Nature Medicine journal style

#let naturemed(
  title: none,
  authors: (),
  affiliations: (),
  abstract: none,
  body
) = {
  set page(
    paper: "a4",
    margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm),
  )

  set text(font: "Arial", size: 11pt)
  set par(justify: false, leading: 0.65em)

  set heading(numbering: none)
  show heading.where(level: 1): it => {
    v(1em)
    text(size: 12pt, weight: "bold", it.body)
    v(0.5em)
  }
  show heading.where(level: 2): it => {
    v(0.8em)
    text(size: 11pt, weight: "bold", it.body)
    v(0.4em)
  }

  // Title block (Nature style)
  align(center)[
    #text(size: 18pt, weight: "bold", title)
    #v(1.5em)
    #for (i, author) in authors.enumerate() {
      if type(author) == str { author } else {
        author.name
        if "affil" in author { super(str(author.affil)) }
      }
      if i < authors.len() - 1 { ", " }
    }
    #v(0.8em)
    #set text(size: 10pt)
    #for (i, affil) in affiliations.enumerate() {
      super(str(i + 1)) + affil
      linebreak()
    }
  ]

  v(2em)
  block(width: 100%)[
    #text(weight: "bold")[#abstract]
  ]
  v(1.5em)

  body
}
"##
    .to_string();

    Template {
        metadata,
        typst_source,
        latex_preamble: None,
        csl_style: None,
        source: TemplateSource::Builtin,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_builtin_templates_count() {
        let templates = builtin_templates();
        assert!(templates.len() >= 20, "Should have at least 20 built-in templates, got {}", templates.len());
    }

    #[test]
    fn test_builtin_templates_have_valid_ids() {
        for template in builtin_templates() {
            assert!(!template.id().is_empty(), "Template ID should not be empty");
            assert!(
                template.id().chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_'),
                "Template ID '{}' contains invalid characters",
                template.id()
            );
        }
    }

    #[test]
    fn test_builtin_templates_have_source() {
        for template in builtin_templates() {
            assert!(!template.typst_source.is_empty(), "Template '{}' should have Typst source", template.id());
        }
    }

    #[test]
    fn test_journal_templates_have_journal_info() {
        for template in builtin_templates() {
            if template.metadata.category == TemplateCategory::Journal {
                assert!(
                    template.metadata.journal.is_some(),
                    "Journal template '{}' should have journal info",
                    template.id()
                );
            }
        }
    }

    #[test]
    fn test_specific_templates_exist() {
        let templates = builtin_templates();
        let ids: Vec<&str> = templates.iter().map(|t| t.id()).collect();

        // Check for key templates from each category
        assert!(ids.contains(&"generic"), "generic template should exist");
        assert!(ids.contains(&"mnras"), "mnras template should exist");
        assert!(ids.contains(&"nature"), "nature template should exist");
        assert!(ids.contains(&"neurips"), "neurips template should exist");
        assert!(ids.contains(&"pnas"), "pnas template should exist");
    }
}
