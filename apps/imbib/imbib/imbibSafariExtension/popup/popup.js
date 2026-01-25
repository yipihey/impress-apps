// popup.js - Safari extension popup controller

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
}

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    new PopupController();
});
