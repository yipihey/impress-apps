// GetPageInfo.js - JavaScript preprocessing for share extension
//
// This script runs in the webpage context before the share extension loads.
// It extracts the page title which contains the clean ADS query.

var GetPageInfo = function() {};

GetPageInfo.prototype = {
    run: function(arguments) {
        arguments.completionFunction({
            "title": document.title,
            "url": document.URL
        });
    }
};

var ExtensionPreprocessingJS = new GetPageInfo;
