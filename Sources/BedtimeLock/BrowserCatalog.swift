import AppKit

enum BrowserInteractionMode {
    case safari
    case chromium
    case accessibility
}

enum BrowserCatalog {
    static func interactionMode(
        for app: NSRunningApplication
    ) -> BrowserInteractionMode? {
        let bundle = (
            app.bundleIdentifier ?? ""
        ).lowercased()
        let name = (
            app.localizedName ?? ""
        ).lowercased()

        guard !bundle.contains("iina"),
              !name.contains("iina")
        else {
            return nil
        }

        if bundle == "com.apple.safari"
            || bundle == "com.apple.safaritechnologypreview" {
            return .safari
        }

        if isChromiumBundle(bundle)
            || isChromiumName(name) {
            return .chromium
        }

        if isAccessibilityBrowserBundle(bundle)
            || isAccessibilityBrowserName(name) {
            return .accessibility
        }

        // Future/less-common browsers still get the generic Accessibility
        // path when their app identity clearly describes a browser.
        if bundle.contains("browser")
            || name.hasSuffix(" browser")
            || name.contains(" browser ") {
            return .accessibility
        }

        return nil
    }

    private static func isChromiumBundle(
        _ bundle: String
    ) -> Bool {
        let prefixes = [
            "com.google.chrome",
            "com.brave.browser",
            "com.microsoft.edgemac",
            "com.vivaldi.vivaldi",
            "com.operasoftware.opera",
            "org.chromium.chromium"
        ]

        if prefixes.contains(
            where: bundle.hasPrefix
        ) {
            return true
        }

        let exact = [
            "company.thebrowser.browser",
            "company.thebrowser.dia",
            "net.imput.helium",
            "com.meetsidekick.browser",
            "ru.yandex.desktop.yandex-browser",
            "com.sigmaos.sigmaos.macos"
        ]

        return exact.contains(bundle)
    }

    private static func isAccessibilityBrowserBundle(
        _ bundle: String
    ) -> Bool {
        let prefixes = [
            "org.mozilla.firefox"
        ]

        if prefixes.contains(
            where: bundle.hasPrefix
        ) {
            return true
        }

        let exact = [
            "app.zen-browser.zen",
            "io.gitlab.librewolf-community",
            "net.waterfox.waterfox",
            "one.ablaze.floorp",
            "com.duckduckgo.macos.browser",
            "com.kagi.kagimacos"
        ]

        return exact.contains(bundle)
    }

    private static func isChromiumName(
        _ name: String
    ) -> Bool {
        let names = [
            "google chrome",
            "chrome canary",
            "chromium",
            "brave browser",
            "microsoft edge",
            "arc",
            "dia",
            "vivaldi",
            "opera",
            "opera gx",
            "helium",
            "thorium",
            "sidekick",
            "yandex",
            "sigmaos",
            "wavebox",
            "ghost browser"
        ]

        return names.contains {
            name == $0 || name.contains($0)
        }
    }

    private static func isAccessibilityBrowserName(
        _ name: String
    ) -> Bool {
        let names = [
            "firefox",
            "firefox developer edition",
            "firefox nightly",
            "zen",
            "librewolf",
            "waterfox",
            "floorp",
            "duckduckgo",
            "orion",
            "min"
        ]

        return names.contains {
            name == $0 || name.contains($0)
        }
    }
}
