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
    self.returnedTrashPath = returnedTrashPath
    self.movedIdentity = movedIdentity
    self.detail = detail
    self.deletedCount = deletedCount
    self.deletedLogicalBytes = deletedLogicalBytes
  }
}

public struct JournalIssue: Sendable, Equatable {
  public let line: Int
  public let reason: String
}

public struct JournalReadout: Sendable {
  public let records: [JournalRecord]
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
}

extension ActionJournal {
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
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
    if fd < 0 {
      if errno == ENOENT { return JournalReadout(records: [], issues: []) }
      throw JournalFailure.systemCall("open journal", errno)
    }
    defer { close(fd) }
    try validateOwnedRegularFile(fd)
    let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
    var records: [JournalRecord] = []
    var issues: [JournalIssue] = []
    var plans: [UUID: ActionPlan] = [:]
    var states: [ItemKey: JournalEventKind] = [:]
    var progress: [ItemKey: (Int, Int64)] = [:]
    for (offset, line) in lines.enumerated() {
      if offset == lines.count - 1 && line.isEmpty { break }
      if offset == lines.count - 1 && data.last != 0x0A {
        issues.append(JournalIssue(line: offset + 1, reason: "truncated final line"))
        break
      }
      guard let record = try? JSONDecoder().decode(JournalRecord.self, from: Data(line)) else {
        issues.append(JournalIssue(line: offset + 1, reason: "invalid record"))
        continue
      }
      guard record.schema == 1 else {
        issues.append(JournalIssue(line: offset + 1, reason: "unknown schema"))
        continue
      }
      if let reason = Self.semanticIssue(
        record, plans: &plans,
        states: &states, progress: &progress)
      {
        issues.append(JournalIssue(line: offset + 1, reason: reason))
      } else {
        records.append(record)
      }
    }
    return JournalReadout(records: records, issues: issues)
  }

  public func append(_ record: JournalRecord) throws {
    guard heldLease != nil else { throw JournalFailure.leaseRequired }
    let existing = try read()
    guard existing.issues.isEmpty else { throw JournalFailure.corruptHistory }
    var plans: [UUID: ActionPlan] = [:]
    var states: [ItemKey: JournalEventKind] = [:]
    var progress: [ItemKey: (Int, Int64)] = [:]
    for prior in existing.records {
      _ = Self.semanticIssue(
        prior, plans: &plans,
        states: &states, progress: &progress)
    }
    guard
      Self.semanticIssue(
        record, plans: &plans,
        states: &states, progress: &progress) == nil
    else {
      throw JournalFailure.corruptHistory
    }
    let encoded = try JSONEncoder().encode(record)
    var line = encoded
    line.append(0x0A)
    let (parentFD, name) = try DescriptorFileSystem.openParent(of: path)
    defer { close(parentFD) }
    let fd = openat(
      parentFD, name,
      O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW_ANY, 0o600)
    guard fd >= 0 else { throw JournalFailure.systemCall("open journal", errno) }
    defer { close(fd) }
    try validateOwnedRegularFile(fd)
    try line.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { throw JournalFailure.invalidEncoding }
      var written = 0
      while written < raw.count {
        let result = Darwin.write(fd, base.advanced(by: written), raw.count - written)
        if result <= 0 { throw JournalFailure.systemCall("write", errno) }
        written += result
      }
    }
    try syncFD(fd)
    try syncFD(parentFD)
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

  private func validateOwnedRegularFile(_ fd: Int32) throws {
    var details = stat()
    guard fstat(fd, &details) == 0 else { throw JournalFailure.systemCall("fstat", errno) }
    guard details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      details.st_uid == geteuid(), details.st_nlink == 1,
      details.st_mode & 0o077 == 0
    else { throw JournalFailure.corruptHistory }
  }

  private static func semanticIssue(
    _ record: JournalRecord, plans: inout [UUID: ActionPlan],
    states: inout [ItemKey: JournalEventKind],
    progress: inout [ItemKey: (Int, Int64)]
  ) -> String? {
    if record.kind == .intent {
      guard record.itemID == nil, let plan = record.plan,
        plan.schema == 1, plan.id == record.planID, !plan.items.isEmpty,
        Set(plan.items.map(\.id)).count == plan.items.count,
        plans[plan.id] == nil
      else { return "invalid or duplicate intent" }
      plans[plan.id] = plan
      return nil
    }
    guard record.plan == nil, let plan = plans[record.planID],
      let itemID = record.itemID, plan.items.contains(where: { $0.id == itemID })
    else { return "event without known plan item" }
    let key = ItemKey(planID: record.planID, itemID: itemID)
    let previous = states[key]
    let latest = progress[key] ?? (0, 0)
    switch record.kind {
    case .applied:
      guard previous == nil || (plan.kind == .catalogDelete && previous == .deleteProgress),
        plan.kind == .catalogDelete
          ? (record.returnedTrashPath == nil && record.movedIdentity == nil
            && record.deletedCount == latest.0
            && record.deletedLogicalBytes == latest.1
            && latest.0 == plan.items.first(where: { $0.id == itemID })?.inventory.count)
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
        count <= plan.items.first(where: { $0.id == itemID })?.inventory.count ?? 0,
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
