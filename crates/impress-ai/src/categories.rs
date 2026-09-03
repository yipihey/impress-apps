//! The task-category catalogue: the stable ids apps use when they ask for
//! "the model for library Q&A" or "the model for keyword tagging". Ported
//! from the Swift `AITaskCategory` table so both sides agree on ids; the
//! per-category model assignments live in the preferences file.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TaskCategory {
    pub id: &'static str,
    pub name: &'static str,
    /// SF Symbol name for the GUI.
    pub icon: &'static str,
    pub description: &'static str,
    pub parent: Option<&'static str>,
    pub apps: &'static [&'static str],
    pub supports_comparison: bool,
}

impl TaskCategory {
    pub fn is_root(&self) -> bool {
        self.parent.is_none()
    }
}

pub const TASK_CATEGORIES: &[TaskCategory] = &[
    // Roots.
    TaskCategory {
        id: "writing",
        name: "Writing",
        icon: "pencil.and.outline",
        description: "Text editing and improvement tasks",
        parent: None,
        apps: &["imprint"],
        supports_comparison: false,
    },
    TaskCategory {
        id: "research",
        name: "Research",
        icon: "magnifyingglass",
        description: "Academic research assistance and AI counsel conversations",
        parent: None,
        apps: &["imbib", "imprint", "impart"],
        supports_comparison: false,
    },
    TaskCategory {
        id: "citation",
        name: "Citations",
        icon: "quote.opening",
        description: "Citation finding and formatting",
        parent: None,
        apps: &["imprint", "imbib"],
        supports_comparison: false,
    },
    TaskCategory {
        id: "analysis",
        name: "Analysis",
        icon: "chart.bar.doc.horizontal",
        description: "Content analysis and review",
        parent: None,
        apps: &["imprint"],
        supports_comparison: false,
    },
    TaskCategory {
        id: "data",
        name: "Data",
        icon: "tablecells",
        description: "Data generation and interpretation",
        parent: None,
        apps: &["implore"],
        supports_comparison: false,
    },
    TaskCategory {
        id: "agent",
        name: "Background Agents",
        icon: "gearshape.2",
        description: "Model tiers for impel's background executors",
        parent: None,
        apps: &["impel"],
        supports_comparison: false,
    },
    // Writing.
    TaskCategory {
        id: "writing.rewrite",
        name: "Text Rewriting",
        icon: "arrow.2.squarepath",
        description: "Improve clarity, concision, and tone",
        parent: Some("writing"),
        apps: &["imprint"],
        supports_comparison: true,
    },
    TaskCategory {
        id: "writing.grammar",
        name: "Grammar & Style",
        icon: "textformat.abc",
        description: "Spelling and grammar fixes",
        parent: Some("writing"),
        apps: &["imprint"],
        supports_comparison: true,
    },
    // Research.
    TaskCategory {
        id: "research.search",
        name: "Query Expansion",
        icon: "text.magnifyingglass",
        description: "Expand search queries with synonyms and related concepts",
        parent: Some("research"),
        apps: &["imbib"],
        supports_comparison: true,
    },
    TaskCategory {
        id: "research.summarize",
        name: "Summarization",
        icon: "doc.text.magnifyingglass",
        description: "Generate abstract and document summaries",
        parent: Some("research"),
        apps: &["imbib", "imprint"],
        supports_comparison: true,
    },
    TaskCategory {
        id: "research.discover",
        name: "Paper Discovery",
        icon: "sparkle.magnifyingglass",
        description: "Find related papers and suggestions",
        parent: Some("research"),
        apps: &["imbib"],
        supports_comparison: true,
    },
    TaskCategory {
        id: "research.compare",
        name: "Paper Comparison",
        icon: "rectangle.2.swap",
        description: "Compare methods, evidence, and conclusions across publications",
        parent: Some("research"),
        apps: &["imbib"],
        supports_comparison: true,
    },
    TaskCategory {
        id: "research.rag",
        name: "Library Q&A",
        icon: "books.vertical",
        description: "Answer questions grounded in the selected publication corpus",
        parent: Some("research"),
        apps: &["imbib"],
        supports_comparison: true,
    },
    // Citations.
    TaskCategory {
        id: "citation.find",
        name: "Citation Finding",
        icon: "doc.text.magnifyingglass",
        description: "Identify citations needed for claims",
        parent: Some("citation"),
        apps: &["imprint", "imbib"],
        supports_comparison: true,
    },
    TaskCategory {
        id: "citation.format",
        name: "Citation Formatting",
        icon: "list.bullet.indent",
        description: "Generate and format BibTeX entries",
        parent: Some("citation"),
        apps: &["imbib"],
        supports_comparison: false,
    },
    // Analysis.
    TaskCategory {
        id: "analysis.review",
        name: "Content Review",
        icon: "checkmark.circle",
        description: "Review logical flow and arguments",
        parent: Some("analysis"),
        apps: &["imprint"],
        supports_comparison: true,
    },
    TaskCategory {
        id: "analysis.explain",
        name: "Explanation",
        icon: "lightbulb",
        description: "Simplify or add detail to explanations",
        parent: Some("analysis"),
        apps: &["imprint"],
        supports_comparison: true,
    },
    // Data.
    TaskCategory {
        id: "data.generate",
        name: "Formula Generation",
        icon: "function",
        description: "Generate mathematical formulas from descriptions",
        parent: Some("data"),
        apps: &["implore"],
        supports_comparison: true,
    },
    TaskCategory {
        id: "data.interpret",
        name: "Data Interpretation",
        icon: "chart.xyaxis.line",
        description: "Describe statistical patterns and insights",
        parent: Some("data"),
        apps: &["implore"],
        supports_comparison: true,
    },
    // Background agents (impel-taskd executors). These never inherit the
    // interactive selection: a cloud model chosen for chat must not silently
    // start paying for background work.
    TaskCategory {
        id: "agent.classify",
        name: "Keyword Tagging",
        icon: "tag",
        description: "Propose tags for enriched publications",
        parent: Some("agent"),
        apps: &["impel"],
        supports_comparison: false,
    },
    TaskCategory {
        id: "agent.memory",
        name: "Memory Consolidation",
        icon: "brain",
        description: "Distil durable claims during memory consolidation",
        parent: Some("agent"),
        apps: &["impel"],
        supports_comparison: false,
    },
    TaskCategory {
        id: "agent.throughline",
        name: "Throughline Drafting",
        icon: "text.badge.checkmark",
        description: "Draft throughline proposals for review",
        parent: Some("agent"),
        apps: &["impel"],
        supports_comparison: false,
    },
];

pub fn category(id: &str) -> Option<&'static TaskCategory> {
    TASK_CATEGORIES.iter().find(|category| category.id == id)
}

pub fn root_categories() -> impl Iterator<Item = &'static TaskCategory> {
    TASK_CATEGORIES.iter().filter(|category| category.is_root())
}

/// Leaf categories, optionally only those an app supports.
pub fn leaf_categories(app: Option<&str>) -> Vec<&'static TaskCategory> {
    TASK_CATEGORIES
        .iter()
        .filter(|category| !category.is_root())
        .filter(|category| app.is_none_or(|app| category.apps.contains(&app)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_unique_and_parents_exist() {
        let mut seen = std::collections::BTreeSet::new();
        for category in TASK_CATEGORIES {
            assert!(seen.insert(category.id), "duplicate {}", category.id);
            if let Some(parent) = category.parent {
                let root = self::category(parent).expect(parent);
                assert!(root.is_root());
                assert!(category.id.starts_with(&format!("{parent}.")));
            }
        }
        assert_eq!(root_categories().count(), 6);
        assert_eq!(leaf_categories(None).len(), 16);
        assert_eq!(leaf_categories(Some("implore")).len(), 2);
        assert!(leaf_categories(Some("impel"))
            .iter()
            .all(|category| category.parent == Some("agent")));
        assert!(category("research.rag").unwrap().supports_comparison);
    }
}
