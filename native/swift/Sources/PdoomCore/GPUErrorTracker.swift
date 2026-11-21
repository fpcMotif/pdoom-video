import Metal

public final class GPUErrorTracker: @unchecked Sendable {
  public static let shared = GPUErrorTracker()
  private let lock = NSLock()
  private var firstError: String?

  public func commitTracked(_ cmd: MTLCommandBuffer) {
    cmd.addCompletedHandler { buf in
      guard let e = buf.error else { return }
      self.lock.lock()
      if self.firstError == nil { self.firstError = "\(e)" }
      self.lock.unlock()
    }
    cmd.commit()
  }

  public func checkAndClear() throws {
    lock.lock()
    let e = firstError
    firstError = nil
    lock.unlock()
    if let e { throw EncoderError.failed("Metal command buffer failed: \(e)") }
  }
}
