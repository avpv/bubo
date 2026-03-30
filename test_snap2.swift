import Foundation

let cal = Calendar.current
let now = cal.date(bySettingHour: 23, minute: 1, second: 45, of: Date())!

var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
let currentMins = comps.minute ?? 0
comps.minute = currentMins + (30 - (currentMins % 30))
let final = cal.date(from: comps) ?? now

let df = DateFormatter()
df.dateFormat = "HH:mm:ss"
print("Now: \(df.string(from: now))")
print("Final: \(df.string(from: final))")
