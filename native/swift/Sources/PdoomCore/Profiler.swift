import Foundation

public final class Profiler: @unchecked Sendable {
  public static let shared = Profiler()
  public let enabled = ProcessInfo.processInfo.environment["PDOOM_PROFILE"] != nil
  private var totals: [String: (time: Double, count: Int)] = [:]
  private let lock = NSLock()

  @discardableResult
  public func time<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
    guard enabled else { return try body() }
    let start = DispatchTime.now()
    let result = try body()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    lock.lock()
    var v = totals[name] ?? (0, 0)
    v.time += elapsed; v.count += 1
    totals[name] = v
    lock.unlock()
    return result
  }

  public func report() {
    guard enabled else { return }
    let rows = totals.sorted { $0.value.time > $1.value.time }
    let grandTotal = rows.reduce(0.0) { $0 + $1.value.time }
    print("--- profile (PDOOM_PROFILE=1) ---")
    for (k, v) in rows {
      let avgMs = v.time / Double(v.count) * 1000
      let pct = grandTotal > 0 ? v.time / grandTotal * 100 : 0
      let name = k.padding(toLength: 24, withPad: " ", startingAt: 0)
      print("\(name) \(String(format: "%8.3fs  n=%-6d  avg %8.3fms  %5.1f%%", v.time, v.count, avgMs, pct))")
    }
  }
}
