// background.js - Browser extension service worker (Chrome/Firefox/Edge)
// Simplified version - URL scheme communication doesn't require background processing

// Track content script readiness per tab
const tabStates = new Map();

// Listen for content script ready messages
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
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
chrome.tabs.onRemoved.addListener((tabId) => {
    tabStates.delete(tabId);
});

// Update tab state on navigation
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    if (changeInfo.status === 'loading') {
        // Reset state when navigating
        tabStates.delete(tabId);
    }
});

// Log extension startup
console.log('imbib browser extension background script loaded');
