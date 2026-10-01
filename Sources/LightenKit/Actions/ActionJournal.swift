import CryptoKit
import Darwin
import Foundation

public enum JournalEventKind: String, Codable, Sendable {
  case intent, applied, failed, skipped, undoIntent, reversed, undoFailed, deleteProgress
}

public struct JournalRecord: Codable, Sendable, Equatable {
  public let schema: Int
  public let eventID: UUID
  public let at: Date
  public let kind: JournalEventKind
  public let planID: UUID
  public let itemID: UUID?
  public let plan: ActionPlan?
  public let planReference: JournalPlanReference?
  public let returnedTrashPath: String?
  public let movedIdentity: FileIdentity?
  public let detail: String?
  public let deletedCount: Int?
  public let deletedLogicalBytes: Int64?

  public init(
    kind: JournalEventKind, planID: UUID, itemID: UUID? = nil,
    plan: ActionPlan? = nil, returnedTrashPath: String? = nil,
    movedIdentity: FileIdentity? = nil, detail: String? = nil,
    deletedCount: Int? = nil, deletedLogicalBytes: Int64? = nil
  ) {
    self.schema = 1
    self.eventID = UUID()
    self.at = Date()
    self.kind = kind
    self.planID = planID
    self.itemID = itemID
    self.plan = plan
    self.planReference = nil
    self.returnedTrashPath = returnedTrashPath
    self.movedIdentity = movedIdentity
    self.detail = detail
    self.deletedCount = deletedCount
    self.deletedLogicalBytes = deletedLogicalBytes
  }

  private init(_ record: JournalRecord, plan: ActionPlan?, reference: JournalPlanReference?) {
    schema = reference == nil ? record.schema : 2
    eventID = record.eventID
    at = record.at
    kind = record.kind
    planID = record.planID
    itemID = record.itemID
    self.plan = plan
    planReference = reference
    returnedTrashPath = record.returnedTrashPath
    movedIdentity = record.movedIdentity
    detail = record.detail
    deletedCount = record.deletedCount
    deletedLogicalBytes = record.deletedLogicalBytes
  }

  var summary: JournalPlanSummary? {
    plan.map(JournalPlanSummary.init) ?? planReference?.summary
  }

  func externalized(_ reference: JournalPlanReference) -> JournalRecord {
    JournalRecord(self, plan: nil, reference: reference)
  }

  func hydrated(_ plan: ActionPlan) -> JournalRecord {
    JournalRecord(self, plan: plan, reference: planReference)
  }

}

public struct JournalIssue: Sendable, Equatable {
  public let line: Int
  public let reason: String
}

public struct JournalReadout: Sendable {
  public internal(set) var records: [JournalRecord]
  public let issues: [JournalIssue]
}

public struct JournalLease: Sendable, Equatable {
  public let id: UUID
  public init(id: UUID = UUID()) { self.id = id }
}

public protocol ActionJournal: Sendable {
  func acquireMutationLease() async throws -> JournalLease
  func releaseMutationLease(_ lease: JournalLease) async
  func append(_ record: JournalRecord) async throws
  func read() async throws -> JournalReadout
  func readSummary() async throws -> JournalReadout
  func loadPlan(id: UUID) async throws -> ActionPlan
}

extension ActionJournal {
  public func readSummary() async throws -> JournalReadout { try await read() }

  public func loadPlan(id: UUID) async throws -> ActionPlan {
    let readout = try await read()
    guard readout.issues.isEmpty,
      let plan = readout.records.first(where: { $0.kind == .intent && $0.planID == id })?.plan
    else { throw JournalFailure.corruptHistory }
    return plan
  }

  public func withMutationLease<T: Sendable>(
    _ operation: @Sendable () async throws -> T
  ) async throws -> T {
    let lease = try await acquireMutationLease()
    do {
      let value = try await operation()
      await releaseMutationLease(lease)
      return value
    } catch {
      await releaseMutationLease(lease)
      throw error
    }
  }
}

public enum JournalFailure: Error, Sendable {
  case corruptHistory, leaseBusy, leaseRequired
  case systemCall(String, Int32)
  case invalidEncoding
}

/// Append-only JSONL with a nonblocking filesystem lease for mutations.
/// Each accepted record is complete and fsynced before its caller proceeds.
public actor JSONLActionJournal: ActionJournal {
  private struct ItemKey: Hashable {
    let planID: UUID
    let itemID: UUID
  }
  public let path: String
  private let syncFD: @Sendable (Int32) throws -> Void
  private var heldLease: JournalLease?
  private var lockFD: Int32 = -1
  private var cached: JournalReadout?
  private var cachedStamp: FileStamp?
  private var plans: [UUID: JournalPlanSummary] = [:]
  private var states: [ItemKey: JournalEventKind] = [:]
  private var progress: [ItemKey: (Int, Int64)] = [:]

  private struct FileStamp: Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    init(_ value: stat) {
      device = value.st_dev
      inode = value.st_ino
      size = value.st_size
      changedSeconds = Int64(value.st_ctimespec.tv_sec)
      changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
      modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
      modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
    }
  }

  public init(path: String? = nil) {
    self.syncFD = { fd in
      guard fsync(fd) == 0 else { throw JournalFailure.systemCall("fsync", errno) }
    }
    if let path {
      self.path = path
    } else {
      self.path =
        NSHomeDirectory()
        + "/Library/Application Support/com.tavsn.lighten/actions-v1.jsonl"
    }
  }

  init(path: String, syncFD: @escaping @Sendable (Int32) throws -> Void) {
    self.path = path
    self.syncFD = syncFD
  }

  public func acquireMutationLease() throws -> JournalLease {
    guard heldLease == nil else { throw JournalFailure.leaseBusy }
    try createDurableParentDirectories()
    let (parentFD, name) = try DescriptorFileSystem.openParent(of: path)
    defer { close(parentFD) }
    let fd = openat(
      parentFD, name + ".lock",
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW_ANY, 0o600)
    guard fd >= 0 else { throw JournalFailure.systemCall("open lock", errno) }
    do {
      try validateOwnedRegularFile(fd)
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        throw JournalFailure.leaseBusy
      }
      try syncFD(fd)
      try syncFD(parentFD)
    } catch {
      close(fd)
      throw error
    }
    let lease = JournalLease()
    heldLease = lease
    lockFD = fd
    return lease
  }

  public func releaseMutationLease(_ lease: JournalLease) {
    guard heldLease == lease else { return }
    flock(lockFD, LOCK_UN)
    close(lockFD)
    lockFD = -1
    heldLease = nil
  }

  public func read() throws -> JournalReadout {
    let summary = try readCompact()
    var records: [JournalRecord] = []
    var issues = summary.issues
    for (offset, record) in summary.records.enumerated() {
      if let reference = record.planReference {
        do {
          records.append(record.hydrated(try readPlan(reference)))
        } catch {
          issues.append(JournalIssue(line: offset + 1, reason: "unavailable or changed plan inventory"))
        }
      } else {
        records.append(record)
      }
    }
    return JournalReadout(records: records, issues: issues)
  }

  public func readSummary() async throws -> JournalReadout { try readCompact() }

  private func readCompact() throws -> JournalReadout {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
    if fd < 0 {
      if errno == ENOENT {
        cached = JournalReadout(records: [], issues: [])
        cachedStamp = nil
        plans = [:]
        states = [:]
        progress = [:]
        return cached!
      }
      throw JournalFailure.systemCall("open journal", errno)
    }
    defer { close(fd) }
    try validateOwnedRegularFile(fd, repairPermissions: true)
    let stamp = try fileStamp(fd)
    if let cached, stamp == cachedStamp { return cached }
    let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    let readout = parse(data)
    cached = readout
    cachedStamp = stamp
    return readout
  }

  public func loadPlan(id: UUID) async throws -> ActionPlan {
    let readout = try readCompact()
    guard readout.issues.isEmpty,
      let intent = readout.records.first(where: { $0.kind == .intent && $0.planID == id })
    else { throw JournalFailure.corruptHistory }
    if let plan = intent.plan { return plan }
    guard let reference = intent.planReference else { throw JournalFailure.corruptHistory }
    return try readPlan(reference)
  }

  private func parse(_ data: Data) -> JournalReadout {
    let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
    var records: [JournalRecord] = []
    var issues: [JournalIssue] = []
    plans = [:]
    states = [:]
    progress = [:]
    let decoder = JSONDecoder()
    for (offset, line) in lines.enumerated() {
      if offset == lines.count - 1 && line.isEmpty { break }
      if offset == lines.count - 1 && data.last != 0x0A {
        issues.append(JournalIssue(line: offset + 1, reason: "truncated final line"))
        break
      }
      guard let record = try? decoder.decode(JournalRecord.self, from: Data(line)) else {
        issues.append(JournalIssue(line: offset + 1, reason: "invalid record"))
        continue
      }
      guard record.schema == 1 || record.schema == 2 else {
        issues.append(JournalIssue(line: offset + 1, reason: "unknown schema"))
        continue
      }
      if let reason = Self.semanticIssue(record, plans: &plans, states: &states, progress: &progress) {
        issues.append(JournalIssue(line: offset + 1, reason: reason))
      } else {
        records.append(record)
      }
    }
    return JournalReadout(records: records, issues: issues)
  }

  public func append(_ record: JournalRecord) throws {
    guard heldLease != nil else { throw JournalFailure.leaseRequired }
    _ = try readCompact()
    guard cached?.issues.isEmpty == true else { throw JournalFailure.corruptHistory }
    // Validate against a copy so a failed write cannot advance the durable state.
    var nextPlans = plans
    var nextStates = states
    var nextProgress = progress
    guard Self.semanticIssue(record, plans: &nextPlans, states: &nextStates, progress: &nextProgress) == nil
    else { throw JournalFailure.corruptHistory }
    let stored: JournalRecord
    if record.kind == .intent, let plan = record.plan {
      stored = record.externalized(try writePlan(plan))
    } else {
      stored = record
    }
    let line = try encodeLine(stored)
    let (parentFD, name) = try DescriptorFileSystem.openParent(of: path)
    defer { close(parentFD) }
    let fd = openat(parentFD, name, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW_ANY, 0o600)
    guard fd >= 0 else { throw JournalFailure.systemCall("open journal", errno) }
    defer { close(fd) }
    try validateOwnedRegularFile(fd, repairPermissions: true)
    let before = try fileStamp(fd)
    guard cachedStamp == nil ? before.size == 0 : before == cachedStamp else {
      cached = nil
      throw JournalFailure.corruptHistory
    }
    do {
      try writeAll(line, to: fd)
      try syncFD(fd)
      try syncFD(parentFD)
    } catch {
      cached = nil
      throw error
    }
    plans = nextPlans
    states = nextStates
    progress = nextProgress
    cached?.records.append(stored)
    cachedStamp = try fileStamp(fd)
  }

  /// Keeps the damaged evidence and carries every valid Trash record forward.
  /// Both replacement and archive are durable before the atomic replacement.
  @discardableResult
  public func archiveAndRestart() throws -> String {
    let lease = try acquireMutationLease()
    defer { releaseMutationLease(lease) }
    let readout = try readCompact()
    guard !readout.issues.isEmpty else { throw JournalFailure.corruptHistory }
    let trashIDs = Set(
      readout.records.compactMap { record in
        record.kind == .intent && record.summary?.kind == .trash ? record.planID : nil
      })
    var preserved: [JournalRecord] = []
    for record in readout.records where trashIDs.contains(record.planID) {
      if record.kind == .intent {
        let plan: ActionPlan
        if let embedded = record.plan {
          plan = embedded
        } else if let reference = record.planReference {
          plan = try readPlan(reference)
        } else {
          throw JournalFailure.corruptHistory
        }
        preserved.append(record.externalized(try writePlan(plan)))
      } else {
        preserved.append(record)
      }
    }
    let (parentFD, name) = try DescriptorFileSystem.openParent(of: path)
    defer { close(parentFD) }
    let originalFD = openat(parentFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
    guard originalFD >= 0 else { throw JournalFailure.systemCall("open journal", errno) }
    defer { close(originalFD) }
    try validateOwnedRegularFile(originalFD, repairPermissions: true)
    let originalStamp = try fileStamp(originalFD)
    guard originalStamp == cachedStamp else { throw JournalFailure.corruptHistory }
    let original = try FileHandle(fileDescriptor: originalFD, closeOnDealloc: false).readToEnd() ?? Data()
    let stem = name.hasSuffix(".jsonl") ? String(name.dropLast(6)) : name
    let archiveName = stem + ".corrupt-" + UUID().uuidString + ".jsonl"
    try writeExclusive(original, parentFD: parentFD, name: archiveName)
    let replacement = name + ".recovery-" + UUID().uuidString
    var data = Data()
    for record in preserved { data.append(try encodeLine(record)) }
    try writeExclusive(data, parentFD: parentFD, name: replacement)
    defer { unlinkat(parentFD, replacement, 0) }
    let currentFD = openat(parentFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
    guard currentFD >= 0 else { throw JournalFailure.corruptHistory }
    defer { close(currentFD) }
    try validateOwnedRegularFile(currentFD)
    guard try fileStamp(currentFD) == originalStamp,
      renameat(parentFD, replacement, parentFD, name) == 0
    else { throw JournalFailure.corruptHistory }
    try syncFD(parentFD)
    cached = nil
    _ = try readCompact()
    return (path as NSString).deletingLastPathComponent + "/" + archiveName
  }

  private func openPlansDirectory() throws -> Int32 {
    let (parentFD, _) = try DescriptorFileSystem.openParent(of: path)
    defer { close(parentFD) }
    if mkdirat(parentFD, "plans", 0o700) == 0 {
      try syncFD(parentFD)
    } else if errno != EEXIST {
      throw JournalFailure.systemCall("mkdir plans", errno)
    }
    let fd = openat(parentFD, "plans", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
    guard fd >= 0 else { throw JournalFailure.systemCall("open plans", errno) }
    var details = stat()
    guard fstat(fd, &details) == 0, details.st_uid == geteuid(), details.st_mode & 0o077 == 0 else {
      close(fd)
      throw JournalFailure.corruptHistory
    }
    return fd
  }

  private func writePlan(_ plan: ActionPlan) throws -> JournalPlanReference {
    let data = try JSONEncoder().encode(plan)
    let reference = JournalPlanReference(sha256: Self.digest(data), summary: JournalPlanSummary(plan))
    let parentFD = try openPlansDirectory()
    defer { close(parentFD) }
    let name = plan.id.uuidString + ".json"
    let fd = openat(parentFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
    if fd >= 0 {
      defer { close(fd) }
      try validateOwnedRegularFile(fd)
      let prior = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
      // A prior interrupted intent may have already persisted this same plan.
      guard try JSONDecoder().decode(ActionPlan.self, from: prior) == plan else {
        throw JournalFailure.corruptHistory
      }
      return JournalPlanReference(sha256: Self.digest(prior), summary: reference.summary)
    }
    guard errno == ENOENT else { throw JournalFailure.systemCall("open plan", errno) }
    try writeExclusive(data, parentFD: parentFD, name: name)
    return reference
  }

  private func readPlan(_ reference: JournalPlanReference) throws -> ActionPlan {
    let parentPath = (path as NSString).deletingLastPathComponent
    let planPath = parentPath + "/plans/" + reference.summary.id.uuidString + ".json"
    let fd = open(planPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
    guard fd >= 0 else { throw JournalFailure.systemCall("open plan", errno) }
    defer { close(fd) }
    try validateOwnedRegularFile(fd)
    let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    guard Self.digest(data) == reference.sha256 else { throw JournalFailure.corruptHistory }
    let plan = try JSONDecoder().decode(ActionPlan.self, from: data)
    guard JournalPlanSummary(plan) == reference.summary else { throw JournalFailure.corruptHistory }
    return plan
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func fileStamp(_ fd: Int32) throws -> FileStamp {
    var details = stat()
    guard fstat(fd, &details) == 0 else { throw JournalFailure.systemCall("fstat", errno) }
    return FileStamp(details)
  }

  private func encodeLine(_ record: JournalRecord) throws -> Data {
    var line = try JSONEncoder().encode(record)
    line.append(0x0A)
    return line
  }

  private func writeExclusive(_ data: Data, parentFD: Int32, name: String) throws {
    let fd = openat(parentFD, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY, 0o600)
    guard fd >= 0 else { throw JournalFailure.systemCall("create durable file", errno) }
    defer { close(fd) }
    do {
      try validateOwnedRegularFile(fd)
      try writeAll(data, to: fd)
      try syncFD(fd)
      try syncFD(parentFD)
    } catch {
      unlinkat(parentFD, name, 0)
      throw error
    }
  }

  private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else {
        if raw.isEmpty { return }
        throw JournalFailure.invalidEncoding
      }
      var written = 0
      while written < raw.count {
        let result = Darwin.write(fd, base.advanced(by: written), raw.count - written)
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else { throw JournalFailure.systemCall("write", errno) }
        written += result
      }
    }
  }

  private func createDurableParentDirectories() throws {
    let components = try DescriptorFileSystem.validatedComponents(path)
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw JournalFailure.systemCall("open root", errno) }
    defer { close(fd) }
    for component in components.dropLast() {
      var created = false
      var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
      if next < 0 && errno == ENOENT {
        guard mkdirat(fd, component, 0o700) == 0 else {
          throw JournalFailure.systemCall("mkdirat", errno)
        }
        created = true
        next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
      }
      guard next >= 0 else { throw JournalFailure.systemCall("open directory", errno) }
      if created {
        do {
          try syncFD(next)
          try syncFD(fd)
        } catch {
          close(next)
          throw error
        }
      }
      close(fd)
      fd = next
    }
  }

  private func validateOwnedRegularFile(_ fd: Int32, repairPermissions: Bool = false) throws {
    var details = stat()
    guard fstat(fd, &details) == 0 else { throw JournalFailure.systemCall("fstat", errno) }
    guard details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      details.st_uid == geteuid(), details.st_nlink == 1
    else { throw JournalFailure.corruptHistory }
    if details.st_mode & 0o777 != 0o600 {
      guard repairPermissions, details.st_mode & 0o777 == 0o644,
        fchmod(fd, 0o600) == 0
      else { throw JournalFailure.corruptHistory }
      try syncFD(fd)
    }
  }

  private static func semanticIssue(
    _ record: JournalRecord, plans: inout [UUID: JournalPlanSummary],
    states: inout [ItemKey: JournalEventKind],
    progress: inout [ItemKey: (Int, Int64)]
  ) -> String? {
    if record.kind == .intent {
      guard record.itemID == nil, let plan = record.summary,
        (record.plan != nil) != (record.planReference != nil),
        plan.schema == 1, plan.id == record.planID, !plan.items.isEmpty,
        Set(plan.items.map(\.id)).count == plan.items.count,
        plans[plan.id] == nil
      else { return "invalid or duplicate intent" }
      plans[plan.id] = plan
      return nil
    }
    guard record.plan == nil, record.planReference == nil, let plan = plans[record.planID],
      let itemID = record.itemID, plan.items.contains(where: { $0.id == itemID })
    else { return "event without known plan item" }
    let key = ItemKey(planID: record.planID, itemID: itemID)
    let previous = states[key]
    let latest = progress[key] ?? (0, 0)
    let item = plan.items.first(where: { $0.id == itemID })
    switch record.kind {
    case .applied:
      guard previous == nil || (plan.kind == .catalogDelete && previous == .deleteProgress),
        plan.kind == .catalogDelete
          ? (record.returnedTrashPath == nil && record.movedIdentity == nil
            && record.deletedCount == latest.0
            && record.deletedLogicalBytes == latest.1
            && (item?.userSelection == true ? latest.0 > 0 : latest.0 == item?.inventoryCount))
          : (record.returnedTrashPath != nil && record.movedIdentity != nil)
      else { return "invalid applied event" }
    case .failed, .skipped:
      guard previous == nil || (plan.kind == .catalogDelete && previous == .deleteProgress)
      else { return "duplicate item outcome" }
      if plan.kind == .catalogDelete {
        guard
          previous == .deleteProgress
            ? (record.deletedCount == latest.0 && record.deletedLogicalBytes == latest.1)
            : (record.deletedCount == nil || record.deletedCount == 0)
              && (record.deletedLogicalBytes == nil || record.deletedLogicalBytes == 0)
        else { return "invalid delete outcome count" }
      }
    case .deleteProgress:
      guard plan.kind == .catalogDelete, previous == nil || previous == .deleteProgress,
        let count = record.deletedCount, count == latest.0 + 1,
        item?.userSelection == true || count <= item?.inventoryCount ?? 0,
        let bytes = record.deletedLogicalBytes, bytes >= latest.1
      else { return "invalid delete progress" }
      progress[key] = (count, bytes)
    case .undoIntent:
      guard plan.kind == .trash,
        previous == .applied || previous == .undoIntent || previous == .undoFailed,
        record.returnedTrashPath != nil, record.movedIdentity != nil
      else { return "invalid undo intent" }
    case .reversed, .undoFailed:
      guard plan.kind == .trash, previous == .undoIntent
      else { return "invalid undo outcome" }
    case .intent:
      return "invalid intent"
    }
    states[key] = record.kind
    return nil
  }
}
