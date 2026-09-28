import Foundation
import ImploreVerbsFFI
import ImpressAutomation
import ImpressKit

/// The service owns the public verb surface. This host only gives its Rust
/// implementation access to the same live app state as implore's UI.
private final class NativeImploreHost: ImploreVerbHost, @unchecked Sendable {
    private let router = ImploreHTTPRouter()

    func invoke(method: String, argsJson: String) async -> NativeReply {
        let response = await router.invokeNativeVerb(method: method, argsJSON: argsJson)
        let body: String
        if response.status < 300,
           response.headers["Content-Type"]?.hasPrefix("image/svg+xml") == true,
           let svg = String(data: response.body, encoding: .utf8),
           let data = try? JSONSerialization.data(withJSONObject: ["svg": svg]),
           let json = String(data: data, encoding: .utf8) {
            body = json
        } else {
            body = String(data: response.body, encoding: .utf8)
                ?? "{\"status\":\"error\",\"error\":\"Native response is not UTF-8\"}"
        }
        return NativeReply(status: UInt16(response.status), bodyJson: body)
    }
}

enum ImploreNativeVerbs {
    static func install() {
        if let error = installNativeHost(
            databasePath: SharedWorkspace.databasePath, host: NativeImploreHost()
        ) {
            NSLog("Native implore verb audit store unavailable: %@", error)
            return
        }
        VerbAutomationRoutes.registerDomainDispatcher(services: ["implore-service"]) {
            name, argsJSON, callerJSON in
            let result = await dispatchVerbAsync(
                name: name, argsJson: argsJSON, callerJson: callerJSON)
            return VerbDispatchResponse(status: Int(result.status), bodyJSON: result.bodyJson)
        }
    }
}
