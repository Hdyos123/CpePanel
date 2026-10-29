import Foundation

/// FiberHome LG6121F CPE Web API 客户端
///
/// 协议要点（从设备前端逆向得出）：
/// - 登录 URL 必须是 `/?_<random>`（下划线，不是 `?=`）
/// - 加密前明文 body 必须包含 `sessionid` 字段
/// - AES-128-CBC / PKCS7，key = sessionid 前 16 字节，iv = "pqrstuvwxyz{|}~"
/// - 请求 body 为 hex 密文，响应多数也是 hex 密文
final class CpeAPI {
    static let shared = CpeAPI()

    private var host: String
    private var user: String
    private var password: String
    private var sessionId: String = ""
    private var aesEnabled: Bool = true

    private let lock = NSLock()
    private let session: URLSession

    private static let iv = Data("pqrstuvwxyz{|}~".utf8)

    private init() {
        let c = Settings.load()
        host = c.host
        user = c.user
        password = c.password
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 12
        cfg.waitsForConnectivity = false
        cfg.httpShouldSetCookies = false
        session = URLSession(configuration: cfg)
    }

    func update(host: String, user: String, password: String) {
        lock.lock(); defer { lock.unlock() }
        self.host = host.hasPrefix("http") ? host : "http://" + host
        self.user = user
        self.password = password
        sessionId = ""
    }

    // MARK: - 加解密

    private func encrypt(_ plain: String) throws -> String {
        guard let sid = sessionId.data(using: .utf8), sid.count >= 16 else {
            throw CpeError.noSession
        }
        let encrypted = try Self.cbcEncrypt(data: Data(plain.utf8),
                                            key: Data(sid.prefix(16)),
                                            iv: Self.iv)
        return encrypted.map { String(format: "%02x", $0) }.joined()
    }

    private func decrypt(_ hex: String) throws -> String {
        guard let sid = sessionId.data(using: .utf8), sid.count >= 16 else {
            throw CpeError.noSession
        }
        var bytes = [UInt8]()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[idx..<next], radix: 16) { bytes.append(b) }
            idx = next
        }
        let clear = try Self.cbcDecrypt(data: Data(bytes),
                                        key: Data(sid.prefix(16)),
                                        iv: Self.iv)
        return String(data: clear, encoding: .utf8) ?? ""
    }

    /// AES-CBC 加密（CryptoKit 没有直接 CBC 接口，用 CommonCrypto）
    private static func cbcEncrypt(data: Data, key: Data, iv: Data) throws -> Data {
        var outLength = 0
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCEncrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, out.count,
                                &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CpeError.cryptoFailed }
        return out.prefix(outLength)
    }

    private static func cbcDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        var outLength = 0
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, out.count,
                                &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CpeError.cryptoFailed }
        return out.prefix(outLength)
    }

    // MARK: - 底层请求

    private func rawRequest(path: String,
                            body: String? = nil,
                            method: String = "GET") async throws -> String {
        guard let url = URL(string: host + path) else { throw CpeError.badHost }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("application/json, text/javascript, */*; q=0.01",
                     forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue(host + "/", forHTTPHeaderField: "Referer")
        if let body {
            req.httpBody = Data(body.utf8)
            req.setValue("application/json; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CpeError.badResponse }
        if http.statusCode == 400 { throw CpeError.locked }
        if http.statusCode != 200 { throw CpeError.http(http.statusCode) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func rnd() -> String {
        String(format: "%.17f", Double.random(in: 0..<1)).replacingOccurrences(of: "0.", with: "")
    }

    // MARK: - 会话

    @discardableResult
    func refreshSession() async throws -> String {
        let txt = try await rawRequest(
            path: "/api/tmp/FHNCAPIS?ajaxmethod=get_refresh_sessionid&_=\(Self.rnd())")
        guard let data = txt.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = obj["sessionid"] as? String else {
            throw CpeError.noSession
        }
        lock.lock(); sessionId = sid; lock.unlock()
        return sid
    }

    func login(user: String? = nil, password: String? = nil) async throws {
        let u = user ?? self.user
        let p = password ?? self.password
        update(host: host, user: u, password: p)

        // 探测是否启用加密
        do {
            let t = try await rawRequest(
                path: "/api/tmp/FHNCAPIS?ajaxmethod=is_encrypt&_=\(Self.rnd())")
            NSLog("[CpePanel] is_encrypt -> \(t.prefix(200))")
            if let d = t.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                // 兼容 enable / is_encrypt / isEncrypt 三种写法
                if let v = o["enable"] as? Int { aesEnabled = v == 1 }
                else if let v = o["is_encrypt"] as? Int { aesEnabled = v == 1 }
                else if let v = o["isEncrypt"] as? Int { aesEnabled = v == 1 }
                else if let v = o["enable"] as? Bool { aesEnabled = v }
                else { aesEnabled = false }
            }
        } catch {
            NSLog("[CpePanel] is_encrypt failed: \(error). 回退明文模式")
            aesEnabled = false   // 探测失败时先试明文，别盲目加密
        }

        try await refreshSession()

        let inner: [String: Any] = [
            "dataObj": ["username": u, "password": p],
            "ajaxmethod": "DO_WEB_LOGIN",
            "sessionid": sessionId
        ]
        let plain = try JSONSerialization.data(withJSONObject: inner)
        let plainStr = String(data: plain, encoding: .utf8) ?? "{}"
        let payload = aesEnabled ? try encrypt(plainStr) : plainStr

        let resp = try await rawRequest(
            path: "/api/sign/DO_WEB_LOGIN?_\(Self.rnd())",
            body: payload, method: "POST")
        let trimmed = resp.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[CpePanel] LOGIN aes=\(aesEnabled) sid=\(sessionId.prefix(8)) resp=\(trimmed.prefix(200))")
        guard trimmed.hasPrefix("0|") else {
            if trimmed.hasPrefix("2") { throw CpeError.locked }
            // 把设备原始响应带进错误，方便定位
            throw CpeError.server(trimmed.prefix(160).description)
        }
    }

    // MARK: - 数据接口

    /// 批量读取 XML 节点
    func getValues(_ mapping: [String: String]) async throws -> [String: String] {
        try await multipost(method: "get_value_by_xmlnode",
                            data: ["data_1": mapping])
            .compactMapValues { $0 as? String }
    }

    func multipost(method: String, data: [String: Any]) async throws -> [String: Any] {
        try await refreshSession()

        var payload: [String: Any] = [
            "ajaxmethod": method,
            "multipost": 1,
            "dataObj": data,
            "sessionid": sessionId
        ]
        _ = payload.removeValue(forKey: "unused")

        let plainData = try JSONSerialization.data(withJSONObject: payload,
                                                   options: [.sortedKeys])
        let plainStr = String(data: plainData, encoding: .utf8) ?? "{}"
        let body = aesEnabled ? try encrypt(plainStr) : plainStr

        let resp = try await rawRequest(path: "/api/tmp/FHAPIS?_\(Self.rnd())",
                                        body: body, method: "POST")
        return try decodeResponse(resp)
    }

    /// GET 型接口
    func get(_ method: String, nocheck: Bool = false) async throws -> [String: Any] {
        try await refreshSession()
        let path = "/api/tmp/\(nocheck ? "FHNCAPIS" : "FHAPIS")?ajaxmethod=\(method)&_=\(Self.rnd())"
        let resp = try await rawRequest(path: path)
        return try decodeResponse(resp)
    }

    private func decodeResponse(_ raw: String) throws -> [String: Any] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let d = Data(trimmed.utf8)
            return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        }
        guard let plain = try? decrypt(trimmed),
              let d = plain.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    /// 执行设备命令（重启等）
    func runCommand(_ key: String) async throws -> [String: Any] {
        try await multipost(method: "do_cmd_web", data: ["key": key])
    }

    /// 单节点设置
    func setSingle(url: String, value: String) async throws -> [String: Any] {
        try await refreshSession()
        let inner: [String: Any] = [
            "dataObj": ["url": url, "value": value],
            "ajaxmethod": "set_single_by_xmlnode",
            "sessionid": sessionId
        ]
        let plainData = try JSONSerialization.data(withJSONObject: inner)
        let plainStr = String(data: plainData, encoding: .utf8) ?? "{}"
        let body = aesEnabled ? try encrypt(plainStr) : plainStr
        let resp = try await rawRequest(path: "/api/tmp/FHAPIS?_\(Self.rnd())",
                                        body: body, method: "POST")
        return try decodeResponse(resp)
    }
}

enum CpeError: LocalizedError {
    case badHost, badResponse, noSession, cryptoFailed
    case http(Int), locked, badCredentials
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badHost:       return "设备地址无效"
        case .badResponse:   return "设备响应异常"
        case .noSession:     return "无法获取会话"
        case .cryptoFailed:  return "加解密失败"
        case .http(let c):   return "HTTP \(c)"
        case .locked:        return "登录被锁定，请等待 1 分钟后重试"
        case .badCredentials:return "用户名或密码错误"
        case .server(let s): return "设备返回: \(s)"
        }
    }
}
