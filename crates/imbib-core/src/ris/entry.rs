//! RIS entry data structures

/// RIS reference type
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum RISType {
    ABST,    // Abstract
    ADVS,    // Audiovisual material
    AGGR,    // Aggregated Database
    ANCIENT, // Ancient Text
    ART,     // Art Work
    BILL,    // Bill
    BLOG,    // Blog
    BOOK,    // Whole book
    CASE,    // Case
    CHAP,    // Book chapter
    CHART,   // Chart
    CLSWK,   // Classical Work
    COMP,    // Computer program
    CONF,    // Conference proceeding
    CPAPER,  // Conference paper
    CTLG,    // Catalog
    DATA,    // Data file
    DBASE,   // Online Database
    DICT,    // Dictionary
    EBOOK,   // Electronic Book
    ECHAP,   // Electronic Book Section
    EDBOOK,  // Edited Book
    EJOUR,   // Electronic Article
    ELEC,    // Web Page
    ENCYC,   // Encyclopedia
    EQUA,    // Equation
    FIGURE,  // Figure
    GEN,     // Generic
    GOVDOC,  // Government Document
    GRANT,   // Grant
    HEAR,    // Hearing
    ICOMM,   // Internet Communication
    INPR,    // In Press
    JFULL,   // Journal (full)
    JOUR,    // Journal
    LEGAL,   // Legal Rule or Regulation
    MANSCPT, // Manuscript
    MAP,     // Map
    MGZN,    // Magazine article
    MPCT,    // Motion picture
    MULTI,   // Online Multimedia
    MUSIC,   // Music score
    NEWS,    // Newspaper
    PAMP,    // Pamphlet
    PAT,     // Patent
    PCOMM,   // Personal communication
    RPRT,    // Report
    SER,     // Serial publication
    SLIDE,   // Slide
    SOUND,   // Sound recording
    STAND,   // Standard
    STAT,    // Statute
    THES,    // Thesis/Dissertation
    UNBILL,  // Unenacted Bill
    UNPB,    // Unpublished work
    VIDEO,   // Video recording
    Unknown, // Unknown type
}

impl RISType {
    /// Parse a RIS type from string
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Self {
        match s.trim().to_uppercase().as_str() {
            "ABST" => Self::ABST,
            "ADVS" => Self::ADVS,
            "AGGR" => Self::AGGR,
            "ANCIENT" => Self::ANCIENT,
            "ART" => Self::ART,
            "BILL" => Self::BILL,
            "BLOG" => Self::BLOG,
            "BOOK" => Self::BOOK,
            "CASE" => Self::CASE,
            "CHAP" => Self::CHAP,
            "CHART" => Self::CHART,
            "CLSWK" => Self::CLSWK,
            "COMP" => Self::COMP,
            "CONF" => Self::CONF,
            "CPAPER" => Self::CPAPER,
            "CTLG" => Self::CTLG,
            "DATA" => Self::DATA,
            "DBASE" => Self::DBASE,
            "DICT" => Self::DICT,
            "EBOOK" => Self::EBOOK,
            "ECHAP" => Self::ECHAP,
            "EDBOOK" => Self::EDBOOK,
            "EJOUR" => Self::EJOUR,
            "ELEC" => Self::ELEC,
            "ENCYC" => Self::ENCYC,
            "EQUA" => Self::EQUA,
            "FIGURE" => Self::FIGURE,
            "GEN" => Self::GEN,
            "GOVDOC" => Self::GOVDOC,
            "GRANT" => Self::GRANT,
            "HEAR" => Self::HEAR,
            "ICOMM" => Self::ICOMM,
            "INPR" => Self::INPR,
            "JFULL" => Self::JFULL,
            "JOUR" => Self::JOUR,
            "LEGAL" => Self::LEGAL,
            "MANSCPT" => Self::MANSCPT,
            "MAP" => Self::MAP,
            "MGZN" => Self::MGZN,
            "MPCT" => Self::MPCT,
            "MULTI" => Self::MULTI,
            "MUSIC" => Self::MUSIC,
            "NEWS" => Self::NEWS,
            "PAMP" => Self::PAMP,
            "PAT" => Self::PAT,
            "PCOMM" => Self::PCOMM,
            "RPRT" => Self::RPRT,
            "SER" => Self::SER,
            "SLIDE" => Self::SLIDE,
            "SOUND" => Self::SOUND,
            "STAND" => Self::STAND,
            "STAT" => Self::STAT,
            "THES" => Self::THES,
            "UNBILL" => Self::UNBILL,
            "UNPB" => Self::UNPB,
            "VIDEO" => Self::VIDEO,
            _ => Self::Unknown,
        }
    }

    /// Convert to canonical string representation
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ABST => "ABST",
            Self::ADVS => "ADVS",
            Self::AGGR => "AGGR",
            Self::ANCIENT => "ANCIENT",
            Self::ART => "ART",
            Self::BILL => "BILL",
            Self::BLOG => "BLOG",
            Self::BOOK => "BOOK",
            Self::CASE => "CASE",
            Self::CHAP => "CHAP",
            Self::CHART => "CHART",
            Self::CLSWK => "CLSWK",
            Self::COMP => "COMP",
            Self::CONF => "CONF",
            Self::CPAPER => "CPAPER",
            Self::CTLG => "CTLG",
            Self::DATA => "DATA",
            Self::DBASE => "DBASE",
            Self::DICT => "DICT",
            Self::EBOOK => "EBOOK",
            Self::ECHAP => "ECHAP",
            Self::EDBOOK => "EDBOOK",
            Self::EJOUR => "EJOUR",
            Self::ELEC => "ELEC",
            Self::ENCYC => "ENCYC",
            Self::EQUA => "EQUA",
            Self::FIGURE => "FIGURE",
            Self::GEN => "GEN",
            Self::GOVDOC => "GOVDOC",
            Self::GRANT => "GRANT",
            Self::HEAR => "HEAR",
            Self::ICOMM => "ICOMM",
            Self::INPR => "INPR",
            Self::JFULL => "JFULL",
            Self::JOUR => "JOUR",
            Self::LEGAL => "LEGAL",
            Self::MANSCPT => "MANSCPT",
            Self::MAP => "MAP",
            Self::MGZN => "MGZN",
            Self::MPCT => "MPCT",
            Self::MULTI => "MULTI",
            Self::MUSIC => "MUSIC",
            Self::NEWS => "NEWS",
            Self::PAMP => "PAMP",
            Self::PAT => "PAT",
            Self::PCOMM => "PCOMM",
            Self::RPRT => "RPRT",
            Self::SER => "SER",
            Self::SLIDE => "SLIDE",
            Self::SOUND => "SOUND",
            Self::STAND => "STAND",
            Self::STAT => "STAT",
            Self::THES => "THES",
            Self::UNBILL => "UNBILL",
            Self::UNPB => "UNPB",
            Self::VIDEO => "VIDEO",
            Self::Unknown => "GEN",
        }
    }
}

/// A single RIS tag (key-value pair)
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RISTag {
    pub tag: String,
    pub value: String,
}

/// A parsed RIS entry
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RISEntry {
    pub entry_type: RISType,
    pub tags: Vec<RISTag>,
    pub raw_ris: Option<String>,
}

impl RISEntry {
    /// Create a new RIS entry
    pub fn new(entry_type: RISType) -> Self {
        Self {
            entry_type,
            tags: Vec::new(),
            raw_ris: None,
        }
    }

    /// Add a tag to the entry
    pub fn add_tag(&mut self, tag: impl Into<String>, value: impl Into<String>) {
        self.tags.push(RISTag {
            tag: tag.into(),
            value: value.into(),
        });
    }

    /// Get a tag value by key (returns first match)
    pub fn get_tag(&self, tag: &str) -> Option<&str> {
        self.tags
            .iter()
            .find(|t| t.tag.eq_ignore_ascii_case(tag))
            .map(|t| t.value.as_str())
    }

    /// Get all values for a tag (e.g., multiple authors)
    pub fn get_all_tags(&self, tag: &str) -> Vec<&str> {
        self.tags
            .iter()
            .filter(|t| t.tag.eq_ignore_ascii_case(tag))
            .map(|t| t.value.as_str())
            .collect()
    }

    /// Get the title (T1 or TI tag)
    pub fn title(&self) -> Option<&str> {
        self.get_tag("T1").or_else(|| self.get_tag("TI"))
    }

    /// Get all authors (AU or A1 tags)
    pub fn authors(&self) -> Vec<&str> {
        let mut authors = self.get_all_tags("AU");
        if authors.is_empty() {
            authors = self.get_all_tags("A1");
        }
        authors
    }

    /// Get the year (PY or Y1 tag)
    pub fn year(&self) -> Option<&str> {
        self.get_tag("PY").or_else(|| self.get_tag("Y1")).map(|y| {
            // RIS year format is often YYYY/MM/DD or just YYYY
            if let Some(slash_pos) = y.find('/') {
                &y[..slash_pos]
            } else {
                y
            }
        })
    }

    /// Get the DOI
    pub fn doi(&self) -> Option<&str> {
        self.get_tag("DO").or_else(|| self.get_tag("DOI"))
    }

    /// Get the journal (JO, JF, or T2 tag)
    pub fn journal(&self) -> Option<&str> {
        self.get_tag("JO")
            .or_else(|| self.get_tag("JF"))
            .or_else(|| self.get_tag("T2"))
    }

    /// Get the abstract (AB or N2 tag)
    pub fn abstract_text(&self) -> Option<&str> {
        self.get_tag("AB").or_else(|| self.get_tag("N2"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ris_type_parsing() {
        assert_eq!(RISType::from_str("JOUR"), RISType::JOUR);
        assert_eq!(RISType::from_str("jour"), RISType::JOUR);
        assert_eq!(RISType::from_str("BOOK"), RISType::BOOK);
        assert_eq!(RISType::from_str("unknown"), RISType::Unknown);
    }

    #[test]
    fn test_entry_tag_access() {
        let mut entry = RISEntry::new(RISType::JOUR);
        entry.add_tag("TI", "Test Title");
        entry.add_tag("AU", "Smith, John");
        entry.add_tag("AU", "Doe, Jane");
        entry.add_tag("PY", "2024");

        assert_eq!(entry.title(), Some("Test Title"));
        assert_eq!(entry.authors(), vec!["Smith, John", "Doe, Jane"]);
        assert_eq!(entry.year(), Some("2024"));
    }

    #[test]
    fn test_year_parsing() {
        let mut entry = RISEntry::new(RISType::JOUR);
        entry.add_tag("PY", "2024/03/15");

        assert_eq!(entry.year(), Some("2024"));
    }
}
