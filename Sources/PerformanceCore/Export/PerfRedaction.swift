import Foundation

/// 落盘前的脱敏策略。
///
/// 性能数据天然会捎带敏感信息：URL 里的 token、文件路径里的用户名、
/// 堆栈里的函数名。这些一旦落盘就会随导出文件、bug 单流出。
/// 上一版把 URL 完整路径、`url.path`、符号名直接明文落盘并上传，没有任何处理。
public struct PerfRedactionPolicy: Sendable, Hashable {
    /// 去掉 URL 的 query。token、签名、用户标识大多在这里。
    public var stripURLQuery: Bool
    /// 去掉 URL 的 path，只保留 scheme + host。
    ///
    /// 更激进但也更安全——RESTful 路径里常嵌着用户 ID、订单号。
    /// 代价是无法按接口维度分析耗时，所以默认关闭。
    public var stripURLPath: Bool
    /// 把绝对文件路径转成相对于 home 或 bundle 的形式，隐去用户名。
    public var relativizeFilePaths: Bool
    /// 是否保留堆栈中的符号名。
    ///
    /// 关闭后只留镜像 UUID + 偏移，靠服务端 dSYM 还原。
    /// 这既是脱敏，也能显著减小落盘体积。
    public var includeSymbolNames: Bool
    /// 白名单内的 host 才保留，其余替换为占位符。nil 表示不限制。
    public var allowedURLHosts: Set<String>?

    public init(
        stripURLQuery: Bool = true,
        stripURLPath: Bool = false,
        relativizeFilePaths: Bool = true,
        includeSymbolNames: Bool = true,
        allowedURLHosts: Set<String>? = nil
    ) {
        self.stripURLQuery = stripURLQuery
        self.stripURLPath = stripURLPath
        self.relativizeFilePaths = relativizeFilePaths
        self.includeSymbolNames = includeSymbolNames
        self.allowedURLHosts = allowedURLHosts
    }

    /// 默认策略：去掉 query、路径相对化，保留接口路径和符号名以便排查。
    public static let `default` = PerfRedactionPolicy()

    /// 严格策略：URL 只留 host、不留符号名。适合对外分发的构建。
    public static let strict = PerfRedactionPolicy(
        stripURLQuery: true,
        stripURLPath: true,
        relativizeFilePaths: true,
        includeSymbolNames: false
    )

    /// 不脱敏。仅适合本地调试构建。
    public static let disabled = PerfRedactionPolicy(
        stripURLQuery: false,
        stripURLPath: false,
        relativizeFilePaths: false,
        includeSymbolNames: true
    )

    // MARK: - 应用

    /// 不在白名单内的 host 的替换值。
    ///
    /// 用 `.invalid` 保留 TLD（RFC 2606）而不是 `<redacted>` 之类的占位串：
    /// 尖括号不是合法的 host 字符，会让 `URLComponents.string` 返回 nil，
    /// 进而触发「重建失败」的兜底路径。保留 TLD 则保证结果始终是个合法 URL。
    public static let redactedHost = "redacted.invalid"

    /// URL 无法解析或重建时的替代值。
    public static let redactedURLPlaceholder = "<unparseable-url>"

    /// 按策略处理一个 URL 字符串。
    ///
    /// 解析失败或重建失败时返回占位符，**不会**退回原始字符串。
    /// 脱敏函数必须 fail-closed：失败时吐出未脱敏的数据，
    /// 比直接丢掉这条数据的后果严重得多。
    public func redact(urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return Self.redactedURLPlaceholder
        }

        if let allowedURLHosts, let host = components.host, !allowedURLHosts.contains(host) {
            components.host = Self.redactedHost
        }
        if stripURLQuery {
            components.query = nil
            components.fragment = nil
        }
        if stripURLPath {
            components.path = ""
        }
        components.user = nil
        components.password = nil

        return components.string ?? Self.redactedURLPlaceholder
    }

    /// 按策略处理一个文件路径。
    public func redact(path: String) -> String {
        guard relativizeFilePaths else { return path }

        let home = NSHomeDirectory()
        if !home.isEmpty, path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }

        // 容器路径里的 UUID 目录同样能定位到具体设备/安装实例
        if let range = path.range(of: "/Containers/Data/Application/") {
            let tail = path[range.upperBound...]
            if let slash = tail.firstIndex(of: "/") {
                return "<container>" + tail[slash...]
            }
            return "<container>"
        }

        return path
    }

    /// 按策略处理一组栈帧。
    public func redact(frames: [PerfFrame]) -> [PerfFrame] {
        guard !includeSymbolNames else { return frames }
        return frames.map {
            PerfFrame(
                address: $0.address,
                imageName: $0.imageName,
                imageOffset: $0.imageOffset,
                symbol: nil,
                symbolOffset: nil
            )
        }
    }
}

/// 载荷可以声明自己该如何脱敏。
///
/// 做成「载荷自己负责」而不是在管道里统一处理，是因为只有载荷类型
/// 知道哪个字段是 URL、哪个是路径。管道拿到的是 `any PerfPayload`，
/// 无法在类型擦除之后还分辨字段语义——上一版的 `[String: String]`
/// 万能袋正是因此完全无法做脱敏。
public protocol PerfRedactable {
    func redacted(using policy: PerfRedactionPolicy) -> Self
}

extension PerfAnyRecord {
    /// 若载荷声明了脱敏方式则应用之，否则原样返回。
    public func redacted(using policy: PerfRedactionPolicy) -> PerfAnyRecord {
        guard let redactable = payload as? any PerfRedactablePayload else {
            return self
        }
        return PerfAnyRecord(
            id: id,
            timestamp: timestamp,
            uptimeNanos: uptimeNanos,
            sessionID: sessionID,
            severity: severity,
            thread: thread,
            kind: kind,
            schemaVersion: schemaVersion,
            payload: redactable.redactedPayload(using: policy)
        )
    }
}

/// `PerfPayload` 与 `PerfRedactable` 的交集，用于在类型擦除后仍能调用脱敏。
public protocol PerfRedactablePayload: PerfPayload, PerfRedactable {}

extension PerfRedactablePayload {
    /// 擦除返回类型，供 `PerfAnyRecord` 调用。
    func redactedPayload(using policy: PerfRedactionPolicy) -> any PerfPayload {
        redacted(using: policy)
    }
}
