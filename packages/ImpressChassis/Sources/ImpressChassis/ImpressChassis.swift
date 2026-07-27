//
//  ImpressChassis.swift
//
//  The chassis façade: today the shared GUI chassis physically lives in
//  PublicationManagerCore (TabContentView, AppShellConfiguration,
//  RecordKindDescriptor, CustomSurfaceRegistry, the triage layer). Importing
//  ImpressChassis re-exports it, so shells written against this name survive
//  the later physical extraction unchanged.
//

@_exported import PublicationManagerCore
