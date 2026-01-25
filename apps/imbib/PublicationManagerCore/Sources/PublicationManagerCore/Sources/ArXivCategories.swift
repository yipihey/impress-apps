//
//  ArXivCategories.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import Foundation

// MARK: - arXiv Category

/// An arXiv category with metadata for UI display.
public struct ArXivCategory: Identifiable, Hashable, Sendable {
    /// Category identifier (e.g., "cs.LG", "astro-ph.GA")
    public let id: String

    /// Human-readable name (e.g., "Machine Learning")
    public let name: String

    /// Parent group (e.g., "Computer Science", "Astrophysics")
    public let group: String

    /// Optional description of what the category covers
    public let description: String?

    public init(id: String, name: String, group: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.group = group
        self.description = description
    }
}

// MARK: - arXiv Category Group

/// A group of related arXiv categories.
public struct ArXivCategoryGroup: Identifiable, Hashable, Sendable {
    /// Group identifier (e.g., "cs", "astro-ph")
    public let id: String

    /// Human-readable name (e.g., "Computer Science")
    public let name: String

    /// SF Symbol icon for the group
    public let iconName: String

    /// Categories in this group
    public let categories: [ArXivCategory]

    public init(id: String, name: String, iconName: String, categories: [ArXivCategory]) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.categories = categories
    }
}

// MARK: - arXiv Categories Data

/// Complete catalog of arXiv categories.
public enum ArXivCategories {

    // MARK: - All Groups

    /// All category groups
    public static let groups: [ArXivCategoryGroup] = [
        computerScience,
        statistics,
        mathematics,
        physics,
        astrophysics,
        quantitativeFinance,
        quantitativeBiology,
        electricalEngineering,
        economics
    ]

    /// All categories flattened
    public static var all: [ArXivCategory] {
        groups.flatMap(\.categories)
    }

    /// Look up a category by ID
    public static func category(for id: String) -> ArXivCategory? {
        all.first { $0.id.lowercased() == id.lowercased() }
    }

    /// Look up a group by ID
    public static func group(for id: String) -> ArXivCategoryGroup? {
        groups.first { $0.id.lowercased() == id.lowercased() }
    }

    /// Categories suggested for AI/ML researchers
    public static let suggestedML: [ArXivCategory] = [
        category(for: "cs.LG")!,
        category(for: "cs.AI")!,
        category(for: "cs.CL")!,
        category(for: "cs.CV")!,
        category(for: "cs.NE")!,
        category(for: "stat.ML")!,
    ]

    /// Categories suggested for astronomers
    public static let suggestedAstro: [ArXivCategory] = [
        category(for: "astro-ph.GA")!,
        category(for: "astro-ph.CO")!,
        category(for: "astro-ph.SR")!,
        category(for: "astro-ph.HE")!,
        category(for: "astro-ph.EP")!,
        category(for: "astro-ph.IM")!,
    ]

    // MARK: - Computer Science

    public static let computerScience = ArXivCategoryGroup(
        id: "cs",
        name: "Computer Science",
        iconName: "desktopcomputer",
        categories: [
            ArXivCategory(
                id: "cs.AI",
                name: "Artificial Intelligence",
                group: "Computer Science",
                description: "Covers all areas of AI except Vision, Robotics, Machine Learning, Multiagent Systems, and Computation and Language"
            ),
            ArXivCategory(
                id: "cs.AR",
                name: "Hardware Architecture",
                group: "Computer Science",
                description: "Covers systems organization and architecture"
            ),
            ArXivCategory(
                id: "cs.CC",
                name: "Computational Complexity",
                group: "Computer Science",
                description: "Covers models of computation, complexity classes, structural complexity"
            ),
            ArXivCategory(
                id: "cs.CE",
                name: "Computational Engineering",
                group: "Computer Science",
                description: "Covers applications of computer science to engineering problems"
            ),
            ArXivCategory(
                id: "cs.CG",
                name: "Computational Geometry",
                group: "Computer Science",
                description: "Covers all aspects of computational geometry"
            ),
            ArXivCategory(
                id: "cs.CL",
                name: "Computation and Language",
                group: "Computer Science",
                description: "Natural language processing, computational linguistics, speech recognition"
            ),
            ArXivCategory(
                id: "cs.CR",
                name: "Cryptography and Security",
                group: "Computer Science",
                description: "Covers all areas of cryptography and security"
            ),
            ArXivCategory(
                id: "cs.CV",
                name: "Computer Vision and Pattern Recognition",
                group: "Computer Science",
                description: "Image processing, computer vision, pattern recognition"
            ),
            ArXivCategory(
                id: "cs.CY",
                name: "Computers and Society",
                group: "Computer Science",
                description: "Social and ethical issues in computing"
            ),
            ArXivCategory(
                id: "cs.DB",
                name: "Databases",
                group: "Computer Science",
                description: "Database management, data mining, information retrieval"
            ),
            ArXivCategory(
                id: "cs.DC",
                name: "Distributed Computing",
                group: "Computer Science",
                description: "Distributed and parallel algorithms, fault tolerance"
            ),
            ArXivCategory(
                id: "cs.DL",
                name: "Digital Libraries",
                group: "Computer Science",
                description: "Digital libraries, metadata, preservation"
            ),
            ArXivCategory(
                id: "cs.DM",
                name: "Discrete Mathematics",
                group: "Computer Science",
                description: "Combinatorics, graph theory, discrete algorithms"
            ),
            ArXivCategory(
                id: "cs.DS",
                name: "Data Structures and Algorithms",
                group: "Computer Science",
                description: "Covers data structures and analysis of algorithms"
            ),
            ArXivCategory(
                id: "cs.ET",
                name: "Emerging Technologies",
                group: "Computer Science",
                description: "Quantum computing, DNA computing, optical computing"
            ),
            ArXivCategory(
                id: "cs.FL",
                name: "Formal Languages and Automata Theory",
                group: "Computer Science",
                description: "Covers formal languages, automata, grammars"
            ),
            ArXivCategory(
                id: "cs.GL",
                name: "General Literature",
                group: "Computer Science",
                description: "General introductions, surveys, bibliographies"
            ),
            ArXivCategory(
                id: "cs.GR",
                name: "Graphics",
                group: "Computer Science",
                description: "Computer graphics, visualization, geometric modeling"
            ),
            ArXivCategory(
                id: "cs.GT",
                name: "Computer Science and Game Theory",
                group: "Computer Science",
                description: "Algorithmic game theory, mechanism design"
            ),
            ArXivCategory(
                id: "cs.HC",
                name: "Human-Computer Interaction",
                group: "Computer Science",
                description: "Covers human factors, user interfaces, accessibility"
            ),
            ArXivCategory(
                id: "cs.IR",
                name: "Information Retrieval",
                group: "Computer Science",
                description: "Search engines, recommender systems, text mining"
            ),
            ArXivCategory(
                id: "cs.IT",
                name: "Information Theory",
                group: "Computer Science",
                description: "Covers theoretical and applied aspects of information theory"
            ),
            ArXivCategory(
                id: "cs.LG",
                name: "Machine Learning",
                group: "Computer Science",
                description: "Papers on all aspects of machine learning research"
            ),
            ArXivCategory(
                id: "cs.LO",
                name: "Logic in Computer Science",
                group: "Computer Science",
                description: "Covers all aspects of logic in computer science"
            ),
            ArXivCategory(
                id: "cs.MA",
                name: "Multiagent Systems",
                group: "Computer Science",
                description: "Multi-agent systems, agent-based simulation"
            ),
            ArXivCategory(
                id: "cs.MM",
                name: "Multimedia",
                group: "Computer Science",
                description: "Multimedia systems, audio/video processing"
            ),
            ArXivCategory(
                id: "cs.MS",
                name: "Mathematical Software",
                group: "Computer Science",
                description: "Covers numerical algorithms and their implementation"
            ),
            ArXivCategory(
                id: "cs.NA",
                name: "Numerical Analysis",
                group: "Computer Science",
                description: "Numerical methods, computational science"
            ),
            ArXivCategory(
                id: "cs.NE",
                name: "Neural and Evolutionary Computing",
                group: "Computer Science",
                description: "Neural networks, genetic algorithms, artificial life"
            ),
            ArXivCategory(
                id: "cs.NI",
                name: "Networking and Internet Architecture",
                group: "Computer Science",
                description: "Network protocols, architectures, applications"
            ),
            ArXivCategory(
                id: "cs.OH",
                name: "Other Computer Science",
                group: "Computer Science",
                description: "Topics not covered by other CS categories"
            ),
            ArXivCategory(
                id: "cs.OS",
                name: "Operating Systems",
                group: "Computer Science",
                description: "Operating systems, file systems, scheduling"
            ),
            ArXivCategory(
                id: "cs.PF",
                name: "Performance",
                group: "Computer Science",
                description: "Performance modeling, evaluation, benchmarking"
            ),
            ArXivCategory(
                id: "cs.PL",
                name: "Programming Languages",
                group: "Computer Science",
                description: "Programming language design, implementation, semantics"
            ),
            ArXivCategory(
                id: "cs.RO",
                name: "Robotics",
                group: "Computer Science",
                description: "Robotic manipulation, locomotion, planning"
            ),
            ArXivCategory(
                id: "cs.SC",
                name: "Symbolic Computation",
                group: "Computer Science",
                description: "Computer algebra, symbolic methods"
            ),
            ArXivCategory(
                id: "cs.SD",
                name: "Sound",
                group: "Computer Science",
                description: "Audio processing, music information retrieval"
            ),
            ArXivCategory(
                id: "cs.SE",
                name: "Software Engineering",
                group: "Computer Science",
                description: "Software development processes and tools"
            ),
            ArXivCategory(
                id: "cs.SI",
                name: "Social and Information Networks",
                group: "Computer Science",
                description: "Social networks, information diffusion"
            ),
            ArXivCategory(
                id: "cs.SY",
                name: "Systems and Control",
                group: "Computer Science",
                description: "Control systems, dynamical systems"
            )
        ]
    )

    // MARK: - Statistics

    public static let statistics = ArXivCategoryGroup(
        id: "stat",
        name: "Statistics",
        iconName: "chart.bar",
        categories: [
            ArXivCategory(
                id: "stat.AP",
                name: "Applications",
                group: "Statistics",
                description: "Applied statistics and statistical methods"
            ),
            ArXivCategory(
                id: "stat.CO",
                name: "Computation",
                group: "Statistics",
                description: "Computational statistics, MCMC, simulation"
            ),
            ArXivCategory(
                id: "stat.ME",
                name: "Methodology",
                group: "Statistics",
                description: "Statistical methodology and theory"
            ),
            ArXivCategory(
                id: "stat.ML",
                name: "Machine Learning",
                group: "Statistics",
                description: "Statistical approaches to machine learning"
            ),
            ArXivCategory(
                id: "stat.OT",
                name: "Other Statistics",
                group: "Statistics",
                description: "Other statistics topics"
            ),
            ArXivCategory(
                id: "stat.TH",
                name: "Statistics Theory",
                group: "Statistics",
                description: "Theoretical statistics"
            )
        ]
    )

    // MARK: - Mathematics

    public static let mathematics = ArXivCategoryGroup(
        id: "math",
        name: "Mathematics",
        iconName: "function",
        categories: [
            ArXivCategory(id: "math.AC", name: "Commutative Algebra", group: "Mathematics"),
            ArXivCategory(id: "math.AG", name: "Algebraic Geometry", group: "Mathematics"),
            ArXivCategory(id: "math.AP", name: "Analysis of PDEs", group: "Mathematics"),
            ArXivCategory(id: "math.AT", name: "Algebraic Topology", group: "Mathematics"),
            ArXivCategory(id: "math.CA", name: "Classical Analysis and ODEs", group: "Mathematics"),
            ArXivCategory(id: "math.CO", name: "Combinatorics", group: "Mathematics"),
            ArXivCategory(id: "math.CT", name: "Category Theory", group: "Mathematics"),
            ArXivCategory(id: "math.CV", name: "Complex Variables", group: "Mathematics"),
            ArXivCategory(id: "math.DG", name: "Differential Geometry", group: "Mathematics"),
            ArXivCategory(id: "math.DS", name: "Dynamical Systems", group: "Mathematics"),
            ArXivCategory(id: "math.FA", name: "Functional Analysis", group: "Mathematics"),
            ArXivCategory(id: "math.GM", name: "General Mathematics", group: "Mathematics"),
            ArXivCategory(id: "math.GN", name: "General Topology", group: "Mathematics"),
            ArXivCategory(id: "math.GR", name: "Group Theory", group: "Mathematics"),
            ArXivCategory(id: "math.GT", name: "Geometric Topology", group: "Mathematics"),
            ArXivCategory(id: "math.HO", name: "History and Overview", group: "Mathematics"),
            ArXivCategory(id: "math.IT", name: "Information Theory", group: "Mathematics"),
            ArXivCategory(id: "math.KT", name: "K-Theory and Homology", group: "Mathematics"),
            ArXivCategory(id: "math.LO", name: "Logic", group: "Mathematics"),
            ArXivCategory(id: "math.MG", name: "Metric Geometry", group: "Mathematics"),
            ArXivCategory(id: "math.MP", name: "Mathematical Physics", group: "Mathematics"),
            ArXivCategory(id: "math.NA", name: "Numerical Analysis", group: "Mathematics"),
            ArXivCategory(id: "math.NT", name: "Number Theory", group: "Mathematics"),
            ArXivCategory(id: "math.OA", name: "Operator Algebras", group: "Mathematics"),
            ArXivCategory(id: "math.OC", name: "Optimization and Control", group: "Mathematics"),
            ArXivCategory(id: "math.PR", name: "Probability", group: "Mathematics"),
            ArXivCategory(id: "math.QA", name: "Quantum Algebra", group: "Mathematics"),
            ArXivCategory(id: "math.RA", name: "Rings and Algebras", group: "Mathematics"),
            ArXivCategory(id: "math.RT", name: "Representation Theory", group: "Mathematics"),
            ArXivCategory(id: "math.SG", name: "Symplectic Geometry", group: "Mathematics"),
            ArXivCategory(id: "math.SP", name: "Spectral Theory", group: "Mathematics"),
            ArXivCategory(id: "math.ST", name: "Statistics Theory", group: "Mathematics")
        ]
    )

    // MARK: - Physics

    public static let physics = ArXivCategoryGroup(
        id: "physics",
        name: "Physics",
        iconName: "atom",
        categories: [
            ArXivCategory(id: "cond-mat.dis-nn", name: "Disordered Systems and Neural Networks", group: "Physics"),
            ArXivCategory(id: "cond-mat.mes-hall", name: "Mesoscale and Nanoscale Physics", group: "Physics"),
            ArXivCategory(id: "cond-mat.mtrl-sci", name: "Materials Science", group: "Physics"),
            ArXivCategory(id: "cond-mat.other", name: "Other Condensed Matter", group: "Physics"),
            ArXivCategory(id: "cond-mat.quant-gas", name: "Quantum Gases", group: "Physics"),
            ArXivCategory(id: "cond-mat.soft", name: "Soft Condensed Matter", group: "Physics"),
            ArXivCategory(id: "cond-mat.stat-mech", name: "Statistical Mechanics", group: "Physics"),
            ArXivCategory(id: "cond-mat.str-el", name: "Strongly Correlated Electrons", group: "Physics"),
            ArXivCategory(id: "cond-mat.supr-con", name: "Superconductivity", group: "Physics"),
            ArXivCategory(id: "gr-qc", name: "General Relativity and Quantum Cosmology", group: "Physics"),
            ArXivCategory(id: "hep-ex", name: "High Energy Physics - Experiment", group: "Physics"),
            ArXivCategory(id: "hep-lat", name: "High Energy Physics - Lattice", group: "Physics"),
            ArXivCategory(id: "hep-ph", name: "High Energy Physics - Phenomenology", group: "Physics"),
            ArXivCategory(id: "hep-th", name: "High Energy Physics - Theory", group: "Physics"),
            ArXivCategory(id: "math-ph", name: "Mathematical Physics", group: "Physics"),
            ArXivCategory(id: "nlin.AO", name: "Adaptation and Self-Organizing Systems", group: "Physics"),
            ArXivCategory(id: "nlin.CD", name: "Chaotic Dynamics", group: "Physics"),
            ArXivCategory(id: "nlin.CG", name: "Cellular Automata and Lattice Gases", group: "Physics"),
            ArXivCategory(id: "nlin.PS", name: "Pattern Formation and Solitons", group: "Physics"),
            ArXivCategory(id: "nlin.SI", name: "Exactly Solvable and Integrable Systems", group: "Physics"),
            ArXivCategory(id: "nucl-ex", name: "Nuclear Experiment", group: "Physics"),
            ArXivCategory(id: "nucl-th", name: "Nuclear Theory", group: "Physics"),
            ArXivCategory(id: "physics.acc-ph", name: "Accelerator Physics", group: "Physics"),
            ArXivCategory(id: "physics.ao-ph", name: "Atmospheric and Oceanic Physics", group: "Physics"),
            ArXivCategory(id: "physics.app-ph", name: "Applied Physics", group: "Physics"),
            ArXivCategory(id: "physics.atm-clus", name: "Atomic and Molecular Clusters", group: "Physics"),
            ArXivCategory(id: "physics.atom-ph", name: "Atomic Physics", group: "Physics"),
            ArXivCategory(id: "physics.bio-ph", name: "Biological Physics", group: "Physics"),
            ArXivCategory(id: "physics.chem-ph", name: "Chemical Physics", group: "Physics"),
            ArXivCategory(id: "physics.class-ph", name: "Classical Physics", group: "Physics"),
            ArXivCategory(id: "physics.comp-ph", name: "Computational Physics", group: "Physics"),
            ArXivCategory(id: "physics.data-an", name: "Data Analysis, Statistics and Probability", group: "Physics"),
            ArXivCategory(id: "physics.ed-ph", name: "Physics Education", group: "Physics"),
            ArXivCategory(id: "physics.flu-dyn", name: "Fluid Dynamics", group: "Physics"),
            ArXivCategory(id: "physics.gen-ph", name: "General Physics", group: "Physics"),
            ArXivCategory(id: "physics.geo-ph", name: "Geophysics", group: "Physics"),
            ArXivCategory(id: "physics.hist-ph", name: "History and Philosophy of Physics", group: "Physics"),
            ArXivCategory(id: "physics.ins-det", name: "Instrumentation and Detectors", group: "Physics"),
            ArXivCategory(id: "physics.med-ph", name: "Medical Physics", group: "Physics"),
            ArXivCategory(id: "physics.optics", name: "Optics", group: "Physics"),
            ArXivCategory(id: "physics.plasm-ph", name: "Plasma Physics", group: "Physics"),
            ArXivCategory(id: "physics.pop-ph", name: "Popular Physics", group: "Physics"),
            ArXivCategory(id: "physics.soc-ph", name: "Physics and Society", group: "Physics"),
            ArXivCategory(id: "physics.space-ph", name: "Space Physics", group: "Physics"),
            ArXivCategory(id: "quant-ph", name: "Quantum Physics", group: "Physics")
        ]
    )

    // MARK: - Astrophysics

    public static let astrophysics = ArXivCategoryGroup(
        id: "astro-ph",
        name: "Astrophysics",
        iconName: "sparkles",
        categories: [
            ArXivCategory(
                id: "astro-ph.CO",
                name: "Cosmology and Nongalactic Astrophysics",
                group: "Astrophysics",
                description: "Cosmology, large-scale structure, cosmic microwave background"
            ),
            ArXivCategory(
                id: "astro-ph.EP",
                name: "Earth and Planetary Astrophysics",
                group: "Astrophysics",
                description: "Exoplanets, planet formation, planetary systems, astrobiology"
            ),
            ArXivCategory(
                id: "astro-ph.GA",
                name: "Astrophysics of Galaxies",
                group: "Astrophysics",
                description: "Galaxy formation, structure, dynamics, stellar populations"
            ),
            ArXivCategory(
                id: "astro-ph.HE",
                name: "High Energy Astrophysical Phenomena",
                group: "Astrophysics",
                description: "Black holes, neutron stars, gamma-ray bursts, cosmic rays"
            ),
            ArXivCategory(
                id: "astro-ph.IM",
                name: "Instrumentation and Methods",
                group: "Astrophysics",
                description: "Astronomical instrumentation, techniques, data analysis"
            ),
            ArXivCategory(
                id: "astro-ph.SR",
                name: "Solar and Stellar Astrophysics",
                group: "Astrophysics",
                description: "Stars, stellar evolution, the Sun, star formation"
            )
        ]
    )

    // MARK: - Quantitative Finance

    public static let quantitativeFinance = ArXivCategoryGroup(
        id: "q-fin",
        name: "Quantitative Finance",
        iconName: "chart.line.uptrend.xyaxis",
        categories: [
            ArXivCategory(id: "q-fin.CP", name: "Computational Finance", group: "Quantitative Finance"),
            ArXivCategory(id: "q-fin.EC", name: "Economics", group: "Quantitative Finance"),
            ArXivCategory(id: "q-fin.GN", name: "General Finance", group: "Quantitative Finance"),
            ArXivCategory(id: "q-fin.MF", name: "Mathematical Finance", group: "Quantitative Finance"),
            ArXivCategory(id: "q-fin.PM", name: "Portfolio Management", group: "Quantitative Finance"),
            ArXivCategory(id: "q-fin.PR", name: "Pricing of Securities", group: "Quantitative Finance"),
            ArXivCategory(id: "q-fin.RM", name: "Risk Management", group: "Quantitative Finance"),
            ArXivCategory(id: "q-fin.ST", name: "Statistical Finance", group: "Quantitative Finance"),
            ArXivCategory(id: "q-fin.TR", name: "Trading and Market Microstructure", group: "Quantitative Finance")
        ]
    )

    // MARK: - Quantitative Biology

    public static let quantitativeBiology = ArXivCategoryGroup(
        id: "q-bio",
        name: "Quantitative Biology",
        iconName: "leaf",
        categories: [
            ArXivCategory(id: "q-bio.BM", name: "Biomolecules", group: "Quantitative Biology"),
            ArXivCategory(id: "q-bio.CB", name: "Cell Behavior", group: "Quantitative Biology"),
            ArXivCategory(id: "q-bio.GN", name: "Genomics", group: "Quantitative Biology"),
            ArXivCategory(id: "q-bio.MN", name: "Molecular Networks", group: "Quantitative Biology"),
            ArXivCategory(id: "q-bio.NC", name: "Neurons and Cognition", group: "Quantitative Biology"),
            ArXivCategory(id: "q-bio.OT", name: "Other Quantitative Biology", group: "Quantitative Biology"),
            ArXivCategory(id: "q-bio.PE", name: "Populations and Evolution", group: "Quantitative Biology"),
            ArXivCategory(id: "q-bio.QM", name: "Quantitative Methods", group: "Quantitative Biology"),
            ArXivCategory(id: "q-bio.SC", name: "Subcellular Processes", group: "Quantitative Biology"),
            ArXivCategory(id: "q-bio.TO", name: "Tissues and Organs", group: "Quantitative Biology")
        ]
    )

    // MARK: - Electrical Engineering

    public static let electricalEngineering = ArXivCategoryGroup(
        id: "eess",
        name: "Electrical Engineering and Systems Science",
        iconName: "bolt",
        categories: [
            ArXivCategory(
                id: "eess.AS",
                name: "Audio and Speech Processing",
                group: "Electrical Engineering",
                description: "Speech recognition, audio signal processing, music"
            ),
            ArXivCategory(
                id: "eess.IV",
                name: "Image and Video Processing",
                group: "Electrical Engineering",
                description: "Image and video coding, enhancement, restoration"
            ),
            ArXivCategory(
                id: "eess.SP",
                name: "Signal Processing",
                group: "Electrical Engineering",
                description: "Signal processing theory and applications"
            ),
            ArXivCategory(
                id: "eess.SY",
                name: "Systems and Control",
                group: "Electrical Engineering",
                description: "Control theory, systems engineering"
            )
        ]
    )

    // MARK: - Economics

    public static let economics = ArXivCategoryGroup(
        id: "econ",
        name: "Economics",
        iconName: "dollarsign.circle",
        categories: [
            ArXivCategory(id: "econ.EM", name: "Econometrics", group: "Economics"),
            ArXivCategory(id: "econ.GN", name: "General Economics", group: "Economics"),
            ArXivCategory(id: "econ.TH", name: "Theoretical Economics", group: "Economics")
        ]
    )
}

// MARK: - Convenience Extensions

public extension ArXivCategory {
    /// The group ID (prefix before the dot)
    var groupID: String {
        if let dotIndex = id.firstIndex(of: ".") {
            return String(id[..<dotIndex])
        }
        // Handle categories without dots (hep-th, gr-qc, etc.)
        return id
    }

    /// Short display name for chips and badges
    var shortName: String {
        id
    }
}

public extension ArXivCategoryGroup {
    /// Find a category within this group by its full ID
    func category(for id: String) -> ArXivCategory? {
        categories.first { $0.id.lowercased() == id.lowercased() }
    }
}
