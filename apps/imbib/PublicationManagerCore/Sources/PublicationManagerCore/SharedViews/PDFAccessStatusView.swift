//
//  PDFAccessStatusView.swift
//  PublicationManagerCore
//
//  View component for displaying PDF access status.
//

import SwiftUI

// MARK: - PDF Access Status View

/// View that displays the current PDF access status with appropriate icons and messages.
public struct PDFAccessStatusView: View {
    public let status: PDFAccessStatus
    public var onBrowserAction: ((URL) -> Void)?

    public init(status: PDFAccessStatus, onBrowserAction: ((URL) -> Void)? = nil) {
        self.status = status
        self.onBrowserAction = onBrowserAction
    }

    public var body: some View {
        HStack(spacing: 8) {
            statusIcon
            statusText
            Spacer()
            actionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(statusBackgroundColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .requiresProxy:
            Image(systemName: "lock.shield")
                .foregroundStyle(.blue)
        case .captchaBlocked:
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
        case .paywalled:
            Image(systemName: "lock.fill")
                .foregroundStyle(.red)
        case .unavailable:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView()
                .controlSize(.small)
        }
    }

    // MARK: - Status Text

    @ViewBuilder
    private var statusText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(statusTitle)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(status.displayDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        switch status {
        case .available:
            return "PDF Available"
        case .requiresProxy:
            return "Proxy Required"
        case .captchaBlocked:
            return "Verification Required"
        case .paywalled:
            return "Subscription Required"
        case .unavailable:
            return "Not Available"
        case .checking:
            return "Checking..."
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .captchaBlocked(_, let url):
            Button("Open in Browser") {
                onBrowserAction?(url)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .paywalled(_, let url):
            Button("Open in Browser") {
                onBrowserAction?(url)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        default:
            EmptyView()
        }
    }

    // MARK: - Background Color

    private var statusBackgroundColor: Color {
        switch status {
        case .available:
            return .green
        case .requiresProxy:
            return .blue
        case .captchaBlocked:
            return .orange
        case .paywalled:
            return .red
        case .unavailable:
            return .gray
        case .checking:
            return .gray
        }
    }
}

// MARK: - Compact Status Badge

/// Compact badge showing PDF access status.
public struct PDFAccessStatusBadge: View {
    public let status: PDFAccessStatus

    public init(status: PDFAccessStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 4) {
            statusIcon
            Text(badgeText)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.15))
        .foregroundStyle(statusColor)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .available:
            Image(systemName: "checkmark.circle.fill")
        case .requiresProxy:
            Image(systemName: "lock.shield")
        case .captchaBlocked:
            Image(systemName: "exclamationmark.shield.fill")
        case .paywalled:
            Image(systemName: "lock.fill")
        case .unavailable:
            Image(systemName: "xmark.circle")
        case .checking:
            ProgressView()
                .controlSize(.mini)
        }
    }

    private var badgeText: String {
        switch status {
        case .available:
            return "Available"
        case .requiresProxy:
            return "Proxy"
        case .captchaBlocked:
            return "CAPTCHA"
        case .paywalled:
            return "Paywall"
        case .unavailable:
            return "Unavailable"
        case .checking:
            return "Checking"
        }
    }

    private var statusColor: Color {
        switch status {
        case .available:
            return .green
        case .requiresProxy:
            return .blue
        case .captchaBlocked:
            return .orange
        case .paywalled:
            return .red
        case .unavailable:
            return .secondary
        case .checking:
            return .secondary
        }
    }
}

// MARK: - Preview

#if DEBUG
struct PDFAccessStatusView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            PDFAccessStatusView(
                status: .available(source: ResolvedPDFSource(
                    type: .arxiv,
                    url: URL(string: "https://arxiv.org/pdf/2311.12345.pdf")!
                ))
            )

            PDFAccessStatusView(
                status: .requiresProxy(source: ResolvedPDFSource(
                    type: .publisher,
                    url: URL(string: "https://example.com/pdf")!,
                    name: "Nature"
                ))
            )

            PDFAccessStatusView(
                status: .captchaBlocked(
                    publisher: "Science",
                    browserURL: URL(string: "https://science.org")!
                )
            )

            PDFAccessStatusView(
                status: .paywalled(
                    publisher: "Elsevier",
                    browserURL: URL(string: "https://doi.org/10.1016/example")!
                )
            )

            PDFAccessStatusView(status: .unavailable(reason: .noPDFFound))

            PDFAccessStatusView(status: .checking)

            Divider()

            Text("Compact Badges:")
                .font(.headline)

            HStack {
                PDFAccessStatusBadge(status: .available(source: ResolvedPDFSource(type: .arxiv, url: URL(string: "https://arxiv.org")!)))
                PDFAccessStatusBadge(status: .requiresProxy(source: ResolvedPDFSource(type: .publisher, url: URL(string: "https://example.com")!)))
                PDFAccessStatusBadge(status: .captchaBlocked(publisher: "Science", browserURL: URL(string: "https://science.org")!))
            }
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
#endif
