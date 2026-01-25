// popup.js - Browser extension popup controller (Chrome/Firefox/Edge)
// Uses URL scheme to communicate with imbib app

class PopupController {
    constructor() {
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

        this.currentMetadata = null;
        this.currentSearchQuery = null;

        this.init();
    }

    async init() {
        this.showState('loading');

        // Set up event listeners
        this.elements.importBtn.addEventListener('click', () => this.handleImport());
        this.elements.retryBtn.addEventListener('click', () => this.init());
        this.elements.createSmartSearchBtn?.addEventListener('click', () => this.handleCreateSmartSearch());

        try {
            // Get current tab - use chrome API for compatibility
            const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
            const tab = tabs[0];

            if (!tab) {
                this.showError('Could not access current tab');
                return;
            }

            // Request metadata from content script
            const response = await chrome.tabs.sendMessage(tab.id, { action: 'extract' });

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
            if (error.message?.includes('Receiving end does not exist') ||
                error.message?.includes('Could not establish connection')) {
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

        // Hide library selector (can't query native app via URL scheme)
        this.elements.librarySelect.style.display = 'none';

        // Hide "already saved" notice (can't check duplicates via URL scheme)
        this.elements.alreadySaved.classList.add('hidden');

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

    async handleImport() {
        if (!this.currentMetadata) return;

        // Update UI
        this.elements.importBtn.disabled = true;
        this.elements.importBtn.querySelector('.button-text').textContent = 'Importing...';
        this.elements.importBtn.querySelector('.button-spinner').classList.remove('hidden');

        try {
            // Build URL scheme parameters
            const params = new URLSearchParams();
            const metadata = this.currentMetadata;

            if (metadata.sourceType) params.set('sourceType', metadata.sourceType);
            if (metadata.bibcode) params.set('bibcode', metadata.bibcode);
            if (metadata.arxivID) params.set('arxivID', metadata.arxivID);
            if (metadata.doi) params.set('doi', metadata.doi);
            if (metadata.pmid) params.set('pmid', metadata.pmid);
            if (metadata.title) params.set('title', metadata.title);
            if (metadata.authors?.length) params.set('authors', metadata.authors.join('|'));
            if (metadata.year) params.set('year', metadata.year);
            if (metadata.journal) params.set('journal', metadata.journal);
            if (metadata.volume) params.set('volume', metadata.volume);
            if (metadata.pages) params.set('pages', metadata.pages);
            if (metadata.abstract) params.set('abstract', metadata.abstract.substring(0, 2000)); // Limit length

            const url = `imbib://import?${params.toString()}`;

            // Open URL scheme to trigger imbib app
            window.location.href = url;

            // Show success (we can't verify the app received it)
            this.showState('success');

            // Auto-close after success
            setTimeout(() => window.close(), 1500);

        } catch (error) {
            console.error('Import error:', error);
            this.showError('Failed to open imbib. Is the app installed?');

            // Reset button
            this.elements.importBtn.disabled = false;
            this.elements.importBtn.querySelector('.button-text').textContent = 'Import';
            this.elements.importBtn.querySelector('.button-spinner').classList.add('hidden');
        }
    }

    showState(stateName) {
        Object.entries(this.states).forEach(([name, el]) => {
            if (el) {
                if (name === stateName) {
                    el.classList.remove('hidden');
                } else {
                    el.classList.add('hidden');
                }
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

            // Build URL scheme to create smart search
            const params = new URLSearchParams();
            params.set('query', this.currentSearchQuery);
            params.set('name', name);
            params.set('sourceID', 'ads');

            const url = `imbib://search/create-smart-search?${params.toString()}`;

            // Open URL scheme to trigger imbib app
            window.location.href = url;

            // Show success (we can't verify the app received it)
            this.showState('success');

            // Auto-close after success
            setTimeout(() => window.close(), 1500);

        } catch (error) {
            console.error('Smart search creation error:', error);
            this.showError('Failed to open imbib. Is the app installed?');

            // Reset button
            btn.disabled = false;
            btn.querySelector('.button-text').textContent = 'Create Smart Search';
            btn.querySelector('.button-spinner').classList.add('hidden');
        }
    }
}

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    new PopupController();
});
