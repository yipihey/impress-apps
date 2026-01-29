//
//  imbibWidgetsBundle.swift
//  imbib-Widgets
//
//  Created by Claude on 2026-01-29.
//

import WidgetKit
import SwiftUI

@main
struct imbibWidgetsBundle: WidgetBundle {
    var body: some Widget {
        InboxCountWidget()
        PaperOfDayWidget()
        RecentPapersWidget()
    }
}
