import Foundation

let cal = Calendar.current
let now = cal.date(bySettingHour: 23, minute: 1, second: 45, of: Date())!
let mins = cal.component(.minute, from: now)
let extraMins = 30 - (mins % 30)
if let snapped = cal.date(byAdding: .minute, value: extraMins, to: now) {
    let final = cal.date(bySetting: .second, value: 0, of: snapped) ?? snapped
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss"
    print("Now: \(df.string(from: now))")
    print("Snapped: \(df.string(from: snapped))")
    print("Final: \(df.string(from: final))")
}
