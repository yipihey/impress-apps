//
//  UITestingConfiguration.swift
//  imbib
//
//  Reads launch arguments to configure test state for UI testing.
//

import Foundation
import OSLog
import PublicationManagerCore

enum UITestingConfiguration {
    private static let logger = Logger(subsystem: "com.imbib.app", category: "uitesting")

    /// Whether the app was launched in UI testing mode.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    /// Whether to reset state on launch (for clean-slate tests).
    static var shouldResetState: Bool {
        ProcessInfo.processInfo.arguments.contains("--reset-state")
    }

    /// The test data set to seed, parsed from `--test-data-set=<name>`.
    static var testDataSet: TestDataSet? {
        for arg in ProcessInfo.processInfo.arguments {
            if arg.hasPrefix("--test-data-set="),
               let value = arg.split(separator: "=", maxSplits: 1).last {
                return TestDataSet(rawValue: String(value))
            }
        }
        return nil
    }

    /// Log the current UI testing configuration.
    static func logConfiguration() {
        logger.info("UI Testing mode active. resetState=\(shouldResetState), dataSet=\(testDataSet?.rawValue ?? "none")")
    }

    /// Seed test data based on the `--test-data-set` launch argument.
    @MainActor
    static func seedTestDataIfNeeded() async {
        guard let dataSet = testDataSet else { return }
        logger.info("UI Testing: seeding test data set '\(dataSet.rawValue)'")

        let store = RustStoreAdapter.shared

        switch dataSet {
        case .empty:
            // No data to seed
            break

        case .basic:
            seedBasicDataSet(store: store)

        case .large:
            seedBasicDataSet(store: store)

        case .withPDFs:
            seedBasicDataSet(store: store)

        case .multiLibrary:
            seedMultiLibraryDataSet(store: store)

        case .inboxTriage:
            seedInboxTriageDataSet(store: store)
        }

        logger.info("UI Testing: finished seeding '\(dataSet.rawValue)'")
    }

    // MARK: - Data Sets

    /// 5 papers in one library with varied metadata.
    @MainActor
    private static func seedBasicDataSet(store: RustStoreAdapter) {
        guard let library = store.createLibrary(name: "Test Library") else {
            logger.error("Failed to create test library")
            return
        }
        store.setLibraryDefault(id: library.id)

        let bibtex = """
        @article{Einstein1905,
            author = {Albert Einstein},
            title = {On the Electrodynamics of Moving Bodies},
            journal = {Annalen der Physik},
            year = {1905},
            volume = {17},
            pages = {891--921},
            doi = {10.1002/andp.19053221004}
        }

        @article{Hubble1929,
            author = {Edwin Hubble},
            title = {A Relation between Distance and Radial Velocity among Extra-Galactic Nebulae},
            journal = {Proceedings of the National Academy of Sciences},
            year = {1929},
            volume = {15},
            number = {3},
            pages = {168--173},
            doi = {10.1073/pnas.15.3.168}
        }

        @article{Penzias1965,
            author = {Arno A. Penzias and Robert W. Wilson},
            title = {A Measurement of Excess Antenna Temperature at 4080 Mc/s},
            journal = {The Astrophysical Journal},
            year = {1965},
            volume = {142},
            pages = {419--421},
            doi = {10.1086/148307}
        }

        @book{Hawking1988,
            author = {Stephen Hawking},
            title = {A Brief History of Time},
            publisher = {Bantam Books},
            year = {1988},
            isbn = {978-0553380163}
        }

        @article{Riess1998,
            author = {Adam G. Riess and others},
            title = {Observational Evidence from Supernovae for an Accelerating Universe and a Cosmological Constant},
            journal = {The Astronomical Journal},
            year = {1998},
            volume = {116},
            number = {3},
            pages = {1009--1038},
            doi = {10.1086/300499}
        }
        """

        let ids = store.importBibTeX(bibtex, libraryId: library.id)
        logger.info("Seeded \(ids.count) papers into '\(library.name)'")

        // Mark first paper as read and starred for variety
        if let first = ids.first {
            store.setRead(ids: [first], read: true)
            store.setStarred(ids: [first], starred: true)
        }
    }

    /// 3 libraries with collections, ~15 papers total.
    @MainActor
    private static func seedMultiLibraryDataSet(store: RustStoreAdapter) {
        // Library 1: Cosmology
        guard let cosmoLib = store.createLibrary(name: "Cosmology") else { return }
        store.setLibraryDefault(id: cosmoLib.id)

        let cosmoBibtex = """
        @article{Planck2020,
            author = {{Planck Collaboration}},
            title = {Planck 2018 results. VI. Cosmological parameters},
            journal = {Astronomy \\& Astrophysics},
            year = {2020},
            volume = {641},
            pages = {A6},
            doi = {10.1051/0004-6361/201833910}
        }

        @article{Riess2019,
            author = {Adam G. Riess and others},
            title = {Large Magellanic Cloud Cepheid Standards Provide a 1\\% Foundation for the Determination of the Hubble Constant},
            journal = {The Astrophysical Journal},
            year = {2019},
            volume = {876},
            number = {1},
            pages = {85},
            doi = {10.3847/1538-4357/ab1422}
        }

        @article{Perlmutter1999,
            author = {S. Perlmutter and others},
            title = {Measurements of Omega and Lambda from 42 High-Redshift Supernovae},
            journal = {The Astrophysical Journal},
            year = {1999},
            volume = {517},
            number = {2},
            pages = {565--586},
            doi = {10.1086/307221}
        }

        @article{DESI2024,
            author = {{DESI Collaboration}},
            title = {DESI 2024 VI: Cosmological Constraints from the Measurements of Baryon Acoustic Oscillations},
            journal = {arXiv preprint},
            year = {2024},
            eprint = {2404.03002},
            archivePrefix = {arXiv}
        }

        @article{Weinberg2013,
            author = {David H. Weinberg and others},
            title = {Observational Probes of Cosmic Acceleration},
            journal = {Physics Reports},
            year = {2013},
            volume = {530},
            number = {2},
            pages = {87--255},
            doi = {10.1016/j.physrep.2013.05.001}
        }
        """
        let cosmoIds = store.importBibTeX(cosmoBibtex, libraryId: cosmoLib.id)
        logger.info("Seeded \(cosmoIds.count) papers into Cosmology")

        // Create a collection in Cosmology
        if let collection = store.createCollection(name: "Dark Energy", libraryId: cosmoLib.id) {
            store.addToCollection(publicationIds: Array(cosmoIds.prefix(3)), collectionId: collection.id)
        }

        // Library 2: Gravitational Waves
        guard let gwLib = store.createLibrary(name: "Gravitational Waves") else { return }

        let gwBibtex = """
        @article{Abbott2016,
            author = {{LIGO Scientific Collaboration} and {Virgo Collaboration}},
            title = {Observation of Gravitational Waves from a Binary Black Hole Merger},
            journal = {Physical Review Letters},
            year = {2016},
            volume = {116},
            number = {6},
            pages = {061102},
            doi = {10.1103/PhysRevLett.116.061102}
        }

        @article{Abbott2017,
            author = {{LIGO Scientific Collaboration} and {Virgo Collaboration}},
            title = {GW170817: Observation of Gravitational Waves from a Binary Neutron Star Inspiral},
            journal = {Physical Review Letters},
            year = {2017},
            volume = {119},
            number = {16},
            pages = {161101},
            doi = {10.1103/PhysRevLett.119.161101}
        }

        @article{Einstein1916GW,
            author = {Albert Einstein},
            title = {Approximative Integration of the Field Equations of Gravitation},
            journal = {Sitzungsberichte der Preussischen Akademie der Wissenschaften},
            year = {1916},
            pages = {688--696}
        }

        @article{Taylor1982,
            author = {J. H. Taylor and J. M. Weisberg},
            title = {A new test of general relativity - Gravitational radiation and the binary pulsar PSR 1913+16},
            journal = {The Astrophysical Journal},
            year = {1982},
            volume = {253},
            pages = {908--920},
            doi = {10.1086/159690}
        }

        @article{Sathyaprakash2009,
            author = {B. S. Sathyaprakash and Bernard F. Schutz},
            title = {Physics, Astrophysics and Cosmology with Gravitational Waves},
            journal = {Living Reviews in Relativity},
            year = {2009},
            volume = {12},
            number = {1},
            pages = {2},
            doi = {10.12942/lrr-2009-2}
        }
        """
        let gwIds = store.importBibTeX(gwBibtex, libraryId: gwLib.id)
        logger.info("Seeded \(gwIds.count) papers into Gravitational Waves")

        // Library 3: Exoplanets
        guard let exoLib = store.createLibrary(name: "Exoplanets") else { return }

        let exoBibtex = """
        @article{Mayor1995,
            author = {Michel Mayor and Didier Queloz},
            title = {A Jupiter-mass companion to a solar-type star},
            journal = {Nature},
            year = {1995},
            volume = {378},
            pages = {355--359},
            doi = {10.1038/378355a0}
        }

        @article{Borucki2010,
            author = {William J. Borucki and others},
            title = {Kepler Planet-Detection Mission: Introduction and First Results},
            journal = {Science},
            year = {2010},
            volume = {327},
            number = {5968},
            pages = {977--980},
            doi = {10.1126/science.1185402}
        }

        @article{Gillon2017,
            author = {Micha{\\\"e}l Gillon and others},
            title = {Seven temperate terrestrial planets around the nearby ultracool dwarf star TRAPPIST-1},
            journal = {Nature},
            year = {2017},
            volume = {542},
            pages = {456--460},
            doi = {10.1038/nature21360}
        }

        @article{Winn2015,
            author = {Joshua N. Winn and Daniel C. Fabrycky},
            title = {The Occurrence and Architecture of Exoplanetary Systems},
            journal = {Annual Review of Astronomy and Astrophysics},
            year = {2015},
            volume = {53},
            pages = {409--447},
            doi = {10.1146/annurev-astro-082214-122246}
        }

        @article{JWST2023,
            author = {{JWST Transiting Exoplanet Community}},
            title = {The JWST Early Release Science Program for Transiting Exoplanet Atmospheres},
            journal = {Nature},
            year = {2023},
            volume = {614},
            pages = {649--652},
            doi = {10.1038/s41586-022-05269-w}
        }
        """
        let exoIds = store.importBibTeX(exoBibtex, libraryId: exoLib.id)
        logger.info("Seeded \(exoIds.count) papers into Exoplanets")

        // Create a collection in Exoplanets
        if let collection = store.createCollection(name: "Habitable Zones", libraryId: exoLib.id) {
            store.addToCollection(publicationIds: Array(exoIds.suffix(2)), collectionId: collection.id)
        }
    }

    /// Inbox with 10 papers for triage testing.
    @MainActor
    private static func seedInboxTriageDataSet(store: RustStoreAdapter) {
        // Create the Save and Dismissed libraries
        guard let saveLib = store.createLibrary(name: "Save") else { return }
        store.setLibraryDefault(id: saveLib.id)
        _ = store.createLibrary(name: "Dismissed")

        // Create an inbox library
        guard let inboxLib = store.createInboxLibrary(name: "Inbox") else { return }

        let inboxBibtex = """
        @article{Triage01,
            author = {Author One},
            title = {New Results on Dark Matter Detection},
            journal = {Physical Review D},
            year = {2024},
            volume = {109},
            pages = {012345},
            doi = {10.1103/PhysRevD.109.012345},
            abstract = {We present new results from a direct dark matter detection experiment.}
        }

        @article{Triage02,
            author = {Author Two and Author Three},
            title = {Machine Learning in Astrophysics: A Review},
            journal = {Annual Review of Astronomy and Astrophysics},
            year = {2024},
            volume = {62},
            pages = {100--150},
            abstract = {A comprehensive review of machine learning applications in astrophysics.}
        }

        @article{Triage03,
            author = {Author Four},
            title = {Fast Radio Bursts: Origins and Implications},
            journal = {Nature Astronomy},
            year = {2024},
            volume = {8},
            pages = {200--210},
            abstract = {Recent observations shed light on the origins of fast radio bursts.}
        }

        @article{Triage04,
            author = {Author Five and Author Six},
            title = {The Epoch of Reionization: New Constraints},
            journal = {The Astrophysical Journal},
            year = {2024},
            volume = {960},
            pages = {45},
            abstract = {We present new constraints on the epoch of reionization from 21cm observations.}
        }

        @article{Triage05,
            author = {Author Seven},
            title = {Primordial Gravitational Waves and Inflation},
            journal = {Physical Review Letters},
            year = {2024},
            volume = {132},
            pages = {221301},
            abstract = {Detection prospects for primordial gravitational waves from cosmic inflation.}
        }

        @article{Triage06,
            author = {Author Eight and Author Nine},
            title = {Galaxy Cluster Mass Functions at High Redshift},
            journal = {Monthly Notices of the Royal Astronomical Society},
            year = {2024},
            volume = {528},
            pages = {1000--1015},
            abstract = {We measure galaxy cluster mass functions out to redshift z=2.}
        }

        @article{Triage07,
            author = {Author Ten},
            title = {Neutrino Mass Constraints from Cosmology},
            journal = {Journal of Cosmology and Astroparticle Physics},
            year = {2024},
            volume = {2024},
            number = {3},
            pages = {030},
            abstract = {Updated neutrino mass constraints combining CMB and BAO data.}
        }

        @article{Triage08,
            author = {Author Eleven and Author Twelve},
            title = {The Stellar Initial Mass Function: Universality and Variations},
            journal = {The Astrophysical Journal Supplement Series},
            year = {2024},
            volume = {270},
            pages = {15},
            abstract = {We examine evidence for variations in the stellar initial mass function.}
        }

        @article{Triage09,
            author = {Author Thirteen},
            title = {Active Galactic Nuclei Feedback in Galaxy Formation},
            journal = {Astronomy \\& Astrophysics},
            year = {2024},
            volume = {685},
            pages = {A100},
            abstract = {Simulations of AGN feedback and its role in quenching star formation.}
        }

        @article{Triage10,
            author = {Author Fourteen and Author Fifteen},
            title = {Tidal Disruption Events: A Growing Sample},
            journal = {The Astrophysical Journal Letters},
            year = {2024},
            volume = {964},
            pages = {L10},
            abstract = {We present a catalog of newly discovered tidal disruption events.}
        }
        """

        let ids = store.importBibTeX(inboxBibtex, libraryId: inboxLib.id)
        logger.info("Seeded \(ids.count) papers into Inbox for triage testing")
    }
}

// MARK: - Test Data Set

enum TestDataSet: String {
    case empty = "empty"
    case basic = "basic"
    case large = "large"
    case withPDFs = "with-pdfs"
    case multiLibrary = "multi-library"
    case inboxTriage = "inbox-triage"
}
