import Foundation
import Darwin
import DeadlockShared

/// Root-only website enforcement.
///
/// deadlock owns only its two marked sections of /etc/hosts:
/// - strict adult/SafeSearch protection
/// - ordinary distracting-site blocking
///
/// The file is rewritten only when policy changes, a managed section is
/// tampered with, or strict SafeSearch mappings are refreshed.
final class WebProtection {
    struct ManagedState: Codable {
        var adultBlock: String
        var lastResolvedAt: Date
        var youtubeSafeMappingSkipped: Bool?
    }

    private let hostsPath = "/etc/hosts"
    private let adultBegin = "# BEGIN DEADLOCK ADULT PROTECTION"
    private let adultEnd = "# END DEADLOCK ADULT PROTECTION"
    private let distractionBegin = "# BEGIN DEADLOCK DISTRACTIONS"
    private let distractionEnd = "# END DEADLOCK DISTRACTIONS"
    private let legacyBegin = "# BEGIN DEADLOCK WEB PROTECTION"
    private let legacyEnd = "# END DEADLOCK WEB PROTECTION"
    private let safeHostRefreshInterval: TimeInterval = 6 * 3600
    private let adultSourceURL =
        "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn-only/hosts"
    private let adultCachePath =
        DeadlockPaths.support + "/adult-upstream-hosts.txt"
    private let minimumAdultSourceDomains = 10_000
    private let maximumAdultSourceDomains = 250_000

    private let socialSourceURL =
        "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/social-only/hosts"
    private let socialCachePath =
        DeadlockPaths.support + "/social-upstream-hosts.txt"
    private let minimumSocialSourceDomains = 500
    private let maximumSocialSourceDomains = 25_000
    private let socialImportAllowRoots = [
        // Imported social lists never get to decide policy for explicit
        // communication/productivity exceptions.
        "discord.com",
        "discord.gg",
        // Shared Meta backends and Instagram are excluded from the imported
        // social list because they are allowed for work/productivity.
        "instagram.com",
        "cdninstagram.com",
        "fbcdn.net",
        "fbcdn.com",
        "fbsbx.com",
        "facebook.net",
        "facebook.com",
        "slack.com",
        "slack-edge.com",
        "slack-files.com",
        "teams.microsoft.com",
        "teams.live.com",
        "skype.com",
        "zoom.us",
        "zoom.com",
        "meet.google.com",
        "chat.google.com"
    ]

    private let adultDomains = [
        "pornhub.com",
        "xvideos.com",
        "xnxx.com",
        "redtube.com",
        "xhamster.com",
        "youporn.com",
        "tube8.com",
        "spankbang.com",
        "eporner.com",
        "beeg.com",
        "tnaflix.com",
        "hqporner.com",
        "drtuber.com",
        "onlyfans.com",
        "fapello.com",
        "rule34.xxx",
        "rule34video.com",
        "rule34.us",
        "rule34.paheal.net",
        "paheal.net",
        "e621.net",
        "e926.net",
        "gelbooru.com",
        "danbooru.donmai.us",
        "konachan.com",
        "konachan.net",
        "yande.re",
        "hanime.tv",
        "nhentai.net",
        "hentaihaven.xxx",
        "hentaifox.com",
        "hentai2read.com",
        "simply-hentai.com",
        "fakku.net",
        // Non-adult site explicitly requested as a permanent hard block.
        "deviantart.com",
        "deviantart.net",
        "sta.sh"
    ]

    func apply(
        pornEnabled: Bool,
        distractionsEnabled: Bool,
        distractionDomains: [String],
        forceRefresh: Bool = false,
        now: Date = Date()
    ) throws -> Date? {
        let normalizedDistractions = distractionsEnabled
            ? PolicyEngine.normalizedDomains(distractionDomains)
            : []
        let youtubeBrowserOnly = normalizedDistractions.contains(where: isBrowserOnlyDomain)

        let original = try String(contentsOfFile: hostsPath, encoding: .utf8)
        var unmanaged = stripSection(original, begin: adultBegin, end: adultEnd)
        unmanaged = stripSection(unmanaged, begin: distractionBegin, end: distractionEnd)
        unmanaged = stripSection(unmanaged, begin: legacyBegin, end: legacyEnd)

        var blocks: [String] = []
        var nextRefresh: Date?

        if pornEnabled {
            let oldState = loadState()
            let oldSection = section(in: original, begin: adultBegin, end: adultEnd)
            let canReuse = !forceRefresh
                && oldState != nil
                && oldState!.lastResolvedAt.addingTimeInterval(safeHostRefreshInterval) > now
                && oldSection == oldState!.adultBlock
                && (oldState!.youtubeSafeMappingSkipped ?? false) == youtubeBrowserOnly

            let state: ManagedState
            if canReuse, let oldState {
                state = oldState
            } else {
                refreshExternalAdultList()
                state = ManagedState(
                    adultBlock: buildAdultBlock(skipYouTubeSafeMapping: youtubeBrowserOnly),
                    lastResolvedAt: now,
                    youtubeSafeMappingSkipped: youtubeBrowserOnly
                )
            }
            blocks.append(state.adultBlock)
            try saveState(state)
            nextRefresh = state.lastResolvedAt.addingTimeInterval(safeHostRefreshInterval)
        } else {
            try? FileManager.default.removeItem(atPath: DeadlockPaths.webProtectionState)
        }

        if !normalizedDistractions.isEmpty {
            refreshExternalSocialListIfNeeded(force: forceRefresh, now: now)
            blocks.append(buildDistractionBlock(normalizedDistractions))
        }

        let desired = appendBlocks(blocks, to: unmanaged)
        if desired != original {
            try writeHosts(desired, restoreOnFailure: original)
            flushCaches()
        }

        return nextRefresh
    }

    func isHealthy(
        pornEnabled: Bool,
        distractionsEnabled: Bool,
        distractionDomains: [String]
    ) -> Bool {
        guard let current = try? String(contentsOfFile: hostsPath, encoding: .utf8) else {
            return false
        }

        let normalizedDistractions = distractionsEnabled
            ? PolicyEngine.normalizedDomains(distractionDomains)
            : []
        let youtubeBrowserOnly = normalizedDistractions.contains(where: isBrowserOnlyDomain)

        let adultSection = section(in: current, begin: adultBegin, end: adultEnd)
        if pornEnabled {
            guard let saved = loadState(),
                  adultSection == saved.adultBlock,
                  (saved.youtubeSafeMappingSkipped ?? false) == youtubeBrowserOnly
            else {
                return false
            }
        } else if adultSection != nil {
            return false
        }

        let distractionSection = section(
            in: current,
            begin: distractionBegin,
            end: distractionEnd
        )
        if distractionsEnabled {
            let expected = normalizedDistractions.isEmpty
                ? nil
                : buildDistractionBlock(normalizedDistractions)
            if distractionSection != expected { return false }
        } else if distractionSection != nil {
            return false
        }

        return true
    }

    private func buildAdultBlock(skipYouTubeSafeMapping: Bool = false) -> String {
        var lines = [adultBegin]

        let explicitDomains = Set(adultDomains)
        for domain in adultDomains {
            appendBlockedHost(domain, lines: &lines)
        }

        // The upstream list already contains exact hostnames/subdomains, so do
        // not expand every entry into www./m. aliases. Blocking both IPv4 and
        // IPv6 keeps the cached list effective even when a browser prefers AAAA.
        for domain in externalAdultDomains() where !explicitDomains.contains(domain) {
            appendBlockedHostExact(domain, lines: &lines)
        }

        addSafeMapping(
            target: "forcesafesearch.google.com",
            aliases: ["google.com", "www.google.com"],
            lines: &lines
        )
        addSafeMapping(
            target: "strict.bing.com",
            aliases: ["bing.com", "www.bing.com"],
            lines: &lines
        )
        addSafeMapping(
            target: "safe.duckduckgo.com",
            aliases: ["duckduckgo.com", "www.duckduckgo.com"],
            lines: &lines
        )
        addSafeMapping(
            target: "strict-safe-search.ecosia.org",
            aliases: ["ecosia.org", "www.ecosia.org"],
            lines: &lines
        )
        if !skipYouTubeSafeMapping {
            addSafeMapping(
                target: "restrictmoderate.youtube.com",
                aliases: [
                    "youtube.com", "www.youtube.com", "m.youtube.com",
                    "youtube-nocookie.com", "www.youtube-nocookie.com"
                ],
                lines: &lines
            )
        }

        lines.append(adultEnd)
        return lines.joined(separator: "\n")
    }

    private func buildDistractionBlock(_ domains: [String]) -> String {
        var lines = [distractionBegin]
        var seen = Set<String>()

        for domain in domains {
            // YouTube is enforced at the browser/app layer instead of DNS so
            // IINA and yt-dlp can keep normal YouTube resolution.
            if isBrowserOnlyDomain(domain) { continue }
            appendBlockedHost(domain, lines: &lines)
            if domain.lowercased() == "facebook.com" {
                for host in ["touch.facebook.com", "mobile.facebook.com", "web.facebook.com"] {
                    appendBlockedHostExact(host, lines: &lines)
                }
            }
            seen.insert(domain.lowercased())
        }

        // Social-only upstream coverage catches alternate/front-end domains
        // that are easy to miss in a hand-maintained distraction list.
        // Explicit communication/productivity exceptions are filtered here,
        // so imported data cannot silently override local Deadlock policy.
        for domain in externalSocialDomains()
            where !isSocialImportAllowed(domain)
                && !isBrowserOnlyDomain(domain)
                && !seen.contains(domain.lowercased()) {
            appendBlockedHostExact(domain, lines: &lines)
        }

        lines.append(distractionEnd)
        return lines.joined(separator: "\n")
    }

    private func isBrowserOnlyDomain(_ domain: String) -> Bool {
        let host = domain.lowercased()
        let browserOnly = ["youtube.com", "youtu.be", "youtube-nocookie.com"]
        return browserOnly.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func appendBlockedHost(_ domain: String, lines: inout [String]) {
        let normalized = domain.lowercased()
        var hosts = [normalized]
        if !normalized.hasPrefix("www.") {
            hosts.append("www." + normalized)
        }
        if !normalized.hasPrefix("m.") {
            hosts.append("m." + normalized)
        }

        for host in Array(Set(hosts)).sorted() {
            lines.append("0.0.0.0 \(host)")
            lines.append(":: \(host)")
        }
    }

    private func appendBlockedHostExact(_ domain: String, lines: inout [String]) {
        let normalized = domain.lowercased()
        lines.append("0.0.0.0 \(normalized)")
        lines.append(":: \(normalized)")
    }

    private func refreshExternalAdultList() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--fail", "--silent", "--show-error", "--location",
            "--connect-timeout", "8", "--max-time", "25",
            adultSourceURL
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8),
                  text.contains("StevenBlack/hosts extension porn")
            else { return }

            let domains = parseExternalAdultDomains(text)
            guard domains.count >= minimumAdultSourceDomains,
                  domains.count <= maximumAdultSourceDomains
            else { return }

            // Refuse a clearly corrupted/misdirected upstream response rather
            // than turning a bad fetch into a broad network outage.
            let protectedRoots: Set<String> = [
                "apple.com", "github.com", "google.com",
                "microsoft.com", "cloudflare.com"
            ]
            guard protectedRoots.isDisjoint(with: Set(domains)) else { return }

            try data.write(
                to: URL(fileURLWithPath: adultCachePath),
                options: .atomic
            )
            _ = chmod(adultCachePath, 0o600)
        } catch {
            // Fail closed: keep the last valid cache. If this is the first run
            // and no cache exists yet, the built-in permanent domains remain.
            return
        }
    }

    private func externalAdultDomains() -> [String] {
        guard let text = try? String(
            contentsOfFile: adultCachePath,
            encoding: .utf8
        ) else { return [] }
        return parseExternalAdultDomains(text)
    }

    private func parseExternalAdultDomains(_ text: String) -> [String] {
        var candidates: [String] = []
        candidates.reserveCapacity(80_000)

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let fields = line.split { $0 == " " || $0 == "\t" }
            guard fields.count >= 2 else { continue }

            for field in fields.dropFirst() {
                let value = String(field)
                if value.hasPrefix("#") { break }
                candidates.append(value)
            }
        }

        return PolicyEngine.normalizedDomains(
            candidates,
            limit: maximumAdultSourceDomains
        )
    }

    private func refreshExternalSocialListIfNeeded(
        force: Bool,
        now: Date
    ) {
        if !force,
           let attrs = try? FileManager.default.attributesOfItem(
                atPath: socialCachePath
           ),
           let modified = attrs[.modificationDate] as? Date,
           modified.addingTimeInterval(safeHostRefreshInterval) > now {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--fail", "--silent", "--show-error", "--location",
            "--connect-timeout", "8", "--max-time", "25",
            socialSourceURL
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8),
                  text.contains("Limited to the extensions: social")
                    || text.contains("StevenBlack/hosts")
            else { return }

            let domains = parseExternalSocialDomains(text)
            guard domains.count >= minimumSocialSourceDomains,
                  domains.count <= maximumSocialSourceDomains
            else { return }

            try data.write(
                to: URL(fileURLWithPath: socialCachePath),
                options: .atomic
            )
            _ = chmod(socialCachePath, 0o600)
        } catch {
            // Fail closed: keep the last valid social cache. The explicit
            // Deadlock distraction list still applies if no cache exists yet.
            return
        }
    }

    private func externalSocialDomains() -> [String] {
        guard let text = try? String(
            contentsOfFile: socialCachePath,
            encoding: .utf8
        ) else { return [] }
        return parseExternalSocialDomains(text)
    }

    private func parseExternalSocialDomains(_ text: String) -> [String] {
        var candidates: [String] = []
        candidates.reserveCapacity(5_000)

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let fields = line.split { $0 == " " || $0 == "\t" }
            guard fields.count >= 2 else { continue }

            for field in fields.dropFirst() {
                let value = String(field)
                if value.hasPrefix("#") { break }
                candidates.append(value)
            }
        }

        return PolicyEngine.normalizedDomains(
            candidates,
            limit: maximumSocialSourceDomains
        )
    }

    private func isSocialImportAllowed(_ domain: String) -> Bool {
        let host = domain.lowercased()
        return socialImportAllowRoots.contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    private func appendBlocks(_ blocks: [String], to unmanaged: String) -> String {
        let base = unmanaged.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !blocks.isEmpty else {
            return base.isEmpty ? "" : base + "\n"
        }

        let managed = blocks.joined(separator: "\n\n")
        return base.isEmpty ? managed + "\n" : base + "\n\n" + managed + "\n"
    }

    private func section(in text: String, begin: String, end: String) -> String? {
        guard let start = text.range(of: begin) else { return nil }
        guard let finish = text.range(of: end, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.lowerBound..<finish.upperBound])
    }

    private func stripSection(_ text: String, begin: String, end: String) -> String {
        guard let start = text.range(of: begin) else {
            return text.replacingOccurrences(of: end, with: "")
        }

        guard let finish = text.range(of: end, range: start.upperBound..<text.endIndex) else {
            return String(text[..<start.lowerBound])
        }

        var output = text
        output.removeSubrange(start.lowerBound..<finish.upperBound)
        return output
    }

    private func addSafeMapping(
        target: String,
        aliases: [String],
        lines: inout [String]
    ) {
        guard let ip = resolveIPv4(target) else { return }
        for alias in aliases {
            lines.append("\(ip) \(alias)")
        }
    }

    private func resolveIPv4(_ host: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        process.arguments = ["-q", "host", "-a", "name", host]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let string = String(data: data, encoding: .utf8)
            else { return nil }

            for line in string.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("ip_address:") else { continue }
                let value = trimmed
                    .dropFirst("ip_address:".count)
                    .trimmingCharacters(in: .whitespaces)
                if value.contains(".") { return value }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func loadState() -> ManagedState? {
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: DeadlockPaths.webProtectionState)
        ) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ManagedState.self, from: data)
    }

    private func saveState(_ state: ManagedState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(
            to: URL(fileURLWithPath: DeadlockPaths.webProtectionState),
            options: .atomic
        )
        _ = chmod(DeadlockPaths.webProtectionState, 0o600)
        _ = chown(DeadlockPaths.webProtectionState, 0, 0)
    }

    private func writeHosts(_ text: String, restoreOnFailure original: String) throws {
        do {
            try overwriteHosts(text)
        } catch {
            try? overwriteHosts(original)
            throw error
        }
    }

    private func overwriteHosts(_ text: String) throws {
        let data = Data(text.utf8)
        let fd = Darwin.open(hostsPath, O_WRONLY | O_TRUNC)
        guard fd >= 0 else {
            throw NSError(
                domain: "deadlock.web",
                code: Int(errno),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not open /etc/hosts: \(String(cString: strerror(errno)))"
                ]
            )
        }
        defer { Darwin.close(fd) }

        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < data.count {
                let amount = Darwin.write(
                    fd,
                    base.advanced(by: written),
                    data.count - written
                )
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw NSError(
                        domain: "deadlock.web",
                        code: Int(errno),
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Could not write /etc/hosts: \(String(cString: strerror(errno)))"
                        ]
                    )
                }
                if amount == 0 {
                    throw NSError(
                        domain: "deadlock.web",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Short write to /etc/hosts"]
                    )
                }
                written += amount
            }
        }
        _ = fsync(fd)
    }

    private func flushCaches() {
        let flush = Process()
        flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        flush.arguments = ["-flushcache"]
        flush.standardOutput = FileHandle.nullDevice
        flush.standardError = FileHandle.nullDevice
        if (try? flush.run()) != nil { flush.waitUntilExit() }

        let mdns = Process()
        mdns.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        mdns.arguments = ["-HUP", "mDNSResponder"]
        mdns.standardOutput = FileHandle.nullDevice
        mdns.standardError = FileHandle.nullDevice
        if (try? mdns.run()) != nil { mdns.waitUntilExit() }
    }
}
