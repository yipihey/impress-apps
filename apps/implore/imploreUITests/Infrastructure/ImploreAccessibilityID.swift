//
//  ImploreAccessibilityID.swift
//  imploreUITests
//
//  Accessibility identifiers for implore UI elements.
//

import Foundation

/// Namespace for accessibility identifiers in implore
enum ImploreAccessibilityID {

    // MARK: - Toolbar

    enum Toolbar {
        static let renderModePicker = "toolbar.renderModePicker"
    }

    // MARK: - Sidebar

    enum Sidebar {
        static let container = "sidebar.container"
        static let datasetName = "sidebar.datasetName"
        static let selectionCount = "sidebar.selectionCount"
        static let editSelectionButton = "sidebar.editSelectionButton"

        static func fieldSelector(_ axis: String) -> String {
            "sidebar.fieldSelector.\(axis)"
        }
    }

    // MARK: - Welcome

    enum Welcome {
        static let container = "welcome.container"
        static let openButton = "welcome.openButton"
    }

    // MARK: - Visualization

    enum Visualization {
        static let container = "visualization.container"
        static let metalView = "visualization.metalView"
        static let marginalsPanel = "visualization.marginalsPanel"
        static let statusBar = "visualization.statusBar"
    }

    // MARK: - Selection Grammar

    enum SelectionGrammar {
        static let container = "selectionGrammar.container"
        static let expressionField = "selectionGrammar.expressionField"
        static let applyButton = "selectionGrammar.applyButton"
        static let cancelButton = "selectionGrammar.cancelButton"
        static let errorMessage = "selectionGrammar.errorMessage"
    }

    // MARK: - Settings

    enum Settings {
        static let container = "settings.container"

        enum Tabs {
            static let general = "settings.tabs.general"
            static let rendering = "settings.tabs.rendering"
            static let colormaps = "settings.tabs.colormaps"
            static let keyboard = "settings.tabs.keyboard"
        }

        enum General {
            static let welcomeToggle = "settings.general.welcomeToggle"
            static let autoLoadToggle = "settings.general.autoLoadToggle"
        }

        enum Rendering {
            static let pointSizeSlider = "settings.rendering.pointSizeSlider"
            static let antialiasingToggle = "settings.rendering.antialiasingToggle"
            static let maxFPSPicker = "settings.rendering.maxFPSPicker"
        }

        enum Colormaps {
            static let colormapPicker = "settings.colormaps.colormapPicker"
            static let reverseToggle = "settings.colormaps.reverseToggle"
            static let colorbarToggle = "settings.colormaps.colorbarToggle"
        }
    }
}
