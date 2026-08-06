//
//  AIDevicePairingSection.swift
//  impart (macOS)
//
//  "Pair a device" for the local AI server (impress-ai-server, port 8787 —
//  SiblingApp.Services.impressAIPort): mints a single-use, 15-minute pairing
//  ticket with the keychain bearer and renders it as a link + QR code.
//
//  Pairing tickets live only in the daemon's memory (by design — a restart
//  invalidates outstanding links), so this panel is how a phone or another
//  browser re-pairs in seconds instead of a debugging session. The ticket
//  rides in the URL FRAGMENT (`#pair=`), which never enters request logs.
//

import CoreImage.CIFilterBuiltins
import SwiftUI

struct AIDevicePairingSection: View {
    /// Origin the link is composed against. Loopback works for a browser on
    /// this Mac; a phone needs the HTTPS front (e.g. a `tailscale serve`
    /// hostname), which the user sets once and we remember.
    @AppStorage("impart.ai.pairingBaseURL") private var baseURL = "http://127.0.0.1:8787"

    @State private var link: String?
    @State private var mintedAt: Date?
    @State private var errorMessage: String?
    @State private var isMinting = false

    private let daemonPort = 8787

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Pair a Device", systemImage: "qrcode")
                .font(.headline)
            Text("Mint a single-use link (valid 15 minutes) that connects a browser to the local AI server. For a phone, set the base URL to your HTTPS front — the secret travels in the URL fragment and is deleted on first use.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Base URL", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Button {
                    Task { await mint() }
                } label: {
                    if isMinting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Create Pairing Link", systemImage: "plus.circle")
                    }
                }
                .disabled(isMinting)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let link {
                HStack(alignment: .top, spacing: 14) {
                    if let qr = Self.qrImage(for: link) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 132, height: 132)
                            .accessibilityLabel("Pairing QR code")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(link)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.middle)
                        HStack(spacing: 8) {
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(link, forType: .string)
                            }
                            if let mintedAt {
                                Text("expires \(mintedAt.addingTimeInterval(15 * 60), style: .time)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("Single use. Mint another link for each additional device.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }

    private func mint() async {
        isMinting = true
        errorMessage = nil
        link = nil
        defer { isMinting = false }

        guard let bearer = Self.keychainBearer() else {
            errorMessage = "Keychain item com.impress.ai-http not found — is the AI server installed? Run scripts/install-services.sh."
            return
        }
        guard let url = URL(string: "http://127.0.0.1:\(daemonPort)/api/pairing-tickets") else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                errorMessage = "AI server answered HTTP \(code) — is impress-ai-server running?"
                return
            }
            guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ticket = body["ticket"] as? String else {
                errorMessage = "AI server response carried no ticket."
                return
            }
            let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
            link = "\(base)/#pair=\(ticket)"
            mintedAt = Date()
        } catch {
            errorMessage = "AI server unreachable: \(error.localizedDescription)"
        }
    }

    /// The daemon bearer from the login keychain — the same item `run.sh`
    /// resolves at daemon launch. First read may show a keychain consent
    /// prompt; "Always Allow" is safe (impart never displays the value).
    private static func keychainBearer() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.impress.ai-http",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let bearer = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              bearer.count >= 24 else {
            return nil
        }
        return bearer
    }

    /// Render the link as a QR code (Core Image, no dependencies).
    private static func qrImage(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

#Preview {
    AIDevicePairingSection()
        .frame(width: 550)
}
