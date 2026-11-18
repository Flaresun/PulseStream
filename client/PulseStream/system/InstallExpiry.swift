import Foundation

/// How long this build has left before iOS stops launching it and it has to be
/// re-installed from Xcode.
///
/// The limit comes from the provisioning profile embedded in the app bundle: a
/// free (personal team) profile is good for 7 days, a paid Apple Developer
/// Program profile for a year. Reading the profile's own expiry rather than
/// assuming 7 days means this keeps telling the truth after the account is
/// upgraded, with no code change.
enum InstallExpiry {

    /// Assumed lifetime when no profile can be read — matches Apple's free
    /// personal-team limit, which is the case this is here for.
    private static let freeProvisioningLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// The moment this install stops working, or nil if it can't be determined.
    static let expirationDate: Date? = provisionedExpirationDate() ?? estimatedExpirationDate()

    static func timeRemaining(asOf now: Date = Date()) -> TimeInterval? {
        guard let expirationDate else { return nil }
        return max(0, expirationDate.timeIntervalSince(now))
    }

    /// `true` once the profile is a long one — i.e. a paid account, where the
    /// countdown stops being something worth watching.
    static var isLongLivedProfile: Bool {
        guard let expirationDate else { return false }
        return expirationDate.timeIntervalSince(installDate ?? Date()) > 30 * 24 * 60 * 60
    }

    // MARK: - Sources

    /// Parses `ExpirationDate` out of the bundle's embedded.mobileprovision.
    ///
    /// The file is a CMS envelope wrapping an XML plist. Verifying the
    /// signature needs the Security framework and buys us nothing here — the
    /// payload is read-only, local, and only drives a countdown label — so the
    /// plist is simply sliced out of the blob by its delimiters.
    private static func provisionedExpirationDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8))
        else { return nil }

        let payload = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(
            from: payload, options: [], format: nil
        ) as? [String: Any] else { return nil }

        return plist["ExpirationDate"] as? Date
    }

    /// Fallback for builds with no embedded profile (the simulator, mainly):
    /// assume the free 7 days starting from when the bundle was installed.
    private static func estimatedExpirationDate() -> Date? {
        installDate.map { $0.addingTimeInterval(freeProvisioningLifetime) }
    }

    /// When this copy of the app landed on the device. The bundle's own
    /// creation date is rewritten on each install, which is exactly the event
    /// that resets the 7 days.
    private static let installDate: Date? = {
        guard let path = Bundle.main.executableURL?.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        else { return nil }
        return attributes[.creationDate] as? Date
    }()
}
