import Foundation

public enum SpaceMetric: String, CaseIterable, Sendable {
  case logical, allocated
}

public enum SpaceFailure: Error, Sendable { case missingRoot }

public struct VolumeMeasure: Sendable {
  public let path: String
  public let totalBytes: Int64?
  public let freeBytes: Int64?
  public let usedBytes: Int64?

  public init(path: String, totalBytes: Int64?, freeBytes: Int64?) {
    self.path = path
    self.totalBytes = totalBytes
    self.freeBytes = freeBytes
    if let totalBytes, let freeBytes, totalBytes >= freeBytes {
      self.usedBytes = totalBytes - freeBytes
    } else {
      self.usedBytes = nil
    }
  }
}

public enum VolumeMeasurer {
  public static func measure(path: String) async -> VolumeMeasure {
    await Task.detached {
      let url = URL(fileURLWithPath: path)
      let values = try? url.resourceValues(forKeys: [
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
      ])
      return VolumeMeasure(
        path: path,
        totalBytes: values?.volumeTotalCapacity.map(Int64.init),
        freeBytes: values?.volumeAvailableCapacity.map(Int64.init))
    }.value
  }
}
