import SwiftUI

// MARK: - 锁频

struct LockBandView: View {
    @EnvironmentObject var store: CpeStore

    @State private var lockEnabled = false
    @State private var selectedNR: Set<Int> = []
    @State private var selectedLTE: Set<Int> = []
    @State private var carrierEnabled = false
    @State private var carrierSerial = ""
    @State private var busy = false
    @State private var showConfirm = false
    @State private var pendingAction = ""

    private let nrBands = [1, 3, 5, 8, 28, 41, 77, 78, 79]
    private let lteBands = [1, 3, 5, 8, 34, 38, 39, 40, 41]

    private var s: CpeStatus { store.status }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前频段")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("N\(s["band"].isEmpty ? "--" : s["band"])")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.blue)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("PCI").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(s["pci"].isEmpty ? "--" : s["pci"])
                                .font(.system(size: 15, weight: .semibold))
                        }
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("带宽").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(s["bw"].isEmpty ? "--" : s["bw"])
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .padding(.vertical, 3)
                }

                Section {
                    Toggle("启用频段锁定", isOn: $lockEnabled)
                } header: {
                    Text("5G NR")
                } footer: {
                    Text("锁定后设备将只在选定频段工作，可能影响信号。")
                }

                Section {
                    ForEach(nrBands, id: \.self) { b in
                        bandRow("n\(b)", selected: selectedNR.contains(b)) {
                            toggleNR(b)
                        }
                    }
                }

                Section("4G LTE") {
                    ForEach(lteBands, id: \.self) { b in
                        bandRow("B\(b)", selected: selectedLTE.contains(b)) {
                            toggleLTE(b)
                        }
                    }
                }

                Section {
                    Button {
                        pendingAction = "band"
                        showConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? "应用中…" : "应用频段锁定")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                    }
                    .disabled(busy)
                }

                Section {
                    Toggle("启用运营商锁定", isOn: $carrierEnabled)
                    if carrierEnabled {
                        HStack {
                            Text("运营商代码")
                            Spacer()
                            TextField("46001", text: $carrierSerial)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                        }
                    }
                    Button {
                        pendingAction = "carrier"
                        showConfirm = true
                    } label: {
                        Text("应用运营商锁定")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(busy)
                } header: {
                    Text("运营商锁定")
                } footer: {
                    Text("联通 46001 · 移动 46000 · 电信 46011")
                }
            }
            .navigationTitle("锁频")
            .task { loadCurrent() }
            .alert("确认操作", isPresented: $showConfirm) {
                Button("取消", role: .cancel) { }
                Button("确定") { applyPending() }
            } message: {
                Text(pendingAction == "band"
                     ? "将锁定频段，网络会重新注册并短暂断网。确定继续？"
                     : "将锁定运营商，网络会重新注册。确定继续？")
            }
        }
    }

    private func bandRow(_ label: String, selected: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    private func toggleNR(_ b: Int) {
        if selectedNR.contains(b) { selectedNR.remove(b) } else { selectedNR.insert(b) }
    }

    private func toggleLTE(_ b: Int) {
        if selectedLTE.contains(b) { selectedLTE.remove(b) } else { selectedLTE.insert(b) }
    }

    private func loadCurrent() {
        lockEnabled = store.status["lockbandEn"] == "1"
        carrierEnabled = store.status["carrierLockEn"] == "1"
        carrierSerial = store.status["carrierLockNum"]

        let nr = store.status["lockbandNr"]
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        selectedNR = Set(nr)

        let lte = store.status["lockbandLte"]
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        selectedLTE = Set(lte)
    }

    private func applyPending() {
        busy = true
        Task {
            defer { busy = false }
            do {
                if pendingAction == "band" {
                    try await CpeAPI.shared.applyBandLock(
                        enable: lockEnabled,
                        nr: Array(selectedNR).sorted(),
                        lte: Array(selectedLTE).sorted())
                } else {
                    try await CpeAPI.shared.applyCarrierLock(
                        enable: carrierEnabled, serial: carrierSerial)
                }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await store.fetchStatus()
            } catch {
                store.errorText = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}

// MARK: - 短信

struct SmsView: View {
    @EnvironmentObject var store: CpeStore
    @State private var list: [CpeSms] = []
    @State private var loading = false
    @State private var showCompose = false
    @State private var composeTo = ""
    @State private var composeText = ""

    var body: some View {
        NavigationStack {
            Group {
                if loading && list.isEmpty {
                    ProgressView("读取中…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if list.isEmpty {
                    ContentUnavailableView("暂无短信",
                                           systemImage: "message",
                                           description: Text("收件箱是空的"))
                } else {
                    List(list) { m in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(m.sender.isEmpty ? "未知号码" : m.sender)
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Text(m.time)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Text(m.content)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                        .padding(.vertical, 3)
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("短信")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showCompose) {
                composeSheet.presentationDetents([.medium])
            }
            .task { await load() }
        }
    }

    private var composeSheet: some View {
        NavigationStack {
            Form {
                Section("接收号码") {
                    TextField("手机号", text: $composeTo)
                        .keyboardType(.phonePad)
                }
                Section("内容") {
                    TextField("短信内容", text: $composeText, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section {
                    Button {
                        sendSms()
                    } label: {
                        Text("发送").frame(maxWidth: .infinity)
                    }
                    .disabled(composeTo.isEmpty || composeText.isEmpty)
                }
            }
            .navigationTitle("发送短信")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showCompose = false }
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let result = try? await CpeAPI.shared.fetchSms() {
            list = result
        }
    }

    private func sendSms() {
        Task {
            do {
                _ = try await CpeAPI.shared.multipost(method: "send_sms", data: [
                    "phone_number": composeTo,
                    "content": composeText
                ])
                composeTo = ""
                composeText = ""
                showCompose = false
            } catch {
                store.errorText = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
