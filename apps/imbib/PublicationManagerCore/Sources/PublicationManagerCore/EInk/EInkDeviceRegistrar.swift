//
//  EInkDeviceRegistrar.swift
//  PublicationManagerCore
//
//  Re-registers the configured tablet at launch (ADR-025 P7). The device
//  RECORD lives in the store (`imbib/eink-device`), but the legacy
//  `EInkDeviceManager` — which the E-Ink settings pane still gates on
//  (`isAnyDeviceAvailable`) — only knows devices registered in memory, and
//  nothing re-registered them after a relaunch: every launch started with
//  the pane insisting no device existed. This reads the records and adopts
//  each enabled USB device as a `RemarkableDeviceAdapter` over the USB web
//  backend, without probing (reachability is `EInkConnectionMonitor`'s job).
//

import Foundation
import ImpressLogging
import OSLog

@MainActor
public enum EInkDeviceRegistrar {

    /// Register every enabled device record with `EInkDeviceManager`.
    /// Returns the number registered. Reads the store once; probes nothing.
    @discardableResult
    public static func registerConfiguredDevices() async -> Int {
        let devices = RustStoreAdapter.shared.einkDevices().filter(\.enabled)
        guard !devices.isEmpty else { return 0 }

        var registered = 0
        for device in devices {
            guard device.transport == "usb" else {
                Logger.library.infoCapture(
                    "eink.registrar: device \(device.id) uses transport '\(device.transport)', which the engine does not speak; skipped",
                    category: "eink")
                continue
            }
            let backend = RemarkableUSBWebBackend(baseURL: device.baseURL.isEmpty ? nil : device.baseURL)
            let adapter = await RemarkableDeviceAdapter(backend: backend, syncMethod: .usb)
            await EInkDeviceManager.shared.restoreActiveDevice(adapter)
            registered += 1
            Logger.library.infoCapture(
                "eink.registrar: restored '\(device.name)' (\(device.id)) as \(adapter.deviceID)", category: "eink")
        }
        return registered
    }
}
