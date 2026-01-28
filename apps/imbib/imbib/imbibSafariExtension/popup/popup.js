// popup.js - Safari extension popup controller with citation search

// HTTP API Configuration
const API_BASE = 'http://127.0.0.1:23120';
const SEARCH_DEBOUNCE_MS = 300;

class PopupController {
    constructor() {
        // Import mode elements
        this.states = {
            loading: document.getElementById('loading'),
            noContent: document.getElementById('no-content'),
            searchPage: document.getElementById('search-page'),
            itemFound: document.getElementById('item-found'),
            success: document.getElementById('success'),
            error: document.getElementById('error')
        };

        this.elements = {
            title: document.getElementById('item-title'),
            authors: document.getElementById('item-authors'),
            meta: document.getElementById('item-meta'),
            identifiers: document.getElementById('identifiers'),
            alreadySaved: document.getElementById('already-saved'),
            librarySelect: document.getElementById('library-select'),
            importBtn: document.getElementById('import-btn'),
            errorMessage: document.getElementById('error-message'),
            retryBtn: document.getElementById('retry-btn'),
            searchPageMessage: document.getElementById('search-page-message'),
            // Smart search elements
            smartSearchSection: document.getElementById('smart-search-section'),
            searchQueryText: document.getElementById('search-query-text'),
            createSmartSearchBtn: document.getElementById('create-smart-search-btn'),
            searchPageHint: document.getElementById('search-page-hint')
        };

        // Mode elements
        this.modeElements = {
            importMode: document.getElementById('import-mode'),
            searchMode: document.getElementById('search-mode'),
            tabImport: document.getElementById('tab-import'),
            tabSearch: document.getElementById('tab-search')
        };

        // Search mode elements
        this.searchElements = {
            input: document.getElementById('citation-search-input'),
            clearBtn: document.getElementById('clear-search-btn'),
            serverStatus: document.getElementById('server-status'),
            serverStatusText: document.getElementById('server-status-text'),
            searchTips: document.getElementById('search-tips'),
            searchLoading: document.getElementById('search-loading'),
            resultsList: document.getElementById('results-list'),
            noResults: document.getElementById('no-results'),
            copyOptions: document.getElementById('copy-options'),
            selectedTitle: document.getElementById('selected-title'),
            deselectBtn: document.getElementById('deselect-btn'),
            copyCitekeyBtn: document.getElementById('copy-citekey-btn'),
            copyBibtexBtn: document.getElementById('copy-bibtex-btn')
        };

        this.currentMetadata = null;
        this.currentSearchQuery = null;
        this.currentMode = 'import';
        this.selectedPaper = null;
        this.searchTimeout = null;
        this.httpServerAvailable = false;

        this.init();
    }

    async init() {
        // Set up mode tab listeners
        this.modeElements.tabImport.addEventListener('click', () => this.switchMode('import'));
        this.modeElements.tabSearch.addEventListener('click', () => this.switchMode('search'));

        // Set up import mode listeners
        this.elements.importBtn.addEventListener('click', () => this.handleImport());
        this.elements.retryBtn.addEventListener('click', () => this.initImportMode());
        this.elements.createSmartSearchBtn?.addEventListener('click', () => this.handleCreateSmartSearch());

        // Set up search mode listeners
        this.searchElements.input.addEventListener('input', (e) => this.handleSearchInput(e));
        this.searchElements.clearBtn.addEventListener('click', () => this.clearSearch());
        this.searchElements.deselectBtn.addEventListener('click', () => this.deselectPaper());
        this.searchElements.copyCitekeyBtn.addEventListener('click', () => this.copyCiteKey());
        this.searchElements.copyBibtexBtn.addEventListener('click', () => this.copyBibTeX());

        // Initialize import mode by default
        await this.initImportMode();

        // Pre-check HTTP server status for search mode
        this.checkHTTPServer();
    }

    // ============ MODE SWITCHING ============

    switchMode(mode) {
        this.currentMode = mode;

        // Update tabs
        this.modeElements.tabImport.classList.toggle('active', mode === 'import');
        this.modeElements.tabSearch.classList.toggle('active', mode === 'search');

        // Update content visibility
        this.modeElements.importMode.classList.toggle('hidden', mode !== 'import');
        this.modeElements.searchMode.classList.toggle('hidden', mode !== 'search');

        // Focus search input when switching to search mode
        if (mode === 'search') {
            setTimeout(() => this.searchElements.input.focus(), 100);
            this.updateServerStatus();
        }
    }

    // ============ IMPORT MODE ============

    async initImportMode() {
        this.showState('loading');

        try {
            // Get current tab
            const [tab] = await browser.tabs.query({ active: true, currentWindow: true });

            if (!tab) {
                this.showError('Could not access current tab');
                return;
            }

            // Request metadata from content script
            const response = await browser.tabs.sendMessage(tab.id, { action: 'extract' });

            if (!response || response.error) {
                this.showState('noContent');
                return;
            }

            const { metadata } = response;

            if (!metadata) {
                this.showState('noContent');
                return;
            }

            // Handle redirect requests (e.g., arXiv PDF page)
            if (metadata.redirect) {
                this.showError(`Please visit the abstract page:\n${metadata.redirect}`);
                return;
            }

            // Handle search/listing pages
            if (metadata.isSearchPage) {
                this.showSearchPageMessage(metadata.message || 'Click on a paper to import it.', metadata.searchQuery);
                return;
            }

            this.currentMetadata = metadata;
            await this.displayItem(metadata);

        } catch (error) {
            console.error('Popup error:', error);

            // Check if content script is not loaded
            if (error.message?.includes('Receiving end does not exist')) {
                this.showState('noContent');
            } else {
                this.showError(error.message || 'Failed to extract metadata');
            }
        }
    }

    async displayItem(metadata) {
        // Title
        this.elements.title.textContent = metadata.title || 'Untitled';

        // Authors
        if (metadata.authors && metadata.authors.length > 0) {
            const authorText = metadata.authors.length > 3
                ? `${metadata.authors.slice(0, 3).join(', ')} et al.`
                : metadata.authors.join(', ');
            this.elements.authors.textContent = authorText;
        } else {
            this.elements.authors.textContent = '';
        }

        // Meta (journal + year)
        const metaParts = [];
        if (metadata.journal) metaParts.push(metadata.journal);
        if (metadata.year) metaParts.push(metadata.year);
        this.elements.meta.textContent = metaParts.join(' \u2022 ');

        // Identifiers
        this.elements.identifiers.innerHTML = '';
        this.addIdentifierTag('DOI', metadata.doi);
        this.addIdentifierTag('arXiv', metadata.arxivID);
        this.addIdentifierTag('ADS', metadata.bibcode);
        this.addIdentifierTag('PMID', metadata.pmid);

        // Check for duplicate
        const exists = await this.checkDuplicate(metadata);
        if (exists) {
            this.elements.alreadySaved.classList.remove('hidden');
        } else {
            this.elements.alreadySaved.classList.add('hidden');
        }

        // Load libraries
        await this.loadLibraries();

        this.showState('itemFound');
    }

    addIdentifierTag(label, value) {
        if (!value) return;

        const tag = document.createElement('span');
        tag.className = 'identifier-tag';
        tag.innerHTML = `<span class="label">${label}:</span>${this.truncate(value, 20)}`;
        this.elements.identifiers.appendChild(tag);
    }

    truncate(str, maxLength) {
        if (!str) return '';
        return str.length > maxLength ? str.substring(0, maxLength) + '...' : str;
    }

    async loadLibraries() {
        try {
            const response = await browser.runtime.sendNativeMessage(
                'com.imbib.app.safari-extension',
                { action: 'getLibraries' }
            );

            const libraries = response?.libraries || [];

            // Clear existing options except default
            this.elements.librarySelect.innerHTML = '<option value="">Default library</option>';

            libraries.forEach(lib => {
                const option = document.createElement('option');
                option.value = lib.id;
                option.textContent = lib.name;
                this.elements.librarySelect.appendChild(option);
            });
        } catch (error) {
            console.warn('Failed to load libraries:', error);
            // Continue without library selection
        }
    }

    async checkDuplicate(metadata) {
        try {
            const response = await browser.runtime.sendNativeMessage(
                'com.imbib.app.safari-extension',
                {
                    action: 'checkDuplicate',
                    doi: metadata.doi,
                    arxivID: metadata.arxivID,
                    bibcode: metadata.bibcode
                }
            );
            return response?.exists || false;
        } catch (error) {
            console.warn('Failed to check duplicate:', error);
            return false;
        }
    }

    async handleImport() {
        if (!this.currentMetadata) return;

        // Update UI
        this.elements.importBtn.disabled = true;
        this.elements.importBtn.querySelector('.button-text').textContent = 'Importing...';
        this.elements.importBtn.querySelector('.button-spinner').classList.remove('hidden');

        try {
            const libraryId = this.elements.librarySelect.value;

            const response = await browser.runtime.sendNativeMessage(
                'com.imbib.app.safari-extension',
                {
                    action: 'importItem',
                    item: {
                        ...this.currentMetadata,
                        libraryId: libraryId || null,
                        importedAt: new Date().toISOString()
                    }
                }
            );

            if (response?.success) {
                this.showState('success');
                // Auto-close after success
                setTimeout(() => window.close(), 1500);
            } else {
                throw new Error(response?.error || 'Import failed');
            }
        } catch (error) {
            console.error('Import error:', error);
            this.showError(error.message || 'Failed to import reference');

            // Reset button
            this.elements.importBtn.disabled = false;
            this.elements.importBtn.querySelector('.button-text').textContent = 'Import';
            this.elements.importBtn.querySelector('.button-spinner').classList.add('hidden');
        }
    }

    showState(stateName) {
        Object.entries(this.states).forEach(([name, el]) => {
            if (name === stateName) {
                el.classList.remove('hidden');
            } else {
                el.classList.add('hidden');
            }
        });
    }

    showError(message) {
        this.elements.errorMessage.textContent = message;
        this.showState('error');
    }

    showSearchPageMessage(message, searchQuery = null) {
        if (this.elements.searchPageMessage) {
            this.elements.searchPageMessage.textContent = message;
        }

        // Show smart search section if we have a query
        if (searchQuery && this.elements.smartSearchSection) {
            this.currentSearchQuery = searchQuery;
            this.elements.searchQueryText.textContent = searchQuery.length > 60
                ? searchQuery.substring(0, 60) + '...'
                : searchQuery;
            this.elements.smartSearchSection.classList.remove('hidden');
            this.elements.searchPageHint?.classList.add('hidden');
        } else {
            this.currentSearchQuery = null;
            this.elements.smartSearchSection?.classList.add('hidden');
            this.elements.searchPageHint?.classList.remove('hidden');
        }

        this.showState('searchPage');
    }

    async handleCreateSmartSearch() {
        if (!this.currentSearchQuery) return;

        // Update UI
        const btn = this.elements.createSmartSearchBtn;
        btn.disabled = true;
        btn.querySelector('.button-text').textContent = 'Creating...';
        btn.querySelector('.button-spinner').classList.remove('hidden');

        try {
            // Generate a name from the query
            const truncatedQuery = this.currentSearchQuery.length > 40
                ? this.currentSearchQuery.substring(0, 40) + '...'
                : this.currentSearchQuery;
            const name = `Search: ${truncatedQuery}`;

            const response = await browser.runtime.sendNativeMessage(
                'com.imbib.app.safari-extension',
                {
                    action: 'createSmartSearch',
                    query: this.currentSearchQuery,
                    name: name,
                    sourceID: 'ads'
                }
            );

            if (response?.success) {
                this.showState('success');
                // Auto-close after success
                setTimeout(() => window.close(), 1500);
            } else {
                throw new Error(response?.error || 'Failed to create smart search');
            }
        } catch (error) {
            console.error('Smart search creation error:', error);
            this.showError(error.message || 'Failed to create smart search');

            // Reset button
            btn.disabled = false;
            btn.querySelector('.button-text').textContent = 'Create Smart Search';
            btn.querySelector('.button-spinner').classList.add('hidden');
        }
    }

    // ============ SEARCH MODE (Citation Picker) ============

    async checkHTTPServer() {
        try {
            const response = await fetch(`${API_BASE}/api/status`, {
                method: 'GET',
                headers: { 'Accept': 'application/json' }
            });

            if (response.ok) {
                const data = await response.json();
                this.httpServerAvailable = data.status === 'ok';
            } else {
                this.httpServerAvailable = false;
            }
        } catch (error) {
            console.log('HTTP server not available:', error.message);
            this.httpServerAvailable = false;
        }

        this.updateServerStatus();
    }

    updateServerStatus() {
        if (this.currentMode !== 'search') return;

        if (this.httpServerAvailable) {
            this.searchElements.serverStatus.classList.add('hidden');
        } else {
            this.searchElements.serverStatus.classList.remove('hidden');
            this.searchElements.serverStatusText.textContent =
                'HTTP server not running. Enable it in imbib Settings > Automation.';
        }
    }

    handleSearchInput(event) {
        const query = event.target.value.trim();

        // Show/hide clear button
        this.searchElements.clearBtn.classList.toggle('hidden', query.length === 0);

        // Debounce search
        clearTimeout(this.searchTimeout);

        if (query.length === 0) {
            this.showSearchTips();
            return;
        }

        if (query.length < 2) {
            return;
        }

        this.searchTimeout = setTimeout(() => this.performSearch(query), SEARCH_DEBOUNCE_MS);
    }

    clearSearch() {
        this.searchElements.input.value = '';
        this.searchElements.clearBtn.classList.add('hidden');
        this.showSearchTips();
        this.searchElements.input.focus();
    }

    showSearchTips() {
        this.searchElements.searchTips.classList.remove('hidden');
        this.searchElements.searchLoading.classList.add('hidden');
        this.searchElements.resultsList.classList.add('hidden');
        this.searchElements.noResults.classList.add('hidden');
        this.deselectPaper();
    }

    async performSearch(query) {
        // Check server availability first
        if (!this.httpServerAvailable) {
            await this.checkHTTPServer();
            if (!this.httpServerAvailable) {
                return;
            }
        }

        // Show loading
        this.searchElements.searchTips.classList.add('hidden');
        this.searchElements.searchLoading.classList.remove('hidden');
        this.searchElements.resultsList.classList.add('hidden');
        this.searchElements.noResults.classList.add('hidden');

        try {
            const response = await fetch(
                `${API_BASE}/api/search?q=${encodeURIComponent(query)}&limit=20`,
                {
                    method: 'GET',
                    headers: { 'Accept': 'application/json' }
                }
            );

            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }

            const data = await response.json();

            this.searchElements.searchLoading.classList.add('hidden');

            if (data.papers && data.papers.length > 0) {
                this.displaySearchResults(data.papers);
            } else {
                this.searchElements.noResults.classList.remove('hidden');
            }

        } catch (error) {
            console.error('Search error:', error);
            this.searchElements.searchLoading.classList.add('hidden');
            this.httpServerAvailable = false;
            this.updateServerStatus();
        }
    }

    displaySearchResults(papers) {
        this.searchElements.resultsList.innerHTML = '';
        this.searchElements.resultsList.classList.remove('hidden');

        papers.forEach(paper => {
            const item = document.createElement('div');
            item.className = 'result-item';
            item.dataset.citekey = paper.citeKey;
            item.dataset.bibtex = paper.bibtex || '';
            item.dataset.title = paper.title;

            // Build authors string
            const authors = paper.authors || [];
            const authorText = authors.length > 2
                ? `${authors[0]}, et al.`
                : authors.join(', ');

            item.innerHTML = `
                <div class="result-title">${this.escapeHtml(paper.title)}</div>
                <div class="result-meta">
                    <span class="result-citekey">${this.escapeHtml(paper.citeKey)}</span>
                    ${paper.year ? `<span class="result-year">${paper.year}</span>` : ''}
                    <span class="result-authors">${this.escapeHtml(authorText)}</span>
                </div>
            `;

            item.addEventListener('click', () => this.selectPaper(paper));
            this.searchElements.resultsList.appendChild(item);
        });
    }

    selectPaper(paper) {
        this.selectedPaper = paper;

        // Highlight selected item
        const items = this.searchElements.resultsList.querySelectorAll('.result-item');
        items.forEach(item => {
            item.classList.toggle('selected', item.dataset.citekey === paper.citeKey);
        });

        // Show copy options
        this.searchElements.selectedTitle.textContent = this.truncate(paper.title, 40);
        this.searchElements.copyOptions.classList.remove('hidden');
    }

    deselectPaper() {
        this.selectedPaper = null;

        // Remove highlight
        const items = this.searchElements.resultsList.querySelectorAll('.result-item');
        items.forEach(item => item.classList.remove('selected'));

        // Hide copy options
        this.searchElements.copyOptions.classList.add('hidden');
    }

    async copyCiteKey() {
        if (!this.selectedPaper) return;

        const citeCommand = `\\cite{${this.selectedPaper.citeKey}}`;

        try {
            await navigator.clipboard.writeText(citeCommand);
            this.showCopiedFeedback(this.searchElements.copyCitekeyBtn);
        } catch (error) {
            console.error('Copy failed:', error);
        }
    }

    async copyBibTeX() {
        if (!this.selectedPaper) return;

        const bibtex = this.selectedPaper.bibtex;

        if (!bibtex) {
            // Fetch BibTeX from server if not available
            try {
                const response = await fetch(
                    `${API_BASE}/api/papers/${encodeURIComponent(this.selectedPaper.citeKey)}`,
                    {
                        method: 'GET',
                        headers: { 'Accept': 'application/json' }
                    }
                );

                if (response.ok) {
                    const data = await response.json();
                    if (data.paper?.bibtex) {
                        await navigator.clipboard.writeText(data.paper.bibtex);
                        this.showCopiedFeedback(this.searchElements.copyBibtexBtn);
                    }
                }
            } catch (error) {
                console.error('Failed to fetch BibTeX:', error);
            }
            return;
        }

        try {
            await navigator.clipboard.writeText(bibtex);
            this.showCopiedFeedback(this.searchElements.copyBibtexBtn);
        } catch (error) {
            console.error('Copy failed:', error);
        }
    }

    showCopiedFeedback(button) {
        const originalText = button.querySelector('span').textContent;
        button.classList.add('copied');
        button.querySelector('span').textContent = 'Copied!';

        setTimeout(() => {
            button.classList.remove('copied');
            button.querySelector('span').textContent = originalText;
        }, 1500);
    }

    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
}

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    new PopupController();
});
