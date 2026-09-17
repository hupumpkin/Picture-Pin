import Foundation

/// 运行环境与数据目录。
///
/// 路线图 §6：原生版**从全新空库开始**，不读取、不迁移、不删除旧 DesignPeek /
/// Pin Web / CC Web 的任何素材与画布数据。`GITHUB_MAINTENANCE_WORKFLOW.md` §7
/// 还要求 CC 和 Codex 使用**不同的运行数据目录**，否则两个 Agent 同时跑起来
/// 会互相覆盖对方的开发数据。
///
/// 这两条合起来就是本文件存在的全部理由：把数据目录钉死在原生版自己的沙盒里，
/// 并且让并行的两个 Agent 各占一个子目录。
struct AppEnvironment {

    /// 谁是当前运行者。
    ///
    /// 启动参数（`swift run` 场景）与 bundle identifier（双击 `.app` 场景）
    /// 两条路都能定出 profile——见 `resolve`。
    enum Profile: String, CaseIterable {
        case cc
        case codex
        /// 正式版。**与两个开发 profile 分开**，且不共用目录。
        case production
        /// 无法识别的 profile 取值。存在的意义是**不要静默回退**：
        /// 回退到 `.cc` 意味着 Codex 的实例会去写 Claude 的数据目录，
        /// 而这类事故在空目录阶段看不出来，等有数据时已经是覆盖了。
        case unsupported

        var isDevelopment: Bool {
            switch self {
            case .cc, .codex: true
            case .production, .unsupported: false
            }
        }

        var displayName: String {
            switch self {
            case .cc: "Claude"
            case .codex: "Codex"
            case .production: "正式版"
            case .unsupported: "未知 profile"
            }
        }
    }

    let profile: Profile
    /// 应用数据根目录。
    let dataDirectory: URL

    /// 环境变量名。`PIN_DEV_PROFILE=codex swift run` 即可切到 Codex 的目录。
    static let profileEnvironmentKey = "PIN_DEV_PROFILE"

    /// 解析启动环境。
    ///
    /// ## 判定顺序
    ///
    /// 1. `PIN_DEV_PROFILE` 显式指定——但**取值必须已知**，未知一律落到
    ///    `.unsupported`，绝不回退。第一版是 `?? .cc`，拼错一个字母就静默换目录。
    /// 2. 没有环境变量时看 bundle identifier 的后缀。打包脚本会给三个 profile
    ///    写不同的 bundle id（`com.pin.native.dev-cc` / `.dev-codex` / `com.pin.native`），
    ///    所以**双击哪个 .app 就进哪个目录**，不需要用户设任何环境变量。
    /// 3. bundle identifier 也没有（`swift run` 的裸可执行文件没有 bundle）
    ///    才默认 `.cc`。这条路只可能从终端发生。
    ///
    /// 第 2 条是关键：双击启动的 .app 天生带不了环境变量，第一版因此让 Codex
    /// 只要按普通应用方式启动就落进 `dev-cc`。
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> AppEnvironment {
        let profile = resolveProfile(
            environment: environment,
            bundleIdentifier: bundleIdentifier
        )
        return AppEnvironment(profile: profile, dataDirectory: dataDirectory(for: profile))
    }

    static func resolveProfile(
        environment: [String: String],
        bundleIdentifier: String?
    ) -> Profile {
        if let raw = environment[profileEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return Profile(rawValue: raw.lowercased()) ?? .unsupported
        }

        guard let bundleIdentifier else { return .cc }
        // 只认最后一段，避免 `com.example.not-pin-native` 里的 "native" 之类误判。
        switch bundleIdentifier.split(separator: ".").last.map(String.init) {
        case "dev-cc": return .cc
        case "dev-codex": return .codex
        default: return .production
        }
    }

    /// 数据目录。
    ///
    /// 刻意**不用** `Bundle.main.bundleIdentifier` 当目录名：SPM 可执行文件在
    /// `swift run` 下没有 bundle identifier，那样写会导致两种启动方式落到不同目录。
    ///
    /// 正式版直接用 `Pin/` 根目录——那是 macOS 上正常应用该待的地方；两个开发
    /// profile 是它的子目录，因此开发数据永远不会混进正式数据。
    static func dataDirectory(for profile: Profile) -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())

        let root = base.appendingPathComponent("Pin", isDirectory: true)
        switch profile {
        case .production:
            return root
        case .cc, .codex:
            return root.appendingPathComponent("dev-\(profile.rawValue)", isDirectory: true)
        case .unsupported:
            // 谁都不属于的目录：万一真的走到了这里，宁可写进一个没人读的地方，
            // 也不要写进某个真实 profile。
            return root.appendingPathComponent("unsupported-profile", isDirectory: true)
        }
    }

    /// 启动闸门。环境不可用时打印原因并以非零码退出。
    ///
    /// **不用回退代替报错。** 启动失败看得见，写错目录看不见——后者要等到某个
    /// Agent 发现自己的开发数据被对方覆盖时才暴露。
    static func resolveForLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> AppEnvironment {
        let resolved = resolve(environment: environment, bundleIdentifier: bundleIdentifier)
        guard resolved.profile == .unsupported else { return resolved }

        let raw = environment[profileEnvironmentKey] ?? ""
        let known = Profile.allCases
            .filter { $0 != .unsupported }
            .map(\.rawValue)
            .joined(separator: " / ")
        FileHandle.standardError.write(Data("""
        [Pin] 无法识别的 \(profileEnvironmentKey)：\(raw)
             可用取值：\(known)
             不猜、不回退——回退会让你在别人的数据目录里工作。
        """.utf8))
        exit(2)
    }

    /// 各子目录。批次 A 只创建目录结构，不写入任何内容——空库就是本批次的交付物。
    var boardsDirectory: URL { dataDirectory.appendingPathComponent("boards", isDirectory: true) }
    var assetsDirectory: URL { dataDirectory.appendingPathComponent("assets", isDirectory: true) }
    var cacheDirectory: URL { dataDirectory.appendingPathComponent("cache", isDirectory: true) }

    /// 建立目录结构。幂等。
    func prepareDirectories() throws {
        for directory in [dataDirectory, boardsDirectory, assetsDirectory, cacheDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
}
