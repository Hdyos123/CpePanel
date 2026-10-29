import Foundation

/// 设备节点路径（从设备前端逆向得到）
enum CpeNode {
    static let netSet = "X_FH_MobileNetwork.NetworkSettings."
    static let radio  = "X_FH_MobileNetwork.RadioSignalParameter."
    static let sim    = "X_FH_MobileNetwork.SIM.1."
    static let traffic = "X_FH_MobileNetwork.TrafficStats."
    static let pcc    = "X_FH_MobileNetwork.NetworkInfo.PCCInfo."
    static let scc    = "X_FH_MobileNetwork.NetworkInfo.SCCInfos."
    static let hosts  = "LANDevice.1.Hosts."
    static let wlan   = "LANDevice.1.WLANConfiguration."
    static let wan    = "WANDevice.1.WANConnectionDevice.1.WANIPConnection.1."

    /// 总览字段映射
    static var overview: [String: String] {
        [
            "model": "DeviceInfo.ModelName",
            "sn": "DeviceInfo.SerialNumber",
            "swver": "DeviceInfo.SoftwareVersion",
            "hwver": "DeviceInfo.HardwareVersion",
            "vendor": "DeviceInfo.Manufacturer",
            "modem": "DeviceInfo.MobileModuleSoftwareVersion",
            "workmode": "DeviceInfo.X_FH_WorkMode",
            "cpu": "DeviceInfo.ProcessStatus.CPUUsage",
            "memFree": "DeviceInfo.MemoryStatus.Free",
            "memTotal": "DeviceInfo.MemoryStatus.Total",

            "carrier": sim + "CarrierName",
            "imsi": sim + "IMSI",
            "iccid": sim + "ICCID",
            "imei": sim + "IMEI",
            "phone": sim + "PhoneNumber",
            "netmode": sim + "NetworkMode",
            "regstatus": sim + "RegisterStatus",
            "simstatus": sim + "SIMStatus",

            "rsrp": radio + "SSB_RSRP",
            "rsrq": radio + "SSB_RSRQ",
            "rssi": radio + "SSB_RSSI",
            "sinr": radio + "SSB_SINR",
            "level": radio + "Signal_Level",
            "band": radio + "NR_Band",
            "pci": radio + "PCI",
            "tac": radio + "TAC",
            "qci": radio + "QCI",
            "ulmax": radio + "UL_AMBR",
            "dlmax": radio + "DL_AMBR",

            "arfcn": pcc + "pccArfcn",
            "bw": pcc + "pccDlBandWidth",
            "sccNum": scc + "Nums",

            "monthTx": traffic + "MonthTxBytes",
            "monthRx": traffic + "MonthRxBytes",
            "monthTotal": traffic + "MonthTotalBytes",
            "todayTotal": traffic + "TodayTotalBytes",
            "speedRx": traffic + "SpeedRxBytes",
            "speedTx": traffic + "SpeedTxBytes",

            "wanIP": wan + "ExternalIPAddress",
            "wanStatus": wan + "ConnectionStatus",
            "lanIP": "LANDevice.1.LANHostConfigManagement.IPInterface.2.IPInterfaceIPAddress",
            "online": hosts + "OnlineDevNum",
            "ssid24": wlan + "1.SSID",
            "ssid5g": wlan + "5.SSID",
            "tempRaw": "X_FH_MobileNetwork.Temperature.Modem4GTemperature",

            "airplane": netSet + "airplan_on",
            "roaming": netSet + "RoamingEnable",
            "volte": netSet + "volte_switch",
            "lockbandEn": netSet + "LockBandEnable",
            "lockbandNr": netSet + "NRLockBAND",
            "lockbandLte": netSet + "LTELockBAND",
            "carrierLockEn": netSet + "CarrierLockEnable",
            "carrierLockNum": netSet + "CarrierSerialNum",
        ]
    }
}

/// 总览数据
struct CpeStatus {
    var raw: [String: String] = [:]

    subscript(k: String) -> String { raw[k] ?? "" }

    /// 设备部分字段是小数（如 uptime "905.2"），先转 Double 再取整
    func int(_ k: String) -> Int {
        guard let s = raw[k], !s.isEmpty else { return 0 }
        if let i = Int(s) { return i }
        if let d = Double(s) { return Int(d) }
        return 0
    }
    func double(_ k: String) -> Double {
        guard let s = raw[k], !s.isEmpty else { return 0 }
        return Double(s) ?? 0
    }

    var carrierName: String {
        switch self["carrier"] {
        case "UNICOM": return "中国联通"
        case "CMCC":   return "中国移动"
        case "CT":     return "中国电信"
        default:       return self["carrier"].isEmpty ? "未知" : self["carrier"]
        }
    }

    var isOnline: Bool { self["regstatus"] == "0" && self["simstatus"] == "0" }

    /// 温度：设备返回 39163 这类整数，表示 39.163℃
    var temperature: Double? {
        guard let v = Double(self["tempRaw"]), v > 0 else { return nil }
        return v > 1000 ? v / 1000 : v
    }

    /// 实时速率（bit/s）
    var realtimeRx: Double { double("speedRx") * 8 }
    var realtimeTx: Double { double("speedTx") * 8 }
}

/// 在线设备
struct CpeHost: Identifiable {
    let id = UUID()
    var idx: String
    var name: String
    var mac: String
    var ip: String
    var iface: String
    var downLimit: String
    var upLimit: String

    var isWired: Bool { iface.uppercased().contains("ETHERNET") }
    var bandLabel: String {
        if isWired { return "有线" }
        return iface.contains("5G") ? "5G Wi-Fi" : "2.4G Wi-Fi"
    }
}

/// 短信
struct CpeSms: Identifiable {
    let id = UUID()
    var sender: String
    var content: String
    var time: String
}
