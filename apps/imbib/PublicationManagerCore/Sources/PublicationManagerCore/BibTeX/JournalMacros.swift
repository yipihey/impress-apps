//
//  JournalMacros.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation

/// Expands AASTeX journal macro abbreviations to full journal names.
///
/// Based on the standard AASTeX journal macros from the AAS (American Astronomical Society).
/// See: https://ui.adsabs.harvard.edu/help/actions/journal-macros
public enum JournalMacros {

    // MARK: - Macro Definitions

    /// Dictionary mapping journal macros to full names.
    /// Keys are lowercase without the backslash (e.g., "apj" not "\\apj").
    public static let macros: [String: String] = [
        // Major Astronomical Journals
        "aj": "Astronomical Journal",
        "apj": "Astrophysical Journal",
        "apjl": "Astrophysical Journal, Letters",
        "apjlett": "Astrophysical Journal, Letters",
        "apjs": "Astrophysical Journal, Supplement",
        "apjsupp": "Astrophysical Journal, Supplement",
        "mnras": "Monthly Notices of the Royal Astronomical Society",
        "aap": "Astronomy and Astrophysics",
        "astap": "Astronomy and Astrophysics",
        "aaps": "Astronomy and Astrophysics, Supplement",
        "pasp": "Publications of the Astronomical Society of the Pacific",
        "pasj": "Publications of the Astronomical Society of Japan",
        "pasa": "Publications of the Astronomical Society of Australia",

        // Review Journals
        "araa": "Annual Review of Astronomy and Astrophysics",
        "aapr": "Astronomy and Astrophysics Reviews",

        // Society Publications
        "baas": "Bulletin of the American Astronomical Society",
        "memras": "Memoirs of the Royal Astronomical Society",
        "qjras": "Quarterly Journal of the Royal Astronomical Society",
        "jrasc": "Journal of the Royal Astronomical Society of Canada",
        "memsai": "Memorie della Societa Astronomica Italiana",
        "iaucirc": "IAU Circulars",

        // Specialized Fields
        "icarus": "Icarus",
        "psj": "Planetary Science Journal",
        "solphys": "Solar Physics",
        "jcap": "Journal of Cosmology and Astroparticle Physics",
        "planss": "Planetary and Space Science",
        "grl": "Geophysical Research Letters",
        "jgr": "Journal of Geophysical Research",

        // Physics Journals
        "prl": "Physical Review Letters",
        "pra": "Physical Review A",
        "prb": "Physical Review B",
        "prc": "Physical Review C",
        "prd": "Physical Review D",
        "pre": "Physical Review E",
        "physrep": "Physics Reports",
        "physscr": "Physica Scripta",
        "nphysa": "Nuclear Physics A",

        // Optics and Spectroscopy
        "ao": "Applied Optics",
        "applopt": "Applied Optics",
        "jqsrt": "Journal of Quantitative Spectroscopy and Radiative Transfer",
        "procspie": "Proceedings of the SPIE",

        // General Science
        "nat": "Nature",
        "sci": "Science",
        "ssr": "Space Science Reviews",
        "apss": "Astrophysics and Space Science",

        // Regional Journals
        "actaa": "Acta Astronomica",
        "azh": "Astronomicheskii Zhurnal",
        "sovast": "Soviet Astronomy",
        "caa": "Chinese Astronomy and Astrophysics",
        "cjaa": "Chinese Journal of Astronomy and Astrophysics",
        "rmxaa": "Revista Mexicana de Astronomia y Astrofisica",
        "bac": "Bulletin of the Astronomical Institutes of Czechoslovakia",
        "bain": "Bulletin Astronomical Institute of the Netherlands",
        "zap": "Zeitschrift fuer Astrophysik",

        // Other
        "na": "New Astronomy",
        "nar": "New Astronomy Review",
        "skytel": "Sky & Telescope",
        "aplett": "Astrophysics Letters",
        "apspr": "Astrophysics Space Physics Research",
        "fcp": "Fundamental Cosmic Physics",
        "gca": "Geochimica et Cosmochimica Acta",
        "jcp": "Journal of Chemical Physics",
    ]

    // MARK: - Expansion

    /// Expands a journal field value to its full name.
    ///
    /// This handles multiple formats:
    /// - LaTeX macro: `\apj` → "Astrophysical Journal"
    /// - Bare macro: `apj` → "Astrophysical Journal"
    /// - Already full name: Returns unchanged
    ///
    /// - Parameter value: The journal field value from BibTeX
    /// - Returns: The expanded journal name, or the original if not a macro
    public static func expand(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        // Check for LaTeX macro format: \apj
        if trimmed.hasPrefix("\\") {
            let macroName = String(trimmed.dropFirst()).lowercased()
            if let fullName = macros[macroName] {
                return fullName
            }
        }

        // Check for bare macro name
        let lowercased = trimmed.lowercased()
        if let fullName = macros[lowercased] {
            return fullName
        }

        // Not a macro - return original
        return value
    }

    /// Checks if a string is a journal macro.
    public static func isMacro(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        // Check LaTeX format
        if trimmed.hasPrefix("\\") {
            let macroName = String(trimmed.dropFirst()).lowercased()
            return macros[macroName] != nil
        }

        // Check bare format
        return macros[trimmed.lowercased()] != nil
    }
}
