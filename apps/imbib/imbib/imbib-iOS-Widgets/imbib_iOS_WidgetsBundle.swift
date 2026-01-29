//
//  imbib_iOS_WidgetsBundle.swift
//  imbib-iOS-Widgets
//
//  Created by Claude on 2026-01-29.
//

import WidgetKit
import SwiftUI

@main
struct imbib_iOS_WidgetsBundle: WidgetBundle {
    var body: some Widget {
        InboxCountWidget()
        PaperOfDayWidget()
        RecentPapersWidget()
    }
}
