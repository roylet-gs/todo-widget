import SwiftUI

/// A read-only prompt with a Copy button. Prompts are agent-agnostic: paste them into any agent.
struct PromptBlock: View {
    let title: String
    let subtitle: String
    let text: String
    var minHeight: CGFloat = 160
    var maxHeight: CGFloat = 320
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(copied ? "Copied" : "Copy") {
                    Integrations.copy(text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .glassButton(prominent: true)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(.fill.quaternary, in: .rect(cornerRadius: 16))
        }
    }
}

/// Working hours and cadence for the scheduled sync. Stored in the core so the schedule prompt,
/// the CLI and the built-in runner agree.
struct ScheduleEditor: View {
    let model: AppModel
    @State private var config = ScheduleConfig(weekdaysOnly: true, startHour: 9, endHour: 17, intervalMinutes: 60)
    @State private var loaded = false

    var body: some View {
        HStack(spacing: 14) {
            Picker("Days", selection: $config.weekdaysOnly) {
                Text("Weekdays").tag(true)
                Text("Every day").tag(false)
            }
            Picker("Every", selection: $config.intervalMinutes) {
                ForEach([UInt32(30), 60, 120, 180], id: \.self) { m in Text(m < 60 ? "\(m) min" : m == 60 ? "hour" : "\(m / 60) hours").tag(m) }
            }
            Picker("From", selection: $config.startHour) {
                ForEach(UInt8(0)..<UInt8(24), id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
            Picker("To", selection: $config.endHour) {
                ForEach(UInt8(1)...UInt8(24), id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
        }
        .fixedSize()
        .onAppear {
            if let c = try? model.store.getSchedule() { config = c }
            loaded = true
        }
        .onChange(of: config) { _, c in
            guard loaded else { return }
            if c.startHour >= c.endHour {
                config.endHour = min(24, c.startHour + 1)
                return
            }
            try? model.store.setSchedule(schedule: c)
        }
    }
}
