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

    private var pollTask: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.double(forKey: "cpe.rateMs")
        refreshInterval = saved > 0 ? saved : 1.0
    }

    // MARK: - 登录

    func login(host: String, user: String, password: String) async -> Bool {
        errorText = nil
        CpeAPI.shared.update(host: host, user: user, password: password)
        do {
            try await CpeAPI.shared.login()
            Settings(host: host, user: user, password: password).save()
            isLoggedIn = true
            await fetchAll()
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func tryAutoLogin() async {
        let s = Settings.load()
        guard s.isConfigured else { return }
        CpeAPI.shared.update(host: s.host, user: s.user, password: s.password)
        do {
            try await CpeAPI.shared.login()
            isLoggedIn = true
            await fetchAll()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - 数据拉取

    func fetchAll() async {
        async let a: Void = fetchStatus()
        async let b: Void = fetchHosts()
        _ = await (a, b)
        lastUpdate = Date()
    }

    func fetchStatus() async {
        do {
            let map = CpeNode.overview
            let v = try await CpeAPI.shared.getValues(map)
            status.raw = v
            realtimeRx = status.realtimeRx
            realtimeTx = status.realtimeTx
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func fetchHosts() async {
        do {
            // 1. Wi-Fi 关联设备（真实在线）
            let wifi = try await CpeAPI.shared.multipost(method: "get_xml_childnode_value", data: [
                "data_1": [
                    "url": "LANDevice.1.WLANConfiguration.",
                    "node": ["AssociatedDevice": [
                        "url": "AssociatedDevice.",
                        "node": ["MAC": "AssociatedDeviceMACAddress",
                                 "RSSI": "AssociatedDeviceRSSI"]
                    ]]
                ]
            ])
            var onlineMacs = Set<String>()
            var wifiBand: [String: String] = [:]
            if let d1 = wifi["data_1"] as? [String: Any],
               let arr = d1["data"] as? [[String: Any]] {
                for (i, wl) in arr.enumerated() {
                    guard let ads = wl["AssociatedDevice"] as? [[String: Any]] else { continue }
                    for ad in ads {
                        if let m = (ad["MAC"] as? String)?.uppercased(), !m.isEmpty {
                            onlineMacs.insert(m)
                            wifiBand[m] = i >= 4 ? "5G Wi-Fi" : "2.4G Wi-Fi"
                        }
                    }
                }
            }

            // 2. Hosts 表：拿名称 / 有线在线 / 限速
            let hh = try await CpeAPI.shared.multipost(method: "get_xml_childnode_value", data: [
                "data_1": [
                    "url": "LANDevice.1.Hosts.Host.",
                    "node": ["HostName": "HostName", "MAC": "MACAddress",
                             "IP": "IPAddress", "Layer2": "Layer2Interface",
                             "Down": "MaxDSBandwidth", "Up": "MaxUSBandwidth"]
                ]
            ])

            var result: [CpeHost] = []
            var seen = Set<String>()
            if let d = hh["data_1"] as? [String: Any],
               let rows = d["data"] as? [[String: Any]] {
                for r in rows {
                    let mac = (r["MAC"] as? String ?? "").uppercased()
                    guard !mac.isEmpty, !seen.contains(mac) else { continue }
                    let layer = r["Layer2"] as? String ?? ""
                    let ip = (r["IP"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                    let wired = layer.uppercased().contains("ETHERNET")
                    let isOnline = wired ? !ip.isEmpty : onlineMacs.contains(mac)
                    guard isOnline else { continue }
                    seen.insert(mac)
                    let idx = String(r["child_node_idx"] as? Int ?? 0)
                    result.append(CpeHost(
                        idx: idx,
                        name: (r["HostName"] as? String) ?? "设备",
                        mac: mac, ip: ip,
                        iface: wired ? "Ethernet" : (wifiBand[mac] ?? "Wi-Fi"),
                        downLimit: r["Down"] as? String ?? "0",
                        upLimit: r["Up"] as? String ?? "0"))
                }
            }
            // 补充：Wi-Fi 在线但 Hosts 表没有的
            for mac in onlineMacs where !seen.contains(mac) {
                result.append(CpeHost(idx: "", name: "移动设备", mac: mac, ip: "",
                                      iface: wifiBand[mac] ?? "Wi-Fi",
                                      downLimit: "0", upLimit: "0"))
            }
            hosts = result
        } catch {
            // 静默失败，保留旧数据
        }
    }

    // MARK: - 控制

    func setToggle(_ node: String, on: Bool) async -> Bool {
        do {
            _ = try await CpeAPI.shared.setSingle(url: node, value: on ? "1" : "0")
            await fetchStatus()
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func reboot() async -> Bool {
        do {
            _ = try await CpeAPI.shared.runCommand("REBOOT_WEB")
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
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
