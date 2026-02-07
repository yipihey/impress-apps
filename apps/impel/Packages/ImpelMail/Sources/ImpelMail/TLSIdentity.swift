//
//  TLSIdentity.swift
//  ImpelMail
//
//  Loads the bundled self-signed TLS identity for localhost servers.
//

import Foundation
import Security
import Network
import OSLog

/// Provides a TLS identity for the localhost SMTP/IMAP servers.
enum TLSIdentity {

    private static let logger = Logger(subsystem: "com.impress.impel", category: "tls")

    /// Load the bundled PKCS12 identity for localhost TLS.
    static func loadIdentity() -> SecIdentity? {
        guard let url = Bundle.module.url(forResource: "localhost", withExtension: "p12") else {
            logger.error("localhost.p12 not found in bundle")
            return nil
        }

        guard let p12Data = try? Data(contentsOf: url) else {
            logger.error("Failed to read localhost.p12")
            return nil
        }

        let options: [String: Any] = [kSecImportExportPassphrase as String: "impress"]
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identity = first[kSecImportItemIdentity as String] else {
            logger.error("SecPKCS12Import failed: \(status)")
            return nil
        }

        // swiftlint:disable:next force_cast
        let secIdentity = identity as! SecIdentity
        logger.info("Loaded TLS identity for localhost")
        return secIdentity
    }

    /// Create NWParameters with TLS using the bundled localhost identity.
    static func tlsParameters() -> NWParameters? {
        guard let identity = loadIdentity() else { return nil }

        let tlsOptions = NWProtocolTLS.Options()
        let secOptions = tlsOptions.securityProtocolOptions

        guard let secIdentityRef = sec_identity_create(identity) else {
            logger.error("sec_identity_create failed")
            return nil
        }

        sec_protocol_options_set_local_identity(secOptions, secIdentityRef)
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv12)

        return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    }
}
