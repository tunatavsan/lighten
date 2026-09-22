import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

private func provenIdentity(
  device: UInt64 = 1, inode: UInt64 = 2, kind: EntryKind = .regular,
  birthSeconds: Int64? = 10, birthNanoseconds: Int64? = 11,
  modificationSeconds: Int64? = 20, modificationNanoseconds: Int64? = 21,
  logicalBytes: Int64 = 200, linkCount: UInt64 = 1, flags: UInt32 = 0,
  changeNanoseconds: Int64 = 30, allocatedBytes: Int64 = 512
) -> FileIdentity {
  FileIdentity(
    device: device, inode: inode, changeSeconds: 3,
    changeNanoseconds: changeNanoseconds, logicalBytes: logicalBytes,
    allocatedBytes: allocatedBytes, linkCount: linkCount, flags: flags,
    kind: kind, birthSeconds: birthSeconds, birthNanoseconds: birthNanoseconds,
    modificationSeconds: modificationSeconds,
    modificationNanoseconds: modificationNanoseconds
  )
}

private func withoutProof(_ identity: FileIdentity) -> FileIdentity {
  FileIdentity(
    device: identity.device, inode: identity.inode,
    changeSeconds: identity.changeSeconds,
    changeNanoseconds: identity.changeNanoseconds,
    logicalBytes: identity.logicalBytes,
    allocatedBytes: identity.allocatedBytes,
    linkCount: identity.linkCount, flags: identity.flags,
    kind: identity.kind
  )
}

private final class CapturedNativeTrash: TrashMoving {
  private let resultPath = Mutex<String?>(nil)

  func moveToTrash(path: String) async throws -> String {
    let returned = try await Task.detached {
      var resultingURL: NSURL?
      try FileManager.default.trashItem(
        at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL)
      guard let resultingURL else { throw FileSystemFailure.invalidPath }
      return (resultingURL as URL).path
    }.value
    resultPath.withLock { $0 = returned }
    return returned
  }

  func returnedPath() -> String? { resultPath.withLock { $0 } }
}

private func undoFixtureRoot() throws -> String {
  guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
    throw FileSystemFailure.invalidPath
  }
  defer { free(resolved) }
  let root = String(cString: resolved) + "/lighten-undo-test-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  return root
}

@Test func ctimeOnlyChangeRetainsProofButChangedContentOrObjectDoesNot() {
  let original = provenIdentity()
  #expect(
    original.matchesStableTrashIdentity(
      provenIdentity(changeNanoseconds: 31, allocatedBytes: 1024)))
  let changed = [
    provenIdentity(device: 9),
    provenIdentity(inode: 9),
    provenIdentity(kind: .directory),
    provenIdentity(birthSeconds: 11),
    provenIdentity(birthNanoseconds: 12),
    provenIdentity(modificationSeconds: 21),
    provenIdentity(modificationNanoseconds: 22),
    provenIdentity(logicalBytes: 201),
    provenIdentity(linkCount: 2),
    provenIdentity(flags: UInt32(UF_IMMUTABLE)),
    provenIdentity(birthSeconds: nil),
    provenIdentity(modificationSeconds: nil),
  ]
  #expect(changed.allSatisfy { !original.matchesStableTrashIdentity($0) })
}

@Test func missingLegacyProofDecodesAndFailsClosed() throws {
  let original = provenIdentity()
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
      as? [String: Any])
  for key in ["birthSeconds", "birthNanoseconds", "modificationSeconds", "modificationNanoseconds"] {
    object.removeValue(forKey: key)
  }
  let oldData = try JSONSerialization.data(withJSONObject: object)
  let decoded = try JSONDecoder().decode(FileIdentity.self, from: oldData)
  #expect(decoded.birthSeconds == nil)
  #expect(!decoded.matchesStableTrashIdentity(original))
  #expect(decoded.device == original.device)
  #expect(decoded.inode == original.inode)
}

@Test func missingProofCannotEnterPlanOrFinalGuard() async throws {
  let root = try undoFixtureRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = root + "/item"
  try Data("fixture".utf8).write(to: URL(fileURLWithPath: source))
  let scan = try await ScanService().scan(rootPath: root)
  let selected = try #require(scan.entries.first { $0.path == source })
  let oldEntry = ScanEntry(
    id: selected.id, parentID: selected.parentID,
    path: selected.path, identity: withoutProof(try #require(selected.identity)),
    observedAt: selected.observedAt, issues: [], readable: true)
  let altered = ScanSnapshot(
    schema: scan.schema, runID: scan.runID,
    rootPath: scan.rootPath, volumeDevice: scan.volumeDevice,
    volumeID: scan.volumeID, observedAt: scan.observedAt,
    entries: scan.entries.map { $0.id == selected.id ? oldEntry : $0 },
    nodes: scan.nodes)
  #expect(throws: PlanFailure.self) {
    try PlanService().makePlan(snapshot: altered, selectedIDs: [selected.id])
  }
  let forged = PlanItem(
    id: selected.id, sourcePath: source,
    volumeID: scan.volumeID, inventory: [oldEntry],
    ancestors: try DescriptorFileSystem.ancestorIdentities(of: source))
  #expect(throws: GuardFailure.self) { try ActionGuard().validate(forged) }
}

@Test func nativeTrashAfterCtimeChangeReconcilesAndUndoRestores() async throws {
  let root = try undoFixtureRoot()
  let source = root + "/inside.bin"
  let mover = CapturedNativeTrash()
  defer {
    // Only the known UUID fixture returned by this test is restored.
    if let path = mover.returnedPath(),
      FileManager.default.fileExists(atPath: path),
      !FileManager.default.fileExists(atPath: source)
    {
      try? FileManager.default.moveItem(atPath: path, toPath: source)
    }
    try? FileManager.default.removeItem(atPath: root)
  }
  try Data(repeating: 0x42, count: 200_000).write(to: URL(fileURLWithPath: source))
  let scan = try await ScanService().scan(rootPath: root)
  let entry = try #require(scan.entries.first { $0.path == source })
  let plan = try PlanService().makePlan(snapshot: scan, selectedIDs: [entry.id])
  let journalPath = root + "/actions.jsonl"
  let journal = JSONLActionJournal(path: journalPath)
  let result = try await ActionExecutor(journal: journal, trash: mover).execute(plan)
  #expect(result.items.map(\.outcome) == [.applied])
  let returned = try #require(mover.returnedPath())
  let applied = try #require((try await journal.read()).records.first { $0.kind == .applied })
  let moved = try #require(applied.movedIdentity)
  #expect(moved.birthSeconds != nil)
  #expect(moved.modificationSeconds != nil)

  let attribute = "com.tavsn.lighten.fixture." + UUID().uuidString
  var marker: UInt8 = 1
  let setResult = setxattr(returned, attribute, &marker, 1, 0, XATTR_NOFOLLOW)
  #expect(setResult == 0)
  let changed = try KnownPathFileSystem.identity(at: returned)
  #expect(
    changed.changeSeconds != moved.changeSeconds
      || changed.changeNanoseconds != moved.changeNanoseconds)
  #expect(moved.matchesStableTrashIdentity(changed))

  try await Task.sleep(for: .milliseconds(100))
  let relaunched = ActionHistory(journal: JSONLActionJournal(path: journalPath))
  #expect((try await relaunched.reconcile()).items.map(\.state) == [.inTrash])

  let old = withoutProof(try #require(plan.items[0].inventory.first?.identity))
  let prior = plan.items[0]
  let oldEntry = ScanEntry(
    id: prior.inventory[0].id,
    parentID: prior.inventory[0].parentID, path: source, identity: old,
    observedAt: prior.inventory[0].observedAt, issues: [], readable: true)
  let oldItem = PlanItem(
    id: prior.id, sourcePath: source, volumeID: prior.volumeID,
    inventory: [oldEntry], ancestors: prior.ancestors)
  let oldPlan = ActionPlan(snapshotRunID: plan.snapshotRunID, kind: .trash, items: [oldItem])
  let oldJournal = JSONLActionJournal(path: root + "/legacy.jsonl")
  try await oldJournal.withMutationLease {
    try await oldJournal.append(JournalRecord(kind: .intent, planID: oldPlan.id, plan: oldPlan))
    try await oldJournal.append(
      JournalRecord(
        kind: .applied, planID: oldPlan.id,
        itemID: oldItem.id, returnedTrashPath: returned, movedIdentity: withoutProof(moved)))
  }
  let oldHistory = ActionHistory(journal: oldJournal)
  #expect((try await oldHistory.reconcile()).items.map(\.state) == [.uncertain])
  await #expect(throws: UndoFailure.self) {
    try await oldHistory.undo(planID: oldPlan.id, itemID: oldItem.id)
  }
  #expect(FileManager.default.fileExists(atPath: returned))

  let wrongVolumeItem = PlanItem(
    id: prior.id, sourcePath: source,
    volumeID: UUID(), inventory: prior.inventory, ancestors: prior.ancestors)
  let wrongPlan = ActionPlan(
    snapshotRunID: plan.snapshotRunID, kind: .trash,
    items: [wrongVolumeItem])
  let wrongJournal = JSONLActionJournal(path: root + "/wrong-volume.jsonl")
  try await wrongJournal.withMutationLease {
    try await wrongJournal.append(
      JournalRecord(
        kind: .intent,
        planID: wrongPlan.id, plan: wrongPlan))
    try await wrongJournal.append(
      JournalRecord(
        kind: .applied,
        planID: wrongPlan.id, itemID: wrongVolumeItem.id,
        returnedTrashPath: returned, movedIdentity: moved))
  }
  #expect((try await ActionHistory(journal: wrongJournal).reconcile()).items[0].state == .uncertain)
  await #expect(throws: UndoFailure.self) {
    try await ActionHistory(journal: wrongJournal).undo(
      planID: wrongPlan.id,
      itemID: wrongVolumeItem.id)
  }

  try await relaunched.undo(planID: plan.id, itemID: prior.id)
  #expect(FileManager.default.fileExists(atPath: source))
  #expect(!FileManager.default.fileExists(atPath: returned))
}

@Test func nativeDirectoryTrashAfterCtimeChangeReconcilesAndUndoRestores() async throws {
  let root = try undoFixtureRoot()
  let source = root + "/folder"
  let child = source + "/inside.bin"
  let mover = CapturedNativeTrash()
  defer {
    if let path = mover.returnedPath(),
      FileManager.default.fileExists(atPath: path),
      !FileManager.default.fileExists(atPath: source)
    {
      try? FileManager.default.moveItem(atPath: path, toPath: source)
    }
    try? FileManager.default.removeItem(atPath: root)
  }
  try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: false)
  try Data("directory-child".utf8).write(to: URL(fileURLWithPath: child))
  let scan = try await ScanService().scan(rootPath: root)
  let entry = try #require(scan.entries.first { $0.path == source })
  let plan = try PlanService().makePlan(snapshot: scan, selectedIDs: [entry.id])
  let journalPath = root + "/directory-actions.jsonl"
  let journal = JSONLActionJournal(path: journalPath)
  let result = try await ActionExecutor(journal: journal, trash: mover).execute(plan)
  #expect(result.items.map(\.outcome) == [.applied])
  let returned = try #require(mover.returnedPath())
  let applied = try #require((try await journal.read()).records.first { $0.kind == .applied })
  let moved = try #require(applied.movedIdentity)
  let attribute = "com.tavsn.lighten.fixture." + UUID().uuidString
  var marker: UInt8 = 1
  #expect(setxattr(returned, attribute, &marker, 1, 0, XATTR_NOFOLLOW) == 0)
  let changed = try KnownPathFileSystem.identity(at: returned)
  #expect(moved.matchesStableTrashIdentity(changed))
  #expect(
    changed.changeSeconds != moved.changeSeconds
      || changed.changeNanoseconds != moved.changeNanoseconds)

  try await Task.sleep(for: .milliseconds(100))
  let relaunched = ActionHistory(journal: JSONLActionJournal(path: journalPath))
  #expect((try await relaunched.reconcile()).items.map(\.state) == [.inTrash])
  try await relaunched.undo(planID: plan.id, itemID: entry.id)
  #expect(try Data(contentsOf: URL(fileURLWithPath: child)) == Data("directory-child".utf8))
  #expect(!FileManager.default.fileExists(atPath: returned))
}
