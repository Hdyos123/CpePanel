import SwiftUI

// MARK: - 设备列表（含改名 / 限速）

struct DeviceSheet: View {
    let hosts: [CpeHost]
    @EnvironmentObject var store: CpeStore
    @Environment(\.dismiss) var dismiss

    @State private var editing: CpeHost?
    @State private var editName = ""
    @State private var editDown = ""
    @State private var editUp = ""
    @State private var busy = false
    @State private var showConfirm = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(hosts) { h in
                    HStack(spacing: 11) {
                        Image(systemName: h.isWired ? "desktopcomputer" : "iphone")
                            .font(.system(size: 16))
                            .foregroundStyle(.blue)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 11)
                                .fill(Color.blue.opacity(0.1)))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.name).font(.system(size: 14, weight: .medium))
                            Text("\(h.ip.isEmpty ? h.mac : h.ip) · \(h.bandLabel)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            if let lim = limitText(h) {
                                Text(lim).font(.system(size: 10)).foregroundStyle(.orange)
                            }
                        }
                        Spacer()

                        Button {
                            beginEdit(h)
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .background(RoundedRectangle(cornerRadius: 9)
                                    .fill(Color.secondary.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .disabled(h.idx.isEmpty)
                    }
                    .padding(.vertical, 3)
                }
            }
            .navigationTitle("设备列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(item: $editing) { h in
                editorSheet(h)
                    .presentationDetents([.medium])
            }
            .alert("确认修改", isPresented: $showConfirm) {
                Button("取消", role: .cancel) { }
                Button("保存") { commitEdit() }
            } message: {
                Text(confirmText)
            }
        }
    }

    private var confirmText: String {
        var parts: [String] = []
        if !editName.isEmpty { parts.append("名称改为「\(editName)」") }
        if !editDown.isEmpty { parts.append("下行限速 \(editDown) Mbps") }
        if !editUp.isEmpty { parts.append("上行限速 \(editUp) Mbps") }
        return parts.isEmpty ? "没有修改" : "将" + parts.joined(separator: "，") + "。确定保存？"
    }

    private func limitText(_ h: CpeHost) -> String? {
        let d = (Double(h.downLimit) ?? 0) / 1024
        let u = (Double(h.upLimit) ?? 0) / 1024
        guard d > 0 || u > 0 else { return nil }
        var s = "限速 "
        if d > 0 { s += "↓\(Int(d))M " }
        if u > 0 { s += "↑\(Int(u))M" }
        return s
    }

    private func beginEdit(_ h: CpeHost) {
        editing = h
        editName = h.name
        let d = (Double(h.downLimit) ?? 0) / 1024
        let u = (Double(h.upLimit) ?? 0) / 1024
        editDown = d > 0 ? String(Int(d)) : ""
        editUp = u > 0 ? String(Int(u)) : ""
    }

    private func editorSheet(_ h: CpeHost) -> some View {
        NavigationStack {
            Form {
                Section("设备名称") {
                    TextField("输入名称", text: $editName)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    HStack {
                        Text("下行限速")
                        Spacer()
                        TextField("0", text: $editDown)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("Mbps").foregroundStyle(.secondary).font(.system(size: 13))
                    }
                    HStack {
                        Text("上行限速")
                        Spacer()
                        TextField("0", text: $editUp)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("Mbps").foregroundStyle(.secondary).font(.system(size: 13))
                    }
                } header: {
                    Text("速度限制")
                } footer: {
                    Text("填 0 表示不限速。修改后设备会重新应用。")
                }
                Section {
                    Button {
                        showConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? "保存中…" : "保存")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle(h.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { editing = nil }
                }
            }
        }
    }

    private func commitEdit() {
        guard let h = editing else { return }
        let idx = h.idx
        guard !idx.isEmpty else { return }

        busy = true
        Task {
            defer { busy = false }
            // 改名
            if editName != h.name && !editName.isEmpty {
                _ = await store.renameHost(idx: idx, name: editName)
            }
            // 限速（输入为空则不修改，填 0 则解除）
            if !editDown.isEmpty || !editUp.isEmpty {
                _ = await store.limitHost(idx: idx,
                                          down: editDown.isEmpty ? "0" : editDown,
                                          up: editUp.isEmpty ? "0" : editUp)
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await store.fetchHosts()
            editing = nil
        }
    }
}
