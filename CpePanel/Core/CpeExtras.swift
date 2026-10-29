import Foundation

extension CpeAPI {
    /// 读取短信（设备返回 255 个槽位，过滤空记录）
    func fetchSms() async throws -> [CpeSms] {
        let r = try await multipost(method: "get_xml_childnode_value", data: [
            "data_1": [
                "url": "InternetGatewayDevice.X_FH_MobileNetwork.SMS_Recv.SMS_RecvMsg.",
                "node": ["Sender": "Sender", "Content": "Content",
                         "RecvTime": "RecvTime", "Index": "Index"]
            ]
        ])
        guard let d1 = r["data_1"] as? [String: Any],
              let rows = d1["data"] as? [[String: Any]] else { return [] }

        return rows.compactMap { row -> CpeSms? in
            let sender = (row["Sender"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let content = (row["Content"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !sender.isEmpty || !content.isEmpty else { return nil }
            return CpeSms(sender: sender, content: content,
                          time: row["RecvTime"] as? String ?? "")
        }
    }

    /// 应用频段锁定
    func applyBandLock(enable: Bool, nr: [Int], lte: [Int]) async throws {
        let ns = CpeNode.netSet
        _ = try await setSingle(url: ns + "LockBandEnable", value: enable ? "1" : "0")
        if !nr.isEmpty {
            _ = try await setSingle(url: ns + "NRLockBAND",
                                    value: nr.map(String.init).joined(separator: ","))
        }
        if !lte.isEmpty {
            _ = try await setSingle(url: ns + "LTELockBAND",
                                    value: lte.map(String.init).joined(separator: ","))
        }
    }

    /// 运营商锁定
    func applyCarrierLock(enable: Bool, serial: String) async throws {
        let ns = CpeNode.netSet
        _ = try await setSingle(url: ns + "CarrierLockEnable", value: enable ? "1" : "0")
        if !serial.isEmpty {
            _ = try await setSingle(url: ns + "CarrierSerialNum", value: serial)
        }
    }
}
