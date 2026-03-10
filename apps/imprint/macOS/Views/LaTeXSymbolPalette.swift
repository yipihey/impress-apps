import SwiftUI

/// Searchable grid of LaTeX math symbols for quick insertion.
/// Invoked via Cmd+Shift+Y.
struct LaTeXSymbolPalette: View {
    @Binding var isPresented: Bool
    let onInsert: (String) -> Void

    @State private var searchText = ""
    @State private var selectedCategory: SymbolCategory = .greek

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search symbols...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Category tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(SymbolCategory.allCases, id: \.self) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            Text(category.displayName)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    selectedCategory == category
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.clear,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Divider()

            // Symbol grid
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 4), count: 8), spacing: 4) {
                    ForEach(filteredSymbols, id: \.command) { symbol in
                        Button {
                            onInsert(symbol.command)
                            isPresented = false
                        } label: {
                            VStack(spacing: 2) {
                                Text(symbol.display)
                                    .font(.system(size: 18))
                                    .frame(width: 40, height: 28)
                                Text(symbol.name)
                                    .font(.system(size: 7))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 44, height: 44)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help(symbol.command)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 400, height: 400)
    }

    private var filteredSymbols: [LaTeXSymbol] {
        let symbols = Self.symbols[selectedCategory] ?? []
        if searchText.isEmpty { return symbols }
        return symbols.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.command.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Symbol Data

    enum SymbolCategory: String, CaseIterable {
        case greek, operators, relations, arrows, delimiters, accents, misc

        var displayName: String {
            switch self {
            case .greek: "Greek"
            case .operators: "Operators"
            case .relations: "Relations"
            case .arrows: "Arrows"
            case .delimiters: "Delimiters"
            case .accents: "Accents"
            case .misc: "Misc"
            }
        }
    }

    struct LaTeXSymbol {
        let display: String   // Unicode rendering
        let command: String   // LaTeX command
        let name: String      // Short name
    }

    static let symbols: [SymbolCategory: [LaTeXSymbol]] = [
        .greek: [
            LaTeXSymbol(display: "\u{03B1}", command: "\\alpha", name: "alpha"),
            LaTeXSymbol(display: "\u{03B2}", command: "\\beta", name: "beta"),
            LaTeXSymbol(display: "\u{03B3}", command: "\\gamma", name: "gamma"),
            LaTeXSymbol(display: "\u{03B4}", command: "\\delta", name: "delta"),
            LaTeXSymbol(display: "\u{03B5}", command: "\\epsilon", name: "epsilon"),
            LaTeXSymbol(display: "\u{03B6}", command: "\\zeta", name: "zeta"),
            LaTeXSymbol(display: "\u{03B7}", command: "\\eta", name: "eta"),
            LaTeXSymbol(display: "\u{03B8}", command: "\\theta", name: "theta"),
            LaTeXSymbol(display: "\u{03B9}", command: "\\iota", name: "iota"),
            LaTeXSymbol(display: "\u{03BA}", command: "\\kappa", name: "kappa"),
            LaTeXSymbol(display: "\u{03BB}", command: "\\lambda", name: "lambda"),
            LaTeXSymbol(display: "\u{03BC}", command: "\\mu", name: "mu"),
            LaTeXSymbol(display: "\u{03BD}", command: "\\nu", name: "nu"),
            LaTeXSymbol(display: "\u{03BE}", command: "\\xi", name: "xi"),
            LaTeXSymbol(display: "\u{03C0}", command: "\\pi", name: "pi"),
            LaTeXSymbol(display: "\u{03C1}", command: "\\rho", name: "rho"),
            LaTeXSymbol(display: "\u{03C3}", command: "\\sigma", name: "sigma"),
            LaTeXSymbol(display: "\u{03C4}", command: "\\tau", name: "tau"),
            LaTeXSymbol(display: "\u{03C5}", command: "\\upsilon", name: "upsilon"),
            LaTeXSymbol(display: "\u{03C6}", command: "\\phi", name: "phi"),
            LaTeXSymbol(display: "\u{03C7}", command: "\\chi", name: "chi"),
            LaTeXSymbol(display: "\u{03C8}", command: "\\psi", name: "psi"),
            LaTeXSymbol(display: "\u{03C9}", command: "\\omega", name: "omega"),
            LaTeXSymbol(display: "\u{0393}", command: "\\Gamma", name: "Gamma"),
            LaTeXSymbol(display: "\u{0394}", command: "\\Delta", name: "Delta"),
            LaTeXSymbol(display: "\u{0398}", command: "\\Theta", name: "Theta"),
            LaTeXSymbol(display: "\u{039B}", command: "\\Lambda", name: "Lambda"),
            LaTeXSymbol(display: "\u{039E}", command: "\\Xi", name: "Xi"),
            LaTeXSymbol(display: "\u{03A0}", command: "\\Pi", name: "Pi"),
            LaTeXSymbol(display: "\u{03A3}", command: "\\Sigma", name: "Sigma"),
            LaTeXSymbol(display: "\u{03A6}", command: "\\Phi", name: "Phi"),
            LaTeXSymbol(display: "\u{03A8}", command: "\\Psi", name: "Psi"),
            LaTeXSymbol(display: "\u{03A9}", command: "\\Omega", name: "Omega"),
        ],
        .operators: [
            LaTeXSymbol(display: "\u{00B1}", command: "\\pm", name: "plus-minus"),
            LaTeXSymbol(display: "\u{2213}", command: "\\mp", name: "minus-plus"),
            LaTeXSymbol(display: "\u{00D7}", command: "\\times", name: "times"),
            LaTeXSymbol(display: "\u{00F7}", command: "\\div", name: "divide"),
            LaTeXSymbol(display: "\u{22C5}", command: "\\cdot", name: "cdot"),
            LaTeXSymbol(display: "\u{2217}", command: "\\ast", name: "asterisk"),
            LaTeXSymbol(display: "\u{2218}", command: "\\circ", name: "circle"),
            LaTeXSymbol(display: "\u{2211}", command: "\\sum", name: "sum"),
            LaTeXSymbol(display: "\u{220F}", command: "\\prod", name: "product"),
            LaTeXSymbol(display: "\u{222B}", command: "\\int", name: "integral"),
            LaTeXSymbol(display: "\u{222E}", command: "\\oint", name: "contour int"),
            LaTeXSymbol(display: "\u{2202}", command: "\\partial", name: "partial"),
            LaTeXSymbol(display: "\u{2207}", command: "\\nabla", name: "nabla"),
            LaTeXSymbol(display: "\u{221A}", command: "\\sqrt{}", name: "sqrt"),
            LaTeXSymbol(display: "\u{221E}", command: "\\infty", name: "infinity"),
        ],
        .relations: [
            LaTeXSymbol(display: "\u{2264}", command: "\\leq", name: "leq"),
            LaTeXSymbol(display: "\u{2265}", command: "\\geq", name: "geq"),
            LaTeXSymbol(display: "\u{226A}", command: "\\ll", name: "much less"),
            LaTeXSymbol(display: "\u{226B}", command: "\\gg", name: "much greater"),
            LaTeXSymbol(display: "\u{2260}", command: "\\neq", name: "not equal"),
            LaTeXSymbol(display: "\u{2248}", command: "\\approx", name: "approx"),
            LaTeXSymbol(display: "\u{2261}", command: "\\equiv", name: "equiv"),
            LaTeXSymbol(display: "\u{223C}", command: "\\sim", name: "similar"),
            LaTeXSymbol(display: "\u{221D}", command: "\\propto", name: "propto"),
            LaTeXSymbol(display: "\u{2208}", command: "\\in", name: "in"),
            LaTeXSymbol(display: "\u{2209}", command: "\\notin", name: "not in"),
            LaTeXSymbol(display: "\u{2282}", command: "\\subset", name: "subset"),
            LaTeXSymbol(display: "\u{2286}", command: "\\subseteq", name: "subseteq"),
            LaTeXSymbol(display: "\u{2229}", command: "\\cap", name: "cap"),
            LaTeXSymbol(display: "\u{222A}", command: "\\cup", name: "cup"),
        ],
        .arrows: [
            LaTeXSymbol(display: "\u{2190}", command: "\\leftarrow", name: "left"),
            LaTeXSymbol(display: "\u{2192}", command: "\\rightarrow", name: "right"),
            LaTeXSymbol(display: "\u{2191}", command: "\\uparrow", name: "up"),
            LaTeXSymbol(display: "\u{2193}", command: "\\downarrow", name: "down"),
            LaTeXSymbol(display: "\u{2194}", command: "\\leftrightarrow", name: "leftright"),
            LaTeXSymbol(display: "\u{21D0}", command: "\\Leftarrow", name: "Left"),
            LaTeXSymbol(display: "\u{21D2}", command: "\\Rightarrow", name: "Right"),
            LaTeXSymbol(display: "\u{21D4}", command: "\\Leftrightarrow", name: "iff"),
            LaTeXSymbol(display: "\u{21A6}", command: "\\mapsto", name: "maps to"),
            LaTeXSymbol(display: "\u{21A9}", command: "\\hookleftarrow", name: "hook left"),
        ],
        .delimiters: [
            LaTeXSymbol(display: "(", command: "\\left( \\right)", name: "parens"),
            LaTeXSymbol(display: "[", command: "\\left[ \\right]", name: "brackets"),
            LaTeXSymbol(display: "{", command: "\\left\\{ \\right\\}", name: "braces"),
            LaTeXSymbol(display: "|", command: "\\left| \\right|", name: "abs"),
            LaTeXSymbol(display: "\u{2016}", command: "\\left\\| \\right\\|", name: "norm"),
            LaTeXSymbol(display: "\u{2308}", command: "\\lceil", name: "lceil"),
            LaTeXSymbol(display: "\u{2309}", command: "\\rceil", name: "rceil"),
            LaTeXSymbol(display: "\u{230A}", command: "\\lfloor", name: "lfloor"),
            LaTeXSymbol(display: "\u{230B}", command: "\\rfloor", name: "rfloor"),
            LaTeXSymbol(display: "\u{27E8}", command: "\\langle", name: "langle"),
            LaTeXSymbol(display: "\u{27E9}", command: "\\rangle", name: "rangle"),
        ],
        .accents: [
            LaTeXSymbol(display: "\u{00E2}", command: "\\hat{}", name: "hat"),
            LaTeXSymbol(display: "\u{0101}", command: "\\bar{}", name: "bar"),
            LaTeXSymbol(display: "a\u{0307}", command: "\\dot{}", name: "dot"),
            LaTeXSymbol(display: "a\u{0308}", command: "\\ddot{}", name: "ddot"),
            LaTeXSymbol(display: "\u{00E3}", command: "\\tilde{}", name: "tilde"),
            LaTeXSymbol(display: "a\u{20D7}", command: "\\vec{}", name: "vec"),
            LaTeXSymbol(display: "\u{00E0}", command: "\\grave{}", name: "grave"),
            LaTeXSymbol(display: "\u{00E1}", command: "\\acute{}", name: "acute"),
        ],
        .misc: [
            LaTeXSymbol(display: "\u{2200}", command: "\\forall", name: "forall"),
            LaTeXSymbol(display: "\u{2203}", command: "\\exists", name: "exists"),
            LaTeXSymbol(display: "\u{00AC}", command: "\\neg", name: "not"),
            LaTeXSymbol(display: "\u{2227}", command: "\\land", name: "and"),
            LaTeXSymbol(display: "\u{2228}", command: "\\lor", name: "or"),
            LaTeXSymbol(display: "\u{22A5}", command: "\\perp", name: "perp"),
            LaTeXSymbol(display: "\u{2026}", command: "\\ldots", name: "ldots"),
            LaTeXSymbol(display: "\u{22EF}", command: "\\cdots", name: "cdots"),
            LaTeXSymbol(display: "\u{22EE}", command: "\\vdots", name: "vdots"),
            LaTeXSymbol(display: "\u{22F1}", command: "\\ddots", name: "ddots"),
            LaTeXSymbol(display: "\u{2205}", command: "\\emptyset", name: "emptyset"),
            LaTeXSymbol(display: "\u{2135}", command: "\\aleph", name: "aleph"),
            LaTeXSymbol(display: "\u{210F}", command: "\\hbar", name: "hbar"),
            LaTeXSymbol(display: "\u{2113}", command: "\\ell", name: "ell"),
        ],
    ]
}

#Preview {
    LaTeXSymbolPalette(isPresented: .constant(true)) { symbol in
        print("Insert: \(symbol)")
    }
}
