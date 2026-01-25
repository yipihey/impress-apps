//! PubMed source plugin for biomedical literature
//!
//! API docs: https://www.ncbi.nlm.nih.gov/books/NBK25501/
//! Rate limit: 3 requests/second without API key, 10 with key

use super::traits::{SourceError, SourceMetadata};
use crate::domain::{Author, Identifiers, PdfLink, PdfLinkType, SearchResult, Source};
use quick_xml::events::Event;
use quick_xml::Reader;

pub struct PubMedSource;

impl PubMedSource {
    pub fn metadata() -> SourceMetadata {
        SourceMetadata {
            id: "pubmed",
            name: "PubMed",
            description: "Biomedical literature from MEDLINE and life science journals",
            base_url: "https://pubmed.ncbi.nlm.nih.gov",
            rate_limit_per_second: 3.0,
            supports_bibtex: false,
            supports_ris: true,
            requires_api_key: false, // Optional but recommended
        }
    }

    /// Parse PubMed XML response (efetch format)
    pub fn parse_efetch_response(xml: &str) -> Result<Vec<SearchResult>, SourceError> {
        let mut reader = Reader::from_str(xml);
        reader.trim_text(true);

        let mut results = Vec::new();
        let mut buf = Vec::new();

        let mut in_article = false;
        let mut current_element = String::new();
        let mut pmid = String::new();
        let mut title = String::new();
        let mut abstract_text = String::new();
        let mut journal = String::new();
        let mut volume = String::new();
        let mut pages = String::new();
        let mut year: Option<i32> = None;
        let mut doi: Option<String> = None;
        let mut authors: Vec<Author> = Vec::new();
        let mut current_author_last = String::new();
        let mut current_author_first = String::new();
        let mut in_author = false;

        loop {
            match reader.read_event_into(&mut buf) {
                Ok(Event::Start(ref e)) => {
                    let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                    current_element = name.clone();

                    if name == "PubmedArticle" {
                        in_article = true;
                        pmid.clear();
                        title.clear();
                        abstract_text.clear();
                        journal.clear();
                        volume.clear();
                        pages.clear();
                        year = None;
                        doi = None;
                        authors.clear();
                    } else if name == "Author" {
                        in_author = true;
                        current_author_last.clear();
                        current_author_first.clear();
                    }
                }
                Ok(Event::End(ref e)) => {
                    let name = String::from_utf8_lossy(e.name().as_ref()).to_string();

                    if name == "PubmedArticle" && in_article {
                        if !title.is_empty() {
                            let mut pdf_links = Vec::new();

                            // PubMed Central link if available
                            pdf_links.push(PdfLink {
                                url: format!("https://pubmed.ncbi.nlm.nih.gov/{}/", pmid),
                                link_type: PdfLinkType::Landing,
                                description: Some("PubMed".to_string()),
                            });

                            if let Some(ref d) = doi {
                                pdf_links.push(PdfLink {
                                    url: format!("https://doi.org/{}", d),
                                    link_type: PdfLinkType::Publisher,
                                    description: Some("Publisher".to_string()),
                                });
                            }

                            results.push(SearchResult {
                                source_id: pmid.clone(),
                                source: Source::PubMed,
                                title: title.clone(),
                                authors: authors.clone(),
                                year,
                                identifiers: Identifiers {
                                    pmid: Some(pmid.clone()),
                                    doi: doi.clone(),
                                    ..Default::default()
                                },
                                abstract_text: if abstract_text.is_empty() {
                                    None
                                } else {
                                    Some(abstract_text.clone())
                                },
                                journal: if journal.is_empty() {
                                    None
                                } else {
                                    Some(journal.clone())
                                },
                                volume: if volume.is_empty() {
                                    None
                                } else {
                                    Some(volume.clone())
                                },
                                pages: if pages.is_empty() {
                                    None
                                } else {
                                    Some(pages.clone())
                                },
                                pdf_links,
                                bibtex: None,
                                url: Some(format!("https://pubmed.ncbi.nlm.nih.gov/{}/", pmid)),
                                citation_count: None,
                            });
                        }
                        in_article = false;
                    } else if name == "Author" && in_author {
                        if !current_author_last.is_empty() {
                            authors.push(Author {
                                id: uuid::Uuid::new_v4().to_string(),
                                family_name: current_author_last.clone(),
                                given_name: if current_author_first.is_empty() {
                                    None
                                } else {
                                    Some(current_author_first.clone())
                                },
                                suffix: None,
                                orcid: None,
                                affiliation: None,
                            });
                        }
                        in_author = false;
                    }
                    current_element.clear();
                }
                Ok(Event::Text(e)) => {
                    if in_article {
                        let text = e.unescape().unwrap_or_default().to_string();
                        match current_element.as_str() {
                            "PMID" if pmid.is_empty() => pmid = text,
                            "ArticleTitle" => title = text,
                            "AbstractText" => {
                                if !abstract_text.is_empty() {
                                    abstract_text.push(' ');
                                }
                                abstract_text.push_str(&text);
                            }
                            "Title" if journal.is_empty() => journal = text, // Journal title
                            "Volume" => volume = text,
                            "MedlinePgn" => pages = text,
                            "Year" if year.is_none() => year = text.parse().ok(),
                            "LastName" if in_author => current_author_last = text,
                            "ForeName" if in_author => current_author_first = text,
                            "ArticleId" => {
                                // Check if this is DOI (need to check attribute)
                                if text.starts_with("10.") {
                                    doi = Some(text);
                                }
                            }
                            _ => {}
                        }
                    }
                }
                Ok(Event::Eof) => break,
                Err(e) => return Err(SourceError::Parse(format!("XML parse error: {}", e))),
                _ => {}
            }
            buf.clear();
        }

        Ok(results)
    }

    /// Parse esearch response to get PMIDs
    pub fn parse_esearch_response(xml: &str) -> Result<Vec<String>, SourceError> {
        let mut reader = Reader::from_str(xml);
        reader.trim_text(true);

        let mut pmids = Vec::new();
        let mut buf = Vec::new();
        let mut in_id = false;

        loop {
            match reader.read_event_into(&mut buf) {
                Ok(Event::Start(ref e)) => {
                    if e.name().as_ref() == b"Id" {
                        in_id = true;
                    }
                }
                Ok(Event::End(ref e)) => {
                    if e.name().as_ref() == b"Id" {
                        in_id = false;
                    }
                }
                Ok(Event::Text(e)) if in_id => {
                    let text = e.unescape().unwrap_or_default().to_string();
                    pmids.push(text);
                }
                Ok(Event::Eof) => break,
                Err(e) => return Err(SourceError::Parse(format!("XML parse error: {}", e))),
                _ => {}
            }
            buf.clear();
        }

        Ok(pmids)
    }
}

/// Parse PubMed efetch XML response (exported for FFI)
#[uniffi::export]
pub fn parse_pubmed_efetch_response(
    xml: String,
) -> Result<Vec<SearchResult>, crate::error::FfiError> {
    PubMedSource::parse_efetch_response(&xml).map_err(|e| crate::error::FfiError::ParseError {
        message: format!("{:?}", e),
    })
}

/// Parse PubMed esearch XML response to get PMIDs (exported for FFI)
#[uniffi::export]
pub fn parse_pubmed_esearch_response(xml: String) -> Result<Vec<String>, crate::error::FfiError> {
    PubMedSource::parse_esearch_response(&xml).map_err(|e| crate::error::FfiError::ParseError {
        message: format!("{:?}", e),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_EFETCH: &str = r#"<?xml version="1.0"?>
<!DOCTYPE PubmedArticleSet PUBLIC "-//NLM//DTD PubMedArticle, 1st January 2024//EN" "https://dtd.nlm.nih.gov/ncbi/pubmed/out/pubmed_240101.dtd">
<PubmedArticleSet>
  <PubmedArticle>
    <MedlineCitation>
      <PMID>12345678</PMID>
      <Article>
        <Journal>
          <Title>Test Journal</Title>
          <JournalIssue>
            <Volume>10</Volume>
            <PubDate><Year>2023</Year></PubDate>
          </JournalIssue>
        </Journal>
        <ArticleTitle>A Test Article About Medicine</ArticleTitle>
        <Abstract>
          <AbstractText>This is the abstract.</AbstractText>
        </Abstract>
        <AuthorList>
          <Author>
            <LastName>Smith</LastName>
            <ForeName>John</ForeName>
          </Author>
        </AuthorList>
      </Article>
    </MedlineCitation>
  </PubmedArticle>
</PubmedArticleSet>"#;

    #[test]
    fn test_parse_efetch_response() {
        let results = PubMedSource::parse_efetch_response(SAMPLE_EFETCH).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "A Test Article About Medicine");
        assert_eq!(results[0].source_id, "12345678");
        assert_eq!(results[0].year, Some(2023));
    }

    const SAMPLE_ESEARCH: &str = r#"<?xml version="1.0"?>
<eSearchResult>
  <IdList>
    <Id>12345678</Id>
    <Id>87654321</Id>
  </IdList>
</eSearchResult>"#;

    #[test]
    fn test_parse_esearch_response() {
        let pmids = PubMedSource::parse_esearch_response(SAMPLE_ESEARCH).unwrap();
        assert_eq!(pmids.len(), 2);
        assert_eq!(pmids[0], "12345678");
        assert_eq!(pmids[1], "87654321");
    }
}
