import Foundation

/// Kind of a curated ad-cache target. The curated table is directories only;
/// ad configuration files are matched separately by name.
enum AdLockTargetKind: String, Sendable {
    case directory
    case file
}

struct AdLockKnownPath: Hashable, Sendable {
    let relativePath: String
    let kind: AdLockTargetKind

    init(relativePath: String, kind: AdLockTargetKind = .directory) {
        self.relativePath = relativePath
        self.kind = kind
    }
}

/// Payload used when a matched ad configuration file is emptied in place.
enum AdLockFilePayload: String, Sendable {
    case json
    case plist
    case text
}

/// Curated data for the splash-ad cache blocker.
///
/// The path table is a port of the GPL-3.0 upstream list (see NOTICE.md).
/// Notes are deliberately not stored per path: the UI renders the app name
/// plus the relative path and a generic localized label, which keeps four
/// language files maintainable while preserving the same targets.
enum AdLockCatalog {
    static let sentinelFileName = ".erosion_adlock"

    static let appDataRoot = "/var/mobile/Containers/Data/Application"
    static let appGroupRoot = "/var/mobile/Containers/Shared/AppGroup"

    /// Maximum depth below a container root for the generic SDK scan.
    static let maximumScanDepth = 2

    // MARK: - Curated per-app paths (26 bundle IDs / 65 entries)

    static let knownPaths: [String: [AdLockKnownPath]] = [
        "com.sina.weibo": [
            AdLockKnownPath(relativePath: "Documents/wb_ad_cache"),
            AdLockKnownPath(relativePath: "Library/Caches/wb_ad_cache"),
            AdLockKnownPath(relativePath: "Documents/WBAdCache"),
            AdLockKnownPath(relativePath: "Library/Caches/WBAdCache"),
            AdLockKnownPath(relativePath: "Library/Caches/wbad_splash"),
        ],
        "com.sina.weibolite": [
            AdLockKnownPath(relativePath: "Documents/wb_ad_cache"),
            AdLockKnownPath(relativePath: "Library/Caches/wb_ad_cache"),
            AdLockKnownPath(relativePath: "Library/Caches/WBAdCache"),
        ],
        "com.zhihu.ios": [
            AdLockKnownPath(relativePath: "Library/Caches/ZHAdCache"),
            AdLockKnownPath(relativePath: "Library/Caches/ZHSplashAd"),
            AdLockKnownPath(relativePath: "Documents/ZHAdCache"),
            AdLockKnownPath(relativePath: "Library/Caches/LaunchAdCache"),
        ],
        "com.netease.cloudmusic": [
            AdLockKnownPath(relativePath: "Library/Caches/NEAdCache"),
            AdLockKnownPath(relativePath: "Library/Caches/AdCache"),
            AdLockKnownPath(relativePath: "Documents/AdCache"),
        ],
        "com.tencent.QQMusic": [
            AdLockKnownPath(relativePath: "Library/Caches/QMAdCache"),
            AdLockKnownPath(relativePath: "Documents/QMAdCache"),
            AdLockKnownPath(relativePath: "Library/Caches/TADCache"),
        ],
        "tv.danmaku.bilianime": [
            AdLockKnownPath(relativePath: "Library/Caches/SplashAd"),
            AdLockKnownPath(relativePath: "Library/Caches/BiliSplashAd"),
            AdLockKnownPath(relativePath: "Documents/SplashAd"),
        ],
        "com.bilibili.app.in": [
            AdLockKnownPath(relativePath: "Library/Caches/SplashAd"),
        ],
        "com.xingin.discover": [
            AdLockKnownPath(relativePath: "Library/Caches/XYAdCache"),
            AdLockKnownPath(relativePath: "Library/Caches/XHSSplashAd"),
        ],
        "com.taobao.taobao4iphone": [
            AdLockKnownPath(relativePath: "Documents/TBDocuments/bootImagebiz"),
            AdLockKnownPath(relativePath: "Documents/TBDocuments/bootImageDoc"),
            AdLockKnownPath(relativePath: "Documents/TBDocuments/bootImagesDoc"),
            AdLockKnownPath(relativePath: "Library/Caches/TanxAd"),
            AdLockKnownPath(relativePath: "Library/Caches/TanxSDK"),
            AdLockKnownPath(relativePath: "Documents/SplashAd"),
        ],
        "com.taobao.fleamarket": [
            AdLockKnownPath(relativePath: "Library/Caches/TanxAd"),
            AdLockKnownPath(relativePath: "Library/Caches/SplashAd"),
        ],
        "com.360buy.jdmobile": [
            AdLockKnownPath(relativePath: "Library/Caches/startADImage"),
            AdLockKnownPath(relativePath: "Library/Caches/JADYun"),
            AdLockKnownPath(relativePath: "Library/Caches/JDAdSDK"),
        ],
        "com.jingdong.app.mall": [
            AdLockKnownPath(relativePath: "Library/Caches/startADImage"),
            AdLockKnownPath(relativePath: "Library/Caches/JADYun"),
            AdLockKnownPath(relativePath: "Library/Caches/JDAdSDK"),
        ],
        "com.meituan.imeituan": [
            AdLockKnownPath(relativePath: "Library/Caches/MTSplashAd"),
            AdLockKnownPath(relativePath: "Library/Caches/SplashAd"),
        ],
        "com.dianping.dpscope": [
            AdLockKnownPath(relativePath: "Documents/splashes_new"),
            AdLockKnownPath(relativePath: "Library/Caches/DPSplashAd"),
            AdLockKnownPath(relativePath: "Library/Caches/SplashAd"),
        ],
        "cn.10086.app": [
            AdLockKnownPath(relativePath: "Library/DownloadCenter"),
        ],
        "com.tencent.live4iphone": [
            AdLockKnownPath(relativePath: "Library/Caches/QAD/PreloadImageAdOrderCache"),
            AdLockKnownPath(relativePath: "Library/Caches/QAD/QADWatchHistoryAdCache"),
            AdLockKnownPath(relativePath: "Library/Caches/QAD/maxViewAdCacheFolderName"),
            AdLockKnownPath(relativePath: "Library/Caches/TAD/PushAdPendantCache"),
            AdLockKnownPath(relativePath: "Library/Caches/TADCache"),
            AdLockKnownPath(relativePath: "Documents/TADCache"),
        ],
        "com.dragon.read": [
            AdLockKnownPath(relativePath: "Documents/TTAdSplashSimpleCache"),
        ],
        "ctrip.com": [
            AdLockKnownPath(relativePath: "Library/Caches/LoadingImages"),
        ],
        "ctrip.wireless": [
            AdLockKnownPath(relativePath: "Library/Caches/LoadingImages"),
        ],
        "com.autonavi.amap": [
            AdLockKnownPath(relativePath: "Library/Caches/AmapSplashAd"),
            AdLockKnownPath(relativePath: "Library/Caches/SplashAd"),
        ],
        "com.baidu.BaiduMobile": [
            AdLockKnownPath(relativePath: "Library/Caches/BaiduMobAd"),
            AdLockKnownPath(relativePath: "Library/Caches/BDAdCache"),
        ],
        "com.baidu.tieba": [
            AdLockKnownPath(relativePath: "Library/Caches/BaiduMobAd"),
            AdLockKnownPath(relativePath: "Library/Caches/TBAdCache"),
        ],
        "com.baidu.netdisk": [
            AdLockKnownPath(relativePath: "Library/Caches/BaiduMobAd"),
            AdLockKnownPath(relativePath: "Library/Caches/BDSplashAd"),
        ],
        "com.gemd.iting": [
            AdLockKnownPath(relativePath: "Library/Caches/XMLYAdCache"),
            AdLockKnownPath(relativePath: "Documents/XMLYAdCache"),
        ],
        "com.hupu.games": [
            AdLockKnownPath(relativePath: "Library/Caches/HupuAdCache"),
        ],
        "com.douban.frodo": [
            AdLockKnownPath(relativePath: "Library/Caches/DoubanAdCache"),
        ],
    ]

    static func knownPaths(for bundleID: String) -> [AdLockKnownPath] {
        knownPaths[bundleID] ?? []
    }

    static func isKnownBundleID(_ bundleID: String) -> Bool {
        knownPaths[bundleID] != nil
    }

    // MARK: - Splash / ad SDK folder tokens

    /// Lowercased exact folder names of mainstream splash and ad SDKs.
    static let adSDKTokens: Set<String> = [
        "ksadsdk", "ksadcache", "ksad_cache", "com.kwad.sdk", "kwadsdk", "buadsdk",
        "csjadsdk", "csjadcache", "pangle_sdk", "panglesdk", "bytedancead", "ttadsdk",
        "pangolinad", "gromoread", "gdtmobsdk", "gdt_splash", "gdtsplash", "gdtadcache",
        "gdtnetcache", "tadcache", "tencentad", "qq_ad_cache", "ylhadsdk", "baidumobad",
        "bd_ad_cache", "baidusplashad", "bdsplashad", "beizisdk", "beiziad", "octopusad",
        "jadyun", "jdadsdk", "startadimage", "ttadsplashsimplecache", "sigmob", "windadsdk",
        "windad", "anythinksdk", "toponsdk", "tradplus", "mintegral", "mtgadcache",
        "tanxad", "tanxsdk", "sakuraad", "ubixad", "qumengad", "googlemobileads",
        "gadcache", "unityads", "unityadscache", "vunglecache", "vungle_cache", "applovin",
        "chartboost", "inmobicache", "ironsource", "splashad", "splashads", "splashadcache",
        "splash_ad", "splash_ads", "splashscreenad", "launchad", "launchads", "launchadcache",
        "launch_ad", "xhlaunchadcache", "xhlaunchad", "jwlaunchad", "openscreenad", "open_screen_ad",
        "adsplash", "adcache", "adscache", "ad_cache", "ads_cache", "advertisingcache",
        "startupad", "startupads", "bootad", "wb_ad_cache", "wbadcache", "zhadcache",
        "xyadcache", "qmadcache", "xmlyadcache",
    ]

    /// Folders that are never targets and are never descended into.
    static let neverTouchOrDescend: Set<String> = [
        "splashboard", "webkit", "fscacheddata", "com.apple.nsurlsessiond",
        "cookies", "httpstorages", "preferences", "saved application state",
        "cloudkit", "snapshots", "flutter_assets", "downloads", "download",
        "uploads", "upload", "preload", "shaders", "shadercache", "metadata",
        "payload", "avatars", "database", "databases",
    ]

    /// Leaf names rejected when the user adds a custom watch path.
    static let forbiddenCustomNames: Set<String> = [
        "documents", "library", "caches", "tmp", "preferences", "application support",
        "splashboard", "webkit", "fscacheddata", "com.apple.nsurlsessiond",
        "cookies", "httpstorages", "saved application state", "cloudkit",
        "snapshots", "flutter_assets", "downloads", "download",
        "uploads", "upload", "databases", "database", "system", "bundle",
    ]

    // MARK: - Ad configuration files

    static let adConfigFileNames: Set<String> = [
        "splash_ad.json", "splashad.json", "splash_ads.json", "splash_cache.json",
        "launch_ad.json", "launchad.json", "open_screen_ad.json", "ad_splash.json",
        "wb_splash_ad.json", "splash_ad.plist", "splashad.plist", "launch_ad.plist",
        "xhlaunchad.plist", "ad_splash.plist", "wb_ad_cache.plist",
    ]

    static func payload(forConfigFileName name: String) -> AdLockFilePayload? {
        let lower = name.lowercased()
        guard adConfigFileNames.contains(lower) else { return nil }
        if lower.hasSuffix(".plist") { return .plist }
        if lower.hasSuffix(".json") { return .json }
        return .text
    }

    // MARK: - Container filters

    /// Bundle IDs that must never be scanned or locked.
    static let protectedBundleIDs: Set<String> = [
        "com.qingtang.3106",
        "com.jbdotparty.Erosion",
        "com.apple.PosterBoard",
        "com.apple.springboard",
        "com.apple.Preferences",
        "com.apple.mobilephone",
    ]

    /// AppGroup prefixes excluded from the ad scan (system groups and proxy
    /// tools), matching the upstream safety boundary.
    static let ignoredAppGroupPrefixes: [String] = [
        "group.com.apple.",
        "systemgroup.",
        "group.com.jbdotparty.",
        "group.com.qingtang.",
        "group.com.nssurge.",
        "group.com.liguangming.",
        "group.com.luo.",
        "group.com.loon",
        "group.ws.stash.",
    ]

    // MARK: - Official display names (v1.0.7 mapping, localized)

    static let officialDisplayNames: [String: [String: String]] = [
        "com.taobao.taobao4iphone": [
            "zh-Hans": "淘宝", "en": "Taobao", "vi": "Taobao", "ko": "타오바오",
        ],
        "com.taobao.fleamarket": [
            "zh-Hans": "闲鱼", "en": "Idlefish", "vi": "Idlefish", "ko": "셴위",
        ],
        "com.360buy.jdmobile": [
            "zh-Hans": "京东", "en": "JD.com", "vi": "JD.com", "ko": "징둥",
        ],
        "com.jingdong.app.mall": [
            "zh-Hans": "京东", "en": "JD.com", "vi": "JD.com", "ko": "징둥",
        ],
        "com.dianping.dpscope": [
            "zh-Hans": "大众点评", "en": "Dianping", "vi": "Dianping", "ko": "딩핑",
        ],
        "cn.10086.app": [
            "zh-Hans": "中国移动", "en": "China Mobile", "vi": "China Mobile", "ko": "차이나 모바일",
        ],
        "com.tencent.live4iphone": [
            "zh-Hans": "腾讯视频", "en": "Tencent Video", "vi": "Tencent Video", "ko": "텐센트 비디오",
        ],
        "com.dragon.read": [
            "zh-Hans": "番茄小说", "en": "Fanqie Novel", "vi": "Fanqie Novel", "ko": "판치에 소설",
        ],
        "ctrip.com": [
            "zh-Hans": "携程旅行", "en": "Trip.com", "vi": "Trip.com", "ko": "트립닷컴",
        ],
        "ctrip.wireless": [
            "zh-Hans": "携程旅行", "en": "Trip.com", "vi": "Trip.com", "ko": "트립닷컴",
        ],
    ]

    static func displayName(
        bundleID: String,
        languageCode: String,
        fallback: String?
    ) -> String {
        if let localized = officialDisplayNames[bundleID]?[languageCode], !localized.isEmpty {
            return localized
        }
        if let localized = officialDisplayNames[bundleID]?["en"], !localized.isEmpty {
            return localized
        }
        let trimmedFallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedFallback.isEmpty ? bundleID : trimmedFallback
    }
}