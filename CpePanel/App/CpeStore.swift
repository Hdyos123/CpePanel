import Foundation
import SwiftUI

@MainActor
final class CpeStore: ObservableObject {
    @Published var status = CpeStatus()
    @Published var hosts: [CpeHost] = []
    @Published var smsList: [CpeSms] = []
    @Published var isLoggedIn = false
    @Published var isLoading = false
    @Published var errorText: String?
    @Published var lastUpdate = Date()

    @Published var realtimeRx: Double = 0
    @Published var realtimeTx: Double = 0

    @Published var refreshInterval: Double {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "cpe.rateMs") }
    }

    private let bridge = CpeBridge.shared
    private var pollTask: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.double(forKey: "cpe.rateMs")
        refreshInterval = saved > 0 ? saved : 1.0
    }

    // MARK: - 登录

    func login(host: String, user: String, password: String) async -> Bool {
        errorText = nil
        isLoading = true
        defer { isLoading = false }

        let ok = await bridge.login(host: host, user: user, password: password)
        if ok {
            Settings(host: host, user: user, password: password).save()
            isLoggedIn = true
            await fetchAll()
            return true
        } else {
            errorText = bridge.lastError ?? "登录失败"
            return false
        }
    }

    func tryAutoLogin() async {
        let s = Settings.load()
        guard s.isConfigured else { return }
        let ok = await bridge.login(host: s.host, user: s.user, password: s.password)
        if ok {
            isLoggedIn = true
            await fetchAll()
        } else {
            errorText = bridge.lastError
        }
    }

    // MARK: - 数据

    func fetchAll() async {
        async let a: Void = fetchStatus()
        async let b: Void = fetchHosts()
        _ = await (a, b)
        lastUpdate = Date()
    }

    func fetchStatus() async {
        var v = await bridge.fetchValues(CpeNode.overview)
        guard !v.isEmpty else { return }

        // uptime 不在 XML 节点里，需单独走 get_cmd_result_web
        let cmd = await bridge.multipost(method: "get_cmd_result_web", data: [
            "data_1": ["key": "UPTIME"]
        ])
        if let first = cmd.first, let result = first["result"] as? String {
            v["uptime"] = result
        } else if let first = cmd.first, let num = first["result"] as? NSNumber {
            v["uptime"] = num.stringValue
        }

        status.raw = v
        realtimeRx = status.realtimeRx
        realtimeTx = status.realtimeTx
    }

    func fetchHosts() async {
        // Wi-Fi 关联设备（真实在线判断依据）
        let wifiRows = await bridge.multipost(method: "get_xml_childnode_value", data: [
            "data_1": [
                "url": "LANDevice.1.WLANConfiguration.",
                "node": ["AssociatedDevice": [
                    "url": "AssociatedDevice.",
                    "node": ["MAC": "AssociatedDeviceMACAddress"]
                ]]
            ]
        ])

        var onlineMacs = Set<String>()
        var wifiBand: [String: String] = [:]
        for (i, wl) in wifiRows.enumerated() {
            guard let ads = wl["AssociatedDevice"] as? [[String: Any]] else { continue }
            for ad in ads {
                let m = (ad["MAC"] as? String ?? "").uppercased()
                if !m.isEmpty {
                    onlineMacs.insert(m)
                    wifiBand[m] = i >= 4 ? "5G Wi-Fi" : "2.4G Wi-Fi"
                }
            }
        }

        // Hosts 表：名称 / 有线 / 限速
        let hostRows = await bridge.multipost(method: "get_xml_childnode_value", data: [
            "data_1": [
                "url": "LANDevice.1.Hosts.Host.",
                "node": ["HostName": "HostName", "MAC": "MACAddress",
                         "IP": "IPAddress", "Layer2": "Layer2Interface",
                         "Down": "MaxDSBandwidth", "Up": "MaxUSBandwidth"]
            ]
        ])

        var result: [CpeHost] = []
        var seen = Set<String>()
        for r in hostRows {
            let mac = (r["MAC"] as? String ?? "").uppercased()
            guard !mac.isEmpty, !seen.contains(mac) else { continue }
            let layer = r["Layer2"] as? String ?? ""
            let ip = (r["IP"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let wired = layer.uppercased().contains("ETHERNET")
            let online = wired ? !ip.isEmpty : onlineMacs.contains(mac)
            guard online else { continue }
            seen.insert(mac)
            result.append(CpeHost(
                idx: String(r["child_node_idx"] as? Int ?? 0),
                name: (r["HostName"] as? String) ?? "设备",
                mac: mac, ip: ip,
                iface: wired ? "Ethernet" : (wifiBand[mac] ?? "Wi-Fi"),
                downLimit: r["Down"] as? String ?? "0",
                upLimit: r["Up"] as? String ?? "0"))
        }
        for mac in onlineMacs where !seen.contains(mac) {
            result.append(CpeHost(idx: "", name: "移动设备", mac: mac, ip: "",
                                  iface: wifiBand[mac] ?? "Wi-Fi",
                                  downLimit: "0", upLimit: "0"))
        }
        hosts = result
    }

    func fetchSms() async -> [CpeSms] {
        let rows = await bridge.multipost(method: "get_xml_childnode_value", data: [
            "data_1": [
                "url": "InternetGatewayDevice.X_FH_MobileNetwork.SMS_Recv.SMS_RecvMsg.",
                "node": ["Sender": "Sender", "Content": "Content",
                         "RecvTime": "RecvTime"]
            ]
        ])
        return rows.compactMap { row -> CpeSms? in
            let sender = (row["Sender"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let content = (row["Content"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !sender.isEmpty || !content.isEmpty else { return nil }
            return CpeSms(sender: sender, content: content,
                          time: row["RecvTime"] as? String ?? "")
        }
    }

    // MARK: - 控制

    func setToggle(node: String, on: Bool) async -> Bool {
        let ok = await bridge.setSingle(url: node, value: on ? "1" : "0")
        if ok { await fetchStatus() }
        return ok
    }

    func reboot() async -> Bool {
        await bridge.runCommand("REBOOT_WEB")
    }

    /// 频段锁定
    func applyBandLock(enable: Bool, nr: [Int], lte: [Int]) async -> Bool {
        let ns = CpeNode.netSet
        var ok = await bridge.setSingle(url: ns + "LockBandEnable", value: enable ? "1" : "0")
        if !nr.isEmpty {
            ok = await bridge.setSingle(url: ns + "NRLockBAND",
                                        value: nr.map(String.init).joined(separator: ",")) && ok
        }
        if !lte.isEmpty {
            ok = await bridge.setSingle(url: ns + "LTELockBAND",
                                        value: lte.map(String.init).joined(separator: ",")) && ok
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await fetchStatus()
        return ok
    }

    /// 运营商锁定
    func applyCarrierLock(enable: Bool, serial: String) async -> Bool {
        let ns = CpeNode.netSet
        var ok = await bridge.setSingle(url: ns + "CarrierLockEnable", value: enable ? "1" : "0")
        if !serial.isEmpty {
            ok = await bridge.setSingle(url: ns + "CarrierSerialNum", value: serial) && ok
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await fetchStatus()
        return ok
    }

    /// 重命名设备
    func renameHost(idx: String, name: String) async -> Bool {
        await bridge.setSingle(url: "LANDevice.1.Hosts.Host.\(idx).X_FH_DevName", value: name)
    }

    /// 限速（Mbps → Kbps）
    func limitHost(idx: String, down: String, up: String) async -> Bool {
        let base = "LANDevice.1.Hosts.Host.\(idx)."
        let dK = String(Int((Double(down) ?? 0) * 1024))
        let uK = String(Int((Double(up) ?? 0) * 1024))
        let ok1 = await bridge.setSingle(url: base + "MaxDSBandwidth", value: dK)
        let ok2 = await bridge.setSingle(url: base + "MaxUSBandwidth", value: uK)
        return ok1 && ok2
    }

    /// 发送短信
    func sendSms(to: String, text: String) async -> Bool {
        let rows = await bridge.multipost(method: "send_sms",
                                          data: ["phone_number": to, "content": text])
        _ = rows
        return true
    }

    // MARK: - 轮询

    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchStatus()
                let ns = UInt64(max(0.3, self.refreshInterval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
