import Combine
import SwiftUI

/// Countdown to the moment this build stops launching and has to be
/// re-installed from Xcode. Sits in the Home toolbar; tap for the exact date.
struct InstallExpiryBadge: View {
    @State private var now = Date()
    @State private var isDetailPresented = false

    // Re-rendering once a minute is enough for a countdown shown in days and
    // hours, and keeps the badge honest if the app sits open past midnight.
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var remaining: TimeInterval? {
        InstallExpiry.timeRemaining(asOf: now)
    }

    var body: some View {
        if let remaining {
            Button {
                isDetailPresented = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: icon(for: remaining))
                    Text(Self.compact(remaining))
                        .monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(tint(for: remaining).opacity(0.15))
                .foregroundStyle(tint(for: remaining))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .onReceive(tick) { now = $0 }
            .sheet(isPresented: $isDetailPresented) {
                InstallExpiryDetail(remaining: remaining)
            }
        }
    }

    private func tint(for remaining: TimeInterval) -> Color {
        if InstallExpiry.isLongLivedProfile { return .secondary }
        switch remaining {
        case ..<(24 * 3600): return .red
        case ..<(2 * 24 * 3600): return .orange
        default: return .secondary
        }
    }

    private func icon(for remaining: TimeInterval) -> String {
        remaining < 24 * 3600 ? "exclamationmark.triangle.fill" : "clock"
    }

    /// "6d 4h" / "4h 12m" / "38m" — whichever two units actually carry
    /// information, so the badge stays narrow enough for a toolbar.
    static func compact(_ remaining: TimeInterval) -> String {
        let total = Int(remaining)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

private struct InstallExpiryDetail: View {
    let remaining: TimeInterval
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "iphone.gen3.badge.exclamationmark")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)

                Text(InstallExpiryBadge.compact(remaining))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Text("until PulseStream needs reinstalling")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                if let expiry = InstallExpiry.expirationDate {
                    Text(expiry, format: .dateTime.weekday(.wide).day().month().hour().minute())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 40)
            .navigationTitle("Install Expiry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var explanation: String {
        InstallExpiry.isLongLivedProfile
        ? "This build was signed with a paid developer account, so it runs for a full year before the signing certificate expires."
        : "Apps signed with a free Apple ID stop launching after 7 days. Rebuild and run from Xcode onto your phone to reset the clock — your listening history lives on the server, so nothing is lost."
    }
}
