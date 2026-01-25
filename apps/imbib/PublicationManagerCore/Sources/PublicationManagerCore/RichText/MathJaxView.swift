//
//  MathJaxView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-15.
//

import SwiftUI
import WebKit

// MARK: - MathJax Abstract View

/// Renders scientific abstracts using MathJax in a WebView, matching arXiv's rendering.
///
/// This approach provides accurate LaTeX rendering with proper inline positioning,
/// exactly as it appears on arXiv.org.
public struct MathJaxAbstractView: View {
    public let text: String
    public var fontSize: CGFloat
    public var textColor: Color

    @State private var contentHeight: CGFloat = 100

    public init(
        text: String,
        fontSize: CGFloat = 16,
        textColor: Color = .primary
    ) {
        self.text = text
        self.fontSize = fontSize
        self.textColor = textColor
    }

    public var body: some View {
        MathJaxWebView(
            text: text,
            fontSize: fontSize,
            textColor: textColor,
            contentHeight: $contentHeight
        )
        .frame(height: contentHeight)
    }
}

// MARK: - Platform-Specific WebView

#if os(macOS)

/// Custom WKWebView subclass that forwards scroll events to parent instead of handling them.
class NonScrollingWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        // Forward to enclosing scroll view instead of handling internally
        if let scrollView = findParentScrollView() {
            scrollView.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    private func findParentScrollView() -> NSScrollView? {
        var current: NSView? = superview
        while let view = current {
            // Skip our own internal scroll view
            if let sv = view as? NSScrollView, !(sv.documentView is WKWebView) && sv != self.enclosingScrollView {
                return sv
            }
            current = view.superview
        }
        return nil
    }
}

struct MathJaxWebView: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let textColor: Color
    @Binding var contentHeight: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // Add message handler ONCE during creation
        config.userContentController.add(context.coordinator, name: "heightChanged")

        // Use custom non-scrolling WebView subclass
        let webView = NonScrollingWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let html = generateHTML()
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func generateHTML() -> String {
        let colorHex = hexColor(from: textColor)

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <script>
                MathJax = {
                    tex: {
                        inlineMath: [['$', '$'], ['\\\\(', '\\\\)']],
                        displayMath: [['$$', '$$'], ['\\\\[', '\\\\]']],
                        processEscapes: true
                    },
                    svg: {
                        fontCache: 'global'
                    },
                    startup: {
                        pageReady: function() {
                            return MathJax.startup.defaultPageReady().then(function() {
                                // Report height after rendering
                                setTimeout(function() {
                                    var height = document.body.scrollHeight;
                                    window.webkit.messageHandlers.heightChanged.postMessage(height);
                                }, 100);
                            });
                        }
                    }
                };
            </script>
            <script src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg.js" async></script>
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    font-size: \(fontSize)px;
                    line-height: 1.5;
                    color: \(colorHex);
                    background: transparent;
                    overflow: hidden; /* Disable scrolling - parent handles scroll */
                    padding: 4px 0;
                    -webkit-user-select: text;
                    user-select: text;
                }
                .content {
                    word-wrap: break-word;
                    overflow-wrap: break-word;
                }
                mjx-container {
                    display: inline !important;
                    margin: 0 !important;
                }
                mjx-container[display="true"] {
                    display: block !important;
                    margin: 16px 0 !important;
                    text-align: center;
                }
            </style>
        </head>
        <body>
            <div class="content" id="content">\(text)</div>
            <script>
                // Handle dynamic content height
                window.addEventListener('resize', function() {
                    var height = document.body.scrollHeight;
                    window.webkit.messageHandlers.heightChanged.postMessage(height);
                });
                // Prevent wheel events from being captured - let parent scroll view handle them
                document.addEventListener('wheel', function(e) {
                    e.preventDefault();
                }, { passive: false });
            </script>
        </body>
        </html>
        """
    }

    private func hexColor(from color: Color) -> String {
        let nsColor = NSColor(color)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else {
            return "#000000"
        }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MathJaxWebView

        init(_ parent: MathJaxWebView) {
            self.parent = parent
            super.init()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Initial height calculation (message handler already added in makeNSView)
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, error in
                if let height = result as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        self?.parent.contentHeight = height + 8
                    }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "heightChanged", let height = message.body as? CGFloat {
                DispatchQueue.main.async {
                    self.parent.contentHeight = height + 8
                }
            }
        }
    }
}

#else

struct MathJaxWebView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let textColor: Color
    @Binding var contentHeight: CGFloat

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Add message handler ONCE during creation
        config.userContentController.add(context.coordinator, name: "heightChanged")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear

        // Disable scrolling on internal scroll view
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false

        // CRITICAL: Disable user interaction so touches pass through to parent ScrollView.
        // This sacrifices text selection in the abstract but enables proper scrolling.
        // On iOS, WKWebView's gesture recognizers capture all touches otherwise.
        webView.isUserInteractionEnabled = false

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = generateHTML()
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func generateHTML() -> String {
        let colorHex = hexColor(from: textColor)

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <script>
                MathJax = {
                    tex: {
                        inlineMath: [['$', '$'], ['\\\\(', '\\\\)']],
                        displayMath: [['$$', '$$'], ['\\\\[', '\\\\]']],
                        processEscapes: true
                    },
                    svg: {
                        fontCache: 'global'
                    },
                    startup: {
                        pageReady: function() {
                            return MathJax.startup.defaultPageReady().then(function() {
                                setTimeout(function() {
                                    var height = document.body.scrollHeight;
                                    window.webkit.messageHandlers.heightChanged.postMessage(height);
                                }, 100);
                            });
                        }
                    }
                };
            </script>
            <script src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg.js" async></script>
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    font-size: \(fontSize)px;
                    line-height: 1.5;
                    color: \(colorHex);
                    background: transparent;
                    overflow: hidden; /* Disable scrolling - parent handles scroll */
                    padding: 4px 0;
                    -webkit-user-select: text;
                    user-select: text;
                    -webkit-text-size-adjust: none;
                }
                .content {
                    word-wrap: break-word;
                    overflow-wrap: break-word;
                }
                mjx-container {
                    display: inline !important;
                    margin: 0 !important;
                }
                mjx-container[display="true"] {
                    display: block !important;
                    margin: 16px 0 !important;
                    text-align: center;
                }
            </style>
        </head>
        <body>
            <div class="content" id="content">\(text)</div>
            <script>
                window.addEventListener('resize', function() {
                    var height = document.body.scrollHeight;
                    window.webkit.messageHandlers.heightChanged.postMessage(height);
                });
                // Prevent wheel/touch events from being captured - let parent scroll view handle them
                document.addEventListener('wheel', function(e) {
                    e.preventDefault();
                }, { passive: false });
                document.addEventListener('touchmove', function(e) {
                    e.preventDefault();
                }, { passive: false });
            </script>
        </body>
        </html>
        """
    }

    private func hexColor(from color: Color) -> String {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MathJaxWebView

        init(_ parent: MathJaxWebView) {
            self.parent = parent
            super.init()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Initial height calculation (message handler already added in makeUIView)
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, error in
                if let height = result as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        self?.parent.contentHeight = height + 8
                    }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "heightChanged", let height = message.body as? CGFloat {
                DispatchQueue.main.async {
                    self.parent.contentHeight = height + 8
                }
            }
        }
    }
}

#endif

// MARK: - Preview

#Preview("MathJax Abstract") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text("arXiv:2601.09369")
                .font(.headline)

            MathJaxAbstractView(
                text: """
                One of the key challenges in strong gravitational lensing cosmology is the accurate measurement of time delays between multiple lensed images, which are essential for constraining the Hubble constant ($H_0$). We investigate how lens mass-profile assumptions affect time delays. Specifically, we implement a broken power-law (BPL) mass model within the Lenstronomy framework.
                """,
                fontSize: 14
            )

            Divider()

            Text("arXiv:2601.08933")
                .font(.headline)

            MathJaxAbstractView(
                text: """
                This study aims at using Sunyaev-Zel'dovich (SZ) data to test four different functional forms for the cluster pressure profile: generalized Navarro-Frenk-White (gNFW), $\\beta$-model, polytropic, and exponential. A set of 3496 ACT-DR4 galaxy clusters, spanning the mass range $[10^{14},10^{15.1}]\\,\\text{M}_{\\odot}$ and the redshift range $[0,2]$, is stacked on the ACT-DR6 Compton parameter $y$ map.
                """,
                fontSize: 14
            )
        }
        .padding()
    }
}
