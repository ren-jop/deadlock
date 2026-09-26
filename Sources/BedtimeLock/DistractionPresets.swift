import Foundation

struct DistractionPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let domains: [String]

    init(
        _ title: String,
        domains: [String]
    ) {
        self.id = title
        self.title = title
        self.domains = domains
    }
}

struct DistractionPresetGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let presets: [DistractionPreset]

    init(
        _ title: String,
        presets: [DistractionPreset]
    ) {
        self.id = title
        self.title = title
        self.presets = presets
    }
}

enum DistractionPresetCatalog {
    static let groups: [DistractionPresetGroup] = [
        DistractionPresetGroup(
            "Social & feeds",
            presets: [
                DistractionPreset(
                    "Instagram",
                    domains: ["instagram.com"]
                ),
                DistractionPreset(
                    "TikTok",
                    domains: ["tiktok.com"]
                ),
                DistractionPreset(
                    "X / Twitter",
                    domains: ["x.com", "twitter.com"]
                ),
                DistractionPreset(
                    "Facebook",
                    domains: ["facebook.com"]
                ),
                DistractionPreset(
                    "Threads",
                    domains: ["threads.net"]
                ),
                DistractionPreset(
                    "Snapchat",
                    domains: ["snapchat.com"]
                ),
                DistractionPreset(
                    "Pinterest",
                    domains: ["pinterest.com"]
                )
            ]
        ),
        DistractionPresetGroup(
            "Video & streaming",
            presets: [
                DistractionPreset(
                    "YouTube",
                    domains: [
                        "youtube.com",
                        "youtu.be",
                        "youtube-nocookie.com"
                    ]
                ),
                DistractionPreset(
                    "Twitch",
                    domains: ["twitch.tv"]
                ),
                DistractionPreset(
                    "Netflix",
                    domains: ["netflix.com"]
                ),
                DistractionPreset(
                    "Disney+",
                    domains: ["disneyplus.com"]
                ),
                DistractionPreset(
                    "Prime Video",
                    domains: ["primevideo.com"]
                )
            ]
        ),
        DistractionPresetGroup(
            "Forums & communities",
            presets: [
                DistractionPreset(
                    "Reddit",
                    domains: ["reddit.com"]
                ),
                DistractionPreset(
                    "Quora",
                    domains: ["quora.com"]
                ),
                DistractionPreset(
                    "Tumblr",
                    domains: ["tumblr.com"]
                ),
                DistractionPreset(
                    "9GAG",
                    domains: ["9gag.com"]
                )
            ]
        ),
        DistractionPresetGroup(
            "Messaging",
            presets: [
                DistractionPreset(
                    "Discord",
                    domains: ["discord.com"]
                ),
                DistractionPreset(
                    "WhatsApp Web",
                    domains: ["web.whatsapp.com"]
                ),
                DistractionPreset(
                    "Messenger",
                    domains: ["messenger.com"]
                ),
                DistractionPreset(
                    "Telegram Web",
                    domains: ["web.telegram.org"]
                )
            ]
        ),
        DistractionPresetGroup(
            "Gaming",
            presets: [
                DistractionPreset(
                    "Steam",
                    domains: [
                        "steampowered.com",
                        "steamcommunity.com"
                    ]
                ),
                DistractionPreset(
                    "Roblox",
                    domains: ["roblox.com"]
                ),
                DistractionPreset(
                    "Epic Games",
                    domains: ["epicgames.com"]
                )
            ]
        ),
        DistractionPresetGroup(
            "Shopping",
            presets: [
                DistractionPreset(
                    "Amazon",
                    domains: [
                        "amazon.com.au",
                        "amazon.com"
                    ]
                ),
                DistractionPreset(
                    "eBay",
                    domains: [
                        "ebay.com.au",
                        "ebay.com"
                    ]
                ),
                DistractionPreset(
                    "Temu",
                    domains: ["temu.com"]
                ),
                DistractionPreset(
                    "AliExpress",
                    domains: ["aliexpress.com"]
                )
            ]
        ),
        DistractionPresetGroup(
            "News & headlines",
            presets: [
                DistractionPreset(
                    "News.com.au",
                    domains: ["news.com.au"]
                ),
                DistractionPreset(
                    "ABC News",
                    domains: ["abc.net.au"]
                ),
                DistractionPreset(
                    "BBC",
                    domains: ["bbc.com", "bbc.co.uk"]
                ),
                DistractionPreset(
                    "CNN",
                    domains: ["cnn.com"]
                )
            ]
        )
    ]
}
