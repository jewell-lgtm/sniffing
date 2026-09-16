import AppKit

enum Apps {
    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Apps with a Dock presence, for the trigger picker.
    static func runningRegular() -> [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { (id: $0, name: app.localizedName ?? $0) } }
    }

    static func name(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = running.localizedName {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let info = Bundle(url: url)?.infoDictionary
        return info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    /// Accepts a bundle identifier or an app name and returns the bundle identifier of an installed app.
    static func resolve(_ query: String) -> String? {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) != nil { return query }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(query) == .orderedSame
        }), let id = running.bundleIdentifier {
            return id
        }
        let dirs = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications", "/System/Applications/Utilities"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(query).app")
            if let id = Bundle(url: url)?.bundleIdentifier { return id }
        }
        return nil
    }
}
