//
//  ImpressOperationQueue.swift
//  ImpressOperationQueue
//
//  Shared operation queue infrastructure for impress apps.
//
//  This package provides a generic, observable queue-based system for
//  communicating between HTTP automation endpoints and SwiftUI views.
//
//  The queue pattern solves a fundamental problem—HTTP requests arrive
//  on background threads, but UI mutations must happen on MainActor.
//  Rather than each app solving this with NotificationCenter (unreliable)
//  or ad-hoc patterns, this package provides a generic, observable queue.
//

// Re-export all public types
@_exported import Foundation
