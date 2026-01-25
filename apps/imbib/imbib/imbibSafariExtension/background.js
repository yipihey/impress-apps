// background.js - Safari extension background service worker

// Track content script readiness per tab
const tabStates = new Map();

// Listen for content script ready messages
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.action === 'contentReady') {
        if (sender.tab?.id) {
            tabStates.set(sender.tab.id, {
                ready: true,
                url: message.url,
                timestamp: Date.now()
            });
        }
        return;
    }

    // Forward other messages as needed
    return false;
});

// Clean up closed tabs
browser.tabs.onRemoved.addListener((tabId) => {
    tabStates.delete(tabId);
});

// Update tab state on navigation
browser.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    if (changeInfo.status === 'loading') {
        // Reset state when navigating
        tabStates.delete(tabId);
    }
});

// Handle extension icon click (if no popup)
browser.action.onClicked.addListener(async (tab) => {
    // This won't fire when popup is configured, but kept for reference
    console.log('Extension icon clicked for tab:', tab.url);
});

// Log extension startup
console.log('imbib Safari extension background script loaded');
