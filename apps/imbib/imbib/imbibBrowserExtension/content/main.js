// main.js - Content script orchestrator
// Detects page type and extracts bibliographic metadata

(function() {
    'use strict';

    // Page type constants
    const PageType = {
        ADS: 'ads',
        ARXIV: 'arxiv',
        DOI: 'doi',
        PUBMED: 'pubmed',
        OPENALEX: 'openalex',
        GENERIC: 'generic'
    };

    // Detect which type of academic page this is
    function detectPageType() {
        const hostname = window.location.hostname;

        if (hostname.includes('adsabs.harvard.edu')) return PageType.ADS;
        if (hostname.includes('arxiv.org')) return PageType.ARXIV;
        if (hostname === 'doi.org' || hostname === 'dx.doi.org') return PageType.DOI;
        if (hostname.includes('pubmed.ncbi.nlm.nih.gov') ||
            hostname.includes('ncbi.nlm.nih.gov/pmc')) return PageType.PUBMED;
        if (hostname.includes('openalex.org')) return PageType.OPENALEX;

        return PageType.GENERIC;
    }

    // Main extraction function
    async function extractMetadata() {
        const pageType = detectPageType();
        let metadata = null;

        try {
            switch (pageType) {
                case PageType.ADS:
                    metadata = extractADS();
                    break;
                case PageType.ARXIV:
                    metadata = extractArXiv();
                    break;
                case PageType.DOI:
                    metadata = extractDOI();
                    break;
                case PageType.PUBMED:
                    metadata = extractPubMed();
                    break;
                case PageType.OPENALEX:
                    metadata = extractOpenAlex();
                    break;
                default:
                    metadata = extractEmbedded();
            }
        } catch (error) {
            console.error('imbib: Error extracting metadata:', error);
            metadata = null;
        }

        return {
            pageType,
            metadata,
            url: window.location.href,
            timestamp: Date.now()
        };
    }

    // ==================== ADS Scraper ====================

    function extractADS() {
        const url = window.location.href;

        // Detect search results page - extract query for smart search creation
        if (url.includes('/search/') || url.includes('/search?')) {
            const searchQuery = extractADSSearchQuery(url);
            return {
                sourceType: 'ads',
                isSearchPage: true,
                searchQuery: searchQuery,
                searchURL: url,
                message: searchQuery
                    ? `Search: ${searchQuery.length > 50 ? searchQuery.substring(0, 50) + '...' : searchQuery}`
                    : 'This is a search results page. Click on a paper to import it.'
            };
        }

        // Extract bibcode from URL: /abs/{bibcode}/abstract
        const bibcodeMatch = url.match(/\/abs\/([^\/]+)/);
        if (!bibcodeMatch) return null;

        const bibcode = decodeURIComponent(bibcodeMatch[1]);

        const metadata = {
            bibcode: bibcode,
            sourceType: 'ads',
            title: getMetaContent('citation_title') ||
                   document.querySelector('h2.s-abstract-title')?.textContent?.trim(),
            authors: getMetaContentAll('citation_author'),
            year: getMetaContent('citation_publication_date')?.substring(0, 4),
            journal: getMetaContent('citation_journal_title'),
            volume: getMetaContent('citation_volume'),
            pages: getMetaContent('citation_firstpage'),
            doi: getMetaContent('citation_doi'),
            abstract: document.querySelector('div.s-abstract-text')?.textContent?.trim()
                     ?.replace(/^Abstract\s*/i, ''),
            arxivID: extractArXivIDFromADSPage(),
            pdfURL: getMetaContent('citation_pdf_url')
        };

        // Fallback author extraction from DOM
        if (!metadata.authors || metadata.authors.length === 0) {
            const authorElements = document.querySelectorAll('ul.s-authors-and-aff a');
            metadata.authors = Array.from(authorElements)
                .map(el => el.textContent.trim())
                .filter(name => name.length > 0);
        }

        return metadata;
    }

    function extractArXivIDFromADSPage() {
        // Look for arXiv ID in identifiers section
        const identLinks = document.querySelectorAll('a[href*="arxiv.org"]');
        for (const link of identLinks) {
            const match = link.href.match(/arxiv\.org\/abs\/([^\/?]+)/);
            if (match) return match[1];
        }

        // Also check meta tags
        const arxivMeta = getMetaContent('citation_arxiv_id');
        if (arxivMeta) return arxivMeta;

        return null;
    }

    // Extract search query from ADS search URL
    // Handles both traditional (?q=) and path-based (/search/q=) formats
    function extractADSSearchQuery(url) {
        try {
            const urlObj = new URL(url);

            // Traditional format: /search?q=...
            let query = urlObj.searchParams.get('q');

            // Path-based format: /search/q=...&sort=...
            if (!query && urlObj.pathname.startsWith('/search/')) {
                const pathQuery = urlObj.pathname.substring('/search/'.length);
                // Parse path as query params
                const pathParams = new URLSearchParams(pathQuery);
                query = pathParams.get('q');
            }

            if (!query) return null;

            // Decode and clean up the query
            query = decodeURIComponent(query).trim();

            // Skip docs() selection queries - those are temporary and shouldn't be saved
            if (query.startsWith('docs(')) return null;

            return query;
        } catch (e) {
            console.error('imbib: Error parsing ADS search URL:', e);
            return null;
        }
    }

    // ==================== arXiv Scraper ====================

    function extractArXiv() {
        const url = window.location.href;

        // Handle PDF URLs - signal redirect needed
        if (url.includes('/pdf/')) {
            const absURL = url.replace('/pdf/', '/abs/').replace('.pdf', '');
            return { redirect: absURL, sourceType: 'arxiv' };
        }

        // Detect search/list pages
        if (url.includes('/search/') || url.includes('/search?') ||
            url.includes('/list/') || url.includes('/new/') ||
            url.includes('/recent/')) {
            return {
                sourceType: 'arxiv',
                isSearchPage: true,
                message: 'This is a listing page. Click on a paper to import it.'
            };
        }

        // Extract arXiv ID from URL: /abs/{id}
        const idMatch = url.match(/arxiv\.org\/abs\/([^\/?]+)/);
        if (!idMatch) return null;

        const arxivID = idMatch[1];

        const metadata = {
            arxivID: arxivID,
            sourceType: 'arxiv',
            title: getMetaContent('citation_title') ||
                   document.querySelector('h1.title')?.textContent?.replace(/^Title:\s*/i, '').trim(),
            authors: getMetaContentAll('citation_author'),
            year: getMetaContent('citation_date')?.substring(0, 4) ||
                  getMetaContent('citation_online_date')?.substring(0, 4),
            abstract: document.querySelector('blockquote.abstract')?.textContent
                     ?.replace(/^Abstract:\s*/i, '').trim(),
            doi: getMetaContent('citation_doi'),
            categories: extractArXivCategories(),
            pdfURL: `https://arxiv.org/pdf/${arxivID}.pdf`
        };

        // Fallback author extraction
        if (!metadata.authors || metadata.authors.length === 0) {
            const authorDiv = document.querySelector('div.authors');
            if (authorDiv) {
                metadata.authors = Array.from(authorDiv.querySelectorAll('a'))
                    .map(a => a.textContent.trim())
                    .filter(name => name.length > 0);
            }
        }

        return metadata;
    }

    function extractArXivCategories() {
        const categories = [];

        // Primary subject
        const primary = document.querySelector('span.primary-subject');
        if (primary) {
            const match = primary.textContent.match(/\(([^)]+)\)/);
            if (match) categories.push(match[1]);
        }

        // All subjects from meta
        const subjectMeta = getMetaContent('citation_arxiv_primary_subject');
        if (subjectMeta && !categories.includes(subjectMeta)) {
            categories.push(subjectMeta);
        }

        return categories;
    }

    // ==================== DOI Scraper ====================

    function extractDOI() {
        const url = window.location.href;

        // Extract DOI from URL: doi.org/{doi}
        const doiMatch = url.match(/(?:dx\.)?doi\.org\/(.+)$/);
        if (!doiMatch) return null;

        const doi = decodeURIComponent(doiMatch[1]);

        // DOI resolver pages often redirect - return DOI for API lookup
        return {
            doi: doi,
            sourceType: 'doi',
            needsEnrichment: true  // Signal native app to fetch via CrossRef
        };
    }

    // ==================== PubMed Scraper ====================

    function extractPubMed() {
        const url = window.location.href;

        // Extract PMID from URL
        const pmidMatch = url.match(/pubmed\.ncbi\.nlm\.nih\.gov\/(\d+)/);
        const pmcidMatch = url.match(/ncbi\.nlm\.nih\.gov\/pmc\/articles\/(PMC\d+)/);

        const pmid = pmidMatch ? pmidMatch[1] : null;
        const pmcid = pmcidMatch ? pmcidMatch[1] : null;

        if (!pmid && !pmcid) return null;

        const metadata = {
            pmid: pmid,
            pmcid: pmcid,
            sourceType: 'pubmed',
            title: getMetaContent('citation_title') ||
                   document.querySelector('h1.heading-title')?.textContent?.trim(),
            authors: getMetaContentAll('citation_author'),
            year: getMetaContent('citation_publication_date')?.substring(0, 4),
            journal: getMetaContent('citation_journal_title'),
            volume: getMetaContent('citation_volume'),
            pages: getMetaContent('citation_firstpage'),
            doi: getMetaContent('citation_doi'),
            abstract: document.querySelector('div.abstract-content')?.textContent?.trim(),
            pdfURL: getMetaContent('citation_pdf_url')
        };

        // Fallback author extraction
        if (!metadata.authors || metadata.authors.length === 0) {
            const authorElements = document.querySelectorAll('.authors-list .author-name');
            metadata.authors = Array.from(authorElements)
                .map(el => el.textContent.trim())
                .filter(name => name.length > 0);
        }

        return metadata;
    }

    // ==================== OpenAlex Scraper ====================

    function extractOpenAlex() {
        const url = window.location.href;

        // Detect search results page
        if (url.includes('/works?') && !url.includes('/works/W')) {
            return {
                sourceType: 'openalex',
                isSearchPage: true,
                searchURL: url,
                message: 'This is a search results page. Click on a work to import it.'
            };
        }

        // Extract OpenAlex ID from URL: /works/W1234567890
        const workMatch = url.match(/\/works\/(W\d+)/);
        if (!workMatch) return null;

        const openAlexID = workMatch[1];

        // OpenAlex work pages have structured data we can extract
        const metadata = {
            openAlexID: openAlexID,
            sourceType: 'openalex',
            title: getMetaContent('citation_title') ||
                   getMetaContent('og:title') ||
                   document.querySelector('h1')?.textContent?.trim(),
            authors: getMetaContentAll('citation_author'),
            year: getMetaContent('citation_publication_date')?.substring(0, 4),
            journal: getMetaContent('citation_journal_title'),
            doi: getMetaContent('citation_doi'),
            abstract: getMetaContent('description') ||
                      getMetaContent('og:description')
        };

        // Try to extract from page content if meta tags are missing
        // OpenAlex work pages have structured JSON-LD data
        const jsonLd = extractSchemaOrg();
        if (jsonLd) {
            metadata.title = metadata.title || jsonLd.name || jsonLd.headline;
            metadata.doi = metadata.doi || extractDOIFromJsonLd(jsonLd);
            if (!metadata.authors || metadata.authors.length === 0) {
                metadata.authors = extractAuthorsFromJsonLd(jsonLd);
            }
            if (jsonLd.datePublished) {
                metadata.year = metadata.year || jsonLd.datePublished.substring(0, 4);
            }
        }

        // If still no title, return null (not a valid work page)
        if (!metadata.title) return null;

        return metadata;
    }

    // ==================== Generic Embedded Metadata Scraper ====================

    function extractEmbedded() {
        const metadata = {
            sourceType: 'embedded',
            title: null,
            authors: [],
            year: null,
            journal: null,
            volume: null,
            pages: null,
            doi: null,
            abstract: null,
            pdfURL: null
        };

        // 1. Highwire Press (Google Scholar standard) - highest priority
        metadata.title = getMetaContent('citation_title');
        metadata.authors = getMetaContentAll('citation_author');
        metadata.year = getMetaContent('citation_publication_date')?.substring(0, 4) ||
                       getMetaContent('citation_year');
        metadata.journal = getMetaContent('citation_journal_title');
        metadata.volume = getMetaContent('citation_volume');
        metadata.pages = getMetaContent('citation_firstpage');
        metadata.doi = getMetaContent('citation_doi');
        metadata.pdfURL = getMetaContent('citation_pdf_url');
        metadata.abstract = getMetaContent('citation_abstract');

        // 2. Dublin Core fallback
        metadata.title = metadata.title || getMetaContent('DC.title');
        if (!metadata.authors || metadata.authors.length === 0) {
            metadata.authors = getMetaContentAll('DC.creator');
        }
        metadata.doi = metadata.doi || extractDOIFromContent(getMetaContent('DC.identifier'));

        // 3. PRISM (publishing metadata)
        metadata.doi = metadata.doi || getMetaContent('prism.doi');
        metadata.journal = metadata.journal || getMetaContent('prism.publicationName');
        metadata.volume = metadata.volume || getMetaContent('prism.volume');

        // 4. OpenGraph (limited but common)
        metadata.title = metadata.title || getMetaContent('og:title', 'property');

        // 5. Schema.org JSON-LD
        const jsonLd = extractSchemaOrg();
        if (jsonLd) {
            metadata.title = metadata.title || jsonLd.headline || jsonLd.name;
            if (!metadata.authors || metadata.authors.length === 0) {
                metadata.authors = extractAuthorsFromJsonLd(jsonLd);
            }
            metadata.doi = metadata.doi || extractDOIFromJsonLd(jsonLd);
            metadata.abstract = metadata.abstract || jsonLd.description;
        }

        // 6. COinS (OpenURL in spans)
        const coins = extractCOinS();
        if (coins) {
            metadata.title = metadata.title || coins['rft.atitle'] || coins['rft.title'];
            metadata.doi = metadata.doi || extractDOIFromContent(coins['rft.id'] || coins['rft_id']);
            metadata.journal = metadata.journal || coins['rft.jtitle'];
            metadata.volume = metadata.volume || coins['rft.volume'];
            metadata.pages = metadata.pages || coins['rft.spage'];
            if (!metadata.authors || metadata.authors.length === 0) {
                const au = coins['rft.au'] || coins['rft.aulast'];
                if (au) metadata.authors = [au];
            }
        }

        // Only return if we found meaningful data
        if (!metadata.title && !metadata.doi) {
            return null;
        }

        return metadata;
    }

    // ==================== Utility Functions ====================

    function getMetaContent(name, attr = 'name') {
        // Try both name and property attributes
        const selectors = [
            `meta[${attr}="${name}"]`,
            `meta[name="${name}"]`,
            `meta[property="${name}"]`
        ];

        for (const selector of selectors) {
            const el = document.querySelector(selector);
            if (el?.content) {
                return el.content.trim();
            }
        }
        return null;
    }

    function getMetaContentAll(name, attr = 'name') {
        const results = [];
        const selectors = [
            `meta[${attr}="${name}"]`,
            `meta[name="${name}"]`
        ];

        for (const selector of selectors) {
            const elements = document.querySelectorAll(selector);
            elements.forEach(el => {
                if (el.content?.trim()) {
                    results.push(el.content.trim());
                }
            });
        }

        return [...new Set(results)]; // Dedupe
    }

    function extractDOIFromContent(content) {
        if (!content) return null;
        const match = content.match(/10\.\d{4,}[^\s]*/);
        return match ? match[0] : null;
    }

    function extractSchemaOrg() {
        const scripts = document.querySelectorAll('script[type="application/ld+json"]');
        for (const script of scripts) {
            try {
                const data = JSON.parse(script.textContent);

                // Handle @graph arrays
                if (data['@graph']) {
                    for (const item of data['@graph']) {
                        if (isScholarlyType(item['@type'])) {
                            return item;
                        }
                    }
                }

                // Direct type check
                if (isScholarlyType(data['@type'])) {
                    return data;
                }
            } catch (e) {
                // Invalid JSON, skip
            }
        }
        return null;
    }

    function isScholarlyType(type) {
        const scholarlyTypes = [
            'ScholarlyArticle', 'Article', 'NewsArticle',
            'TechArticle', 'BlogPosting', 'WebPage'
        ];
        if (Array.isArray(type)) {
            return type.some(t => scholarlyTypes.includes(t));
        }
        return scholarlyTypes.includes(type);
    }

    function extractAuthorsFromJsonLd(jsonLd) {
        if (!jsonLd.author) return [];

        const authors = Array.isArray(jsonLd.author) ? jsonLd.author : [jsonLd.author];
        return authors
            .map(a => {
                if (typeof a === 'string') return a;
                return a.name || a.givenName && a.familyName ?
                       `${a.givenName} ${a.familyName}` : null;
            })
            .filter(Boolean);
    }

    function extractDOIFromJsonLd(jsonLd) {
        // Check identifier array
        if (jsonLd.identifier) {
            const identifiers = Array.isArray(jsonLd.identifier) ?
                               jsonLd.identifier : [jsonLd.identifier];
            for (const id of identifiers) {
                if (id.propertyID === 'doi' && id.value) {
                    return id.value;
                }
                if (typeof id === 'string') {
                    const doi = extractDOIFromContent(id);
                    if (doi) return doi;
                }
            }
        }

        // Check sameAs for DOI URL
        if (jsonLd.sameAs) {
            const urls = Array.isArray(jsonLd.sameAs) ? jsonLd.sameAs : [jsonLd.sameAs];
            for (const url of urls) {
                if (url.includes('doi.org')) {
                    return extractDOIFromContent(url);
                }
            }
        }

        return null;
    }

    function extractCOinS() {
        const span = document.querySelector('span.Z3988');
        if (!span) return null;

        const title = span.getAttribute('title');
        if (!title) return null;

        const params = {};
        try {
            new URLSearchParams(title).forEach((value, key) => {
                params[key] = decodeURIComponent(value);
            });
        } catch (e) {
            // Invalid URL params
        }
        return Object.keys(params).length > 0 ? params : null;
    }

    // ==================== Message Handling ====================

    // Use chrome API (works in Chrome, Edge, and Firefox MV3)
    const runtime = typeof chrome !== 'undefined' ? chrome.runtime : browser.runtime;

    // Listen for messages from popup
    runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (message.action === 'extract') {
            extractMetadata().then(result => {
                sendResponse(result);
            }).catch(error => {
                console.error('imbib: Extraction error:', error);
                sendResponse({ error: error.message });
            });
            return true; // Async response
        }

        if (message.action === 'ping') {
            sendResponse({ success: true });
            return;
        }
    });

    // Notify background script that content script is ready
    runtime.sendMessage({
        action: 'contentReady',
        url: window.location.href
    }).catch(() => {
        // Extension context may not be available
    });

    // ==================== "Add to imbib" Button Injection ====================

    // Determine if this page should have the add button
    function shouldInjectButton() {
        const pageType = detectPageType();
        const url = window.location.href;

        switch (pageType) {
            case PageType.ARXIV:
                // Only on abstract pages, not listing/search pages
                return url.includes('/abs/') && !url.includes('/pdf/');

            case PageType.ADS:
                // Only on individual paper pages, not search results
                return url.includes('/abs/') && !url.includes('/search/');

            case PageType.DOI:
                // DOI landing pages
                return true;

            case PageType.PUBMED:
                // Individual PubMed article pages
                return /pubmed\.ncbi\.nlm\.nih\.gov\/\d+/.test(url);

            default:
                // For generic pages, only show if we can extract meaningful metadata
                // Check for presence of citation tags
                return !!getMetaContent('citation_title') || !!getMetaContent('citation_doi');
        }
    }

    // Create and inject the floating "Add to imbib" button
    function injectAddButton() {
        if (!shouldInjectButton()) return;

        // Don't inject if already present
        if (document.getElementById('imbib-add-button')) return;

        // Create button container
        const button = document.createElement('div');
        button.id = 'imbib-add-button';
        button.setAttribute('role', 'button');
        button.setAttribute('tabindex', '0');
        button.setAttribute('title', 'Add this paper to imbib');

        // Button content with icon
        button.innerHTML = `
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M12 5v14M5 12h14"/>
            </svg>
            <span>imbib</span>
        `;

        // Inject CSS
        injectButtonStyles();

        // Click handler
        button.addEventListener('click', handleAddButtonClick);

        // Keyboard handler (Enter/Space)
        button.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                handleAddButtonClick();
            }
        });

        document.body.appendChild(button);
    }

    // Inject button CSS styles
    function injectButtonStyles() {
        if (document.getElementById('imbib-button-styles')) return;

        const style = document.createElement('style');
        style.id = 'imbib-button-styles';
        style.textContent = `
            #imbib-add-button {
                position: fixed;
                bottom: 24px;
                right: 24px;
                z-index: 999999;
                display: flex;
                align-items: center;
                gap: 6px;
                padding: 10px 16px;
                background: linear-gradient(135deg, #6366f1 0%, #4f46e5 100%);
                color: white;
                border-radius: 24px;
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                font-size: 14px;
                font-weight: 500;
                cursor: pointer;
                box-shadow: 0 4px 12px rgba(99, 102, 241, 0.4),
                            0 2px 4px rgba(0, 0, 0, 0.1);
                transition: all 0.2s ease;
                user-select: none;
            }

            #imbib-add-button:hover {
                transform: translateY(-2px);
                box-shadow: 0 6px 16px rgba(99, 102, 241, 0.5),
                            0 4px 6px rgba(0, 0, 0, 0.15);
            }

            #imbib-add-button:active {
                transform: translateY(0);
                box-shadow: 0 2px 8px rgba(99, 102, 241, 0.3);
            }

            #imbib-add-button.imbib-loading {
                pointer-events: none;
                opacity: 0.8;
            }

            #imbib-add-button.imbib-loading svg {
                animation: imbib-spin 1s linear infinite;
            }

            #imbib-add-button.imbib-success {
                background: linear-gradient(135deg, #10b981 0%, #059669 100%);
            }

            #imbib-add-button.imbib-error {
                background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%);
            }

            @keyframes imbib-spin {
                from { transform: rotate(0deg); }
                to { transform: rotate(360deg); }
            }

            @media (prefers-reduced-motion: reduce) {
                #imbib-add-button {
                    transition: none;
                }
                #imbib-add-button.imbib-loading svg {
                    animation: none;
                }
            }

            @media (max-width: 480px) {
                #imbib-add-button {
                    bottom: 16px;
                    right: 16px;
                    padding: 8px 12px;
                    font-size: 13px;
                }
            }
        `;
        document.head.appendChild(style);
    }

    // Handle button click - extract metadata and send to app
    async function handleAddButtonClick() {
        const button = document.getElementById('imbib-add-button');
        if (!button || button.classList.contains('imbib-loading')) return;

        // Show loading state
        button.classList.add('imbib-loading');
        const originalHTML = button.innerHTML;
        button.innerHTML = `
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <circle cx="12" cy="12" r="10"/>
            </svg>
            <span>Adding...</span>
        `;

        try {
            // Extract metadata
            const result = await extractMetadata();

            if (!result.metadata) {
                throw new Error('Could not extract paper metadata from this page');
            }

            // Send to native app via imbib:// URL scheme
            const importURL = buildImportURL(result);

            // Try to open the URL
            window.location.href = importURL;

            // Show success state briefly
            button.classList.remove('imbib-loading');
            button.classList.add('imbib-success');
            button.innerHTML = `
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M20 6L9 17l-5-5"/>
                </svg>
                <span>Added!</span>
            `;

            // Reset after delay
            setTimeout(() => {
                button.classList.remove('imbib-success');
                button.innerHTML = originalHTML;
            }, 2000);

        } catch (error) {
            console.error('imbib: Add button error:', error);

            // Show error state
            button.classList.remove('imbib-loading');
            button.classList.add('imbib-error');
            button.innerHTML = `
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <circle cx="12" cy="12" r="10"/>
                    <line x1="15" y1="9" x2="9" y2="15"/>
                    <line x1="9" y1="9" x2="15" y2="15"/>
                </svg>
                <span>Error</span>
            `;

            // Reset after delay
            setTimeout(() => {
                button.classList.remove('imbib-error');
                button.innerHTML = originalHTML;
            }, 3000);
        }
    }

    // Build imbib:// URL for import
    function buildImportURL(result) {
        const metadata = result.metadata;

        // Determine the best import method based on metadata
        if (metadata.arxivID) {
            return `imbib://import/arxiv/${encodeURIComponent(metadata.arxivID)}`;
        }

        if (metadata.doi) {
            return `imbib://import/doi/${encodeURIComponent(metadata.doi)}`;
        }

        if (metadata.bibcode) {
            return `imbib://import/ads/${encodeURIComponent(metadata.bibcode)}`;
        }

        if (metadata.pmid) {
            return `imbib://import/pubmed/${encodeURIComponent(metadata.pmid)}`;
        }

        // Fallback: encode metadata as JSON
        const params = new URLSearchParams();

        if (metadata.title) params.set('title', metadata.title);
        if (metadata.authors?.length) params.set('authors', metadata.authors.join('; '));
        if (metadata.year) params.set('year', metadata.year);
        if (metadata.journal) params.set('journal', metadata.journal);
        if (metadata.volume) params.set('volume', metadata.volume);
        if (metadata.pages) params.set('pages', metadata.pages);
        if (metadata.abstract) params.set('abstract', metadata.abstract.substring(0, 500)); // Limit length
        if (metadata.pdfURL) params.set('pdfURL', metadata.pdfURL);
        params.set('sourceURL', result.url);

        return `imbib://import/metadata?${params.toString()}`;
    }

    // Inject button after DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', injectAddButton);
    } else {
        // Small delay to avoid blocking page load
        setTimeout(injectAddButton, 500);
    }

    console.log('imbib content script loaded for:', window.location.hostname);
})();
