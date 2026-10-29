import Foundation
import UIKit
import WebKit
import Combine

/// 用隐藏的 WKWebView 承载 CPE 会话：
/// - 页面自己处理 AES 加解密和 sessionid
/// - 我们只负责在 JS 上下文里调用 $post / $multipost 取数据
@MainActor
final class CpeBridge: NSObject, ObservableObject {
    static let shared = CpeBridge()

    @Published var ready = false
    @Published var lastError: String?

    private var webView: WKWebView?
    private var host: String = "192.168.8.1"
    private weak var container: UIView?
    private var pendingLogin: CheckedContinuation<Bool, Never>?

    private override init() { super.init() }

    // MARK: - 建立会话

    /// 伪装成 iPhone Safari 的 UA
    /// CPE 固件常按 UA 判断浏览器类型，默认 WKWebView UA 会带
    /// "Mobile/xxx" 但没有 Safari 标识，可能被当作不支持的客户端
    static var safariUA: String {
        let v = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(v) like Mac OS X) "
             + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
             + "Version/\(UIDevice.current.systemVersion.prefix(2)).0 "
             + "Mobile/15E148 Safari/604.1"
    }

    func attach(to view: UIView) {
        container = view
        guard webView == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // 保留 cookie
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true

        let wv = WKWebView(frame: .zero, configuration: cfg)

        // 关键：设置 Safari UA
        wv.customUserAgent = Self.safariUA
        // 同时注入到 navigator，避免 JS 侧检测（部分固件会读 navigator.userAgent）
        let uaJS = """
        Object.defineProperty(navigator, 'userAgent', {
          get: function(){ return '\(Self.safariUA)'; }
        });
        Object.defineProperty(navigator, 'appVersion', {
          get: function(){ return '5.0 (iPhone; CPU iPhone OS \(UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(UIDevice.current.systemVersion.prefix(2)).0 Mobile/15E148 Safari/604.1'; }
        });
        """
        let script = WKUserScript(source: uaJS,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false)
        cfg.userContentController.addUserScript(script)

        wv.navigationDelegate = self
        wv.isHidden = true
        wv.alpha = 0.01                            // 必须留一点透明度，否则可能不加载
        wv.isUserInteractionEnabled = false
        view.addSubview(wv)
        wv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wv.widthAnchor.constraint(equalToConstant: 1),
            wv.heightAnchor.constraint(equalToConstant: 1),
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.topAnchor.constraint(equalTo: view.topAnchor)
        ])
        webView = wv
    }

    /// 加载登录页并完成登录
    func login(host: String, user: String, password: String) async -> Bool {
        self.host = host
        guard let wv = webView else {
            lastError = "WebView 未初始化"
            return false
        }
        let base = host.hasPrefix("http") ? host : "http://\(host)"
        guard let url = URL(string: base + "/login.html") else {
            lastError = "地址无效"
            return false
        }

        ready = false
        // 清掉旧 cookie，确保干净会话
        await clearCookies()

        return await withCheckedContinuation { cont in
            pendingLogin = cont
            loginCreds = (user, password)
            var req = URLRequest(url: url)
            req.setValue(Self.safariUA, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
            req.setValue("zh-CN,zh-Hans;q=0.9", forHTTPHeaderField: "Accept-Language")
            req.setValue("keep-alive", forHTTPHeaderField: "Connection")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            wv.load(req)
        }
    }

    private var loginCreds: (String, String)?

    private func performLoginJS() async -> Bool {
        guard let (user, password) = loginCreds else { return false }
        let uEsc = jsEscape(user)
        let pEsc = jsEscape(password)

        // 调用页面自己的登录流程，并用 axios 接口完成
        let js = """
        (function(){
          return new Promise(function(resolve){
            try {
              var sid = null;
              $post('DO_WEB_LOGIN', {username:'\(uEsc)', password:'\(pEsc)'})
                .then(function(res){
                  var s = (res && res.data) ? String(res.data) : String(res);
                  if (s.indexOf('0|') === 0) resolve('OK');
                  else resolve('FAIL:' + s);
                })
                .catch(function(e){ resolve('ERR:' + (e && e.message ? e.message : e)); });
            } catch(e) { resolve('EXC:' + e.message); }
          });
        })()
        """
        let result = await evaluate(js)
        let str = (result as? String) ?? ""
        if str.hasPrefix("OK") {
            ready = true
            lastError = nil
            return true
        }
        if str.contains("FAIL:4") {
            lastError = "用户名或密码错误"
        } else if str.contains("FAIL:2") || str.contains("FAIL:3") {
            lastError = "登录被锁定，请等待 1 分钟"
        } else {
            lastError = "登录失败：\(str)"
        }
        return false
    }

    // MARK: - 数据接口

    /// 批量读 XML 节点。mapping: [别名: 节点路径]
    func fetchValues(_ mapping: [String: String]) async -> [String: String] {
        guard ready, webView != nil else { return [:] }
        let json = (try? JSONSerialization.data(withJSONObject: mapping)) ?? Data()
        let mapStr = String(data: json, encoding: .utf8) ?? "{}"

        let js = """
        (function(){
          return new Promise(function(resolve){
            try {
              $multipost('get_value_by_xmlnode', \(mapStr))
                .then(function(r){
                  var d = (r && r.data_1) ? r.data_1 : (r && r.data ? r.data : r);
                  resolve(JSON.stringify(d || {}));
                })
                .catch(function(e){ resolve('{}'); });
            } catch(e) { resolve('{}'); }
          });
        })()
        """
        let raw = await evaluate(js)
        guard let s = raw as? String,
              let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let str = v as? String { out[k] = str }
            else if let num = v as? NSNumber { out[k] = num.stringValue }
        }
        return out
    }

    /// 通用 multipost（设备、短信等）
    func multipost(method: String, data: [String: Any]) async -> [[String: Any]] {
        let dataJSON = (try? JSONSerialization.data(withJSONObject: data)) ?? Data()
        let dataStr = String(data: dataJSON, encoding: .utf8) ?? "{}"
        let m = jsEscape(method)

        let js = """
        (function(){
          return new Promise(function(resolve){
            try {
              $multipost('\(m)', \(dataStr))
                .then(function(r){
                  var d = (r && r.data_1) ? r.data_1 : r;
                  var arr = (d && d.data) ? d.data : (Array.isArray(d) ? d : []);
                  resolve(JSON.stringify(arr));
                })
                .catch(function(e){ resolve('[]'); });
            } catch(e) { resolve('[]'); }
          });
        })()
        """
        let raw = await evaluate(js)
        guard let s = raw as? String,
              let d = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else {
            return []
        }
        return arr
    }

    /// 单节点设置
    func setSingle(url: String, value: String) async -> Bool {
        let u = jsEscape(url), v = jsEscape(value)
        let js = """
        (function(){
          return new Promise(function(resolve){
            $post('set_single_by_xmlnode', {url:'\(u)', value:'\(v)'})
              .then(function(){ resolve('OK'); })
              .catch(function(e){ resolve('ERR'); });
          });
        })()
        """
        let r = await evaluate(js) as? String
        return r == "OK"
    }

    /// 执行设备命令（重启）
    func runCommand(_ key: String) async -> Bool {
        let k = jsEscape(key)
        let js = """
        (function(){
          return new Promise(function(resolve){
            $post('do_cmd_web', {key:'\(k)'})
              .then(function(){ resolve('OK'); })
              .catch(function(e){ resolve('ERR'); });
          });
        })()
        """
        let r = await evaluate(js) as? String
        return r == "OK"
    }

    // MARK: - 底层

    private func evaluate(_ js: String) async -> Any? {
        guard let wv = webView else { return nil }
        do {
            return try await wv.evaluateJavaScript(js)
        } catch {
            return nil
        }
    }

    private func clearCookies() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
    }

    private func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "")
    }
}

extension CpeBridge: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // 页面就绪后执行登录
            guard pendingLogin != nil else { return }
            let ok = await performLoginJS()
            pendingLogin?.resume(returning: ok)
            pendingLogin = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            lastError = "无法连接设备：\(error.localizedDescription)"
            pendingLogin?.resume(returning: false)
            pendingLogin = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            lastError = "无法连接设备：\(error.localizedDescription)"
            pendingLogin?.resume(returning: false)
            pendingLogin = nil
        }
    }
}
