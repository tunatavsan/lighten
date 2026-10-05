import Foundation
import LightenKit
import Testing

private func ruleMember(
  _ path: String, seconds: Int64? = 10, nanoseconds: Int64? = 0,
  compatibilityID: UUID?, eligibility: DuplicateEligibility = .eligible
) -> DuplicateMember {
  DuplicateMember(
    entry: ScanEntry(
      parentID: nil, path: path,
      identity: FileIdentity(
        device: 1, inode: 1, changeSeconds: 1, changeNanoseconds: 0,
        logicalBytes: 2_000_000, allocatedBytes: 2_000_000, linkCount: 1, flags: 0, kind: .regular,
        modificationSeconds: seconds, modificationNanoseconds: nanoseconds),
      issues: [], readable: true),
    eligibility: eligibility, compatibilityID: compatibilityID)
}

@Test("Smart keeper prefers a non-transient copy before a newer transient copy")
func duplicateSmartKeeperPrefersDurableLocations() throws {
  let home = "/fixture/home"
  for transient in [
    home + "/Downloads/a", home + "/Desktop/a", home + "/Library/Caches/a", home + "/.Trash/a",
    "/tmp/a", "/private/var/folders/a",
  ] {
    let subset = UUID()
    let durable = ruleMember(home + "/Documents/original", seconds: 1, compatibilityID: subset)
    let group = DuplicateGroup(
      logicalBytes: 2_000_000,
      members: [
        ruleMember(transient, seconds: 99, compatibilityID: subset), durable,
      ])
    let selection = try #require(DuplicateSelectionRule.smart.selections(groups: [group], homeDirectory: home).first)
    #expect(selection.keeperID == durable.id && selection.targetIDs.count == 1)
    #expect(!selection.targetIDs.contains(durable.id))
  }
}

@Test("Newest and oldest keeper rules use precise modification times")
func duplicateKeeperRulesUseModificationTime() throws {
  let subset = UUID()
  let old = ruleMember("/fixture/a", seconds: 1_700_000_000, nanoseconds: 1, compatibilityID: subset)
  let newer = ruleMember("/fixture/b", seconds: 1_700_000_000, nanoseconds: 2, compatibilityID: subset)
  let group = DuplicateGroup(logicalBytes: 2_000_000, members: [newer, old])
  #expect(
    try #require(DuplicateSelectionRule.newest.selections(groups: [group], homeDirectory: "/fixture").first).keeperID
      == newer.id)
  #expect(
    try #require(DuplicateSelectionRule.oldest.selections(groups: [group], homeDirectory: "/fixture").first).keeperID
      == old.id)
}

@Test("Keeper ties are stable by path and missing dates never become fabricated timestamps")
func duplicateKeeperTiesAndMissingDatesAreStable() throws {
  let subset = UUID()
  let unknown = ruleMember("/fixture/a", seconds: nil, nanoseconds: nil, compatibilityID: subset)
  let known = ruleMember("/fixture/b", seconds: 1, compatibilityID: subset)
  let group = DuplicateGroup(logicalBytes: 2_000_000, members: [unknown, known])
  for rule in [DuplicateSelectionRule.smart, .newest, .oldest] {
    #expect(try #require(rule.selections(groups: [group], homeDirectory: "/fixture").first).keeperID == known.id)
  }
  let first = ruleMember("/fixture/a", compatibilityID: subset)
  let second = ruleMember("/fixture/b", compatibilityID: subset)
  let tied = DuplicateGroup(logicalBytes: 2_000_000, members: [second, first])
  #expect(
    try #require(DuplicateSelectionRule.smart.selections(groups: [tied], homeDirectory: "/fixture").first).keeperID
      == first.id)
}

@Test("Folder keeper preference respects path boundaries and falls back to the newest copy")
func duplicateFolderKeeperUsesDirectoryBoundary() throws {
  let subset = UUID()
  let inside = ruleMember("/fixture/keep/a", seconds: 1, compatibilityID: subset)
  let outside = ruleMember("/fixture/keeper/b", seconds: 99, compatibilityID: subset)
  let group = DuplicateGroup(logicalBytes: 2_000_000, members: [outside, inside])
  #expect(
    try #require(
      DuplicateSelectionRule.folder("/fixture/keep").selections(groups: [group], homeDirectory: "/fixture").first
    ).keeperID == inside.id)
  #expect(
    try #require(
      DuplicateSelectionRule.folder("/fixture/absent").selections(groups: [group], homeDirectory: "/fixture").first
    ).keeperID == outside.id)
}

@Test("One bulk selection keeps every compatibility subset and ignores unverified members")
func duplicateBulkSelectionPreservesCompatibilitySubsets() {
  let firstSubset = UUID()
  let secondSubset = UUID()
  let first = [
    ruleMember("/fixture/a", compatibilityID: firstSubset), ruleMember("/fixture/b", compatibilityID: firstSubset),
  ]
  let second = [
    ruleMember("/fixture/c", compatibilityID: secondSubset), ruleMember("/fixture/d", compatibilityID: secondSubset),
  ]
  let reportOnly = ruleMember("/fixture/e", compatibilityID: nil, eligibility: .metadataDifferent)
  let unknown = ruleMember("/fixture/f", compatibilityID: firstSubset, eligibility: .metadataUnknown)
  let group = DuplicateGroup(logicalBytes: 2_000_000, members: first + second + [reportOnly, unknown])
  let selections = DuplicateSelectionRule.smart.selections(groups: [group], homeDirectory: "/fixture")
  #expect(selections.count == 2 && selections.allSatisfy { $0.groupID == group.id })
  let keepers = Set(selections.map(\.keeperID))
  let targets = selections.reduce(into: Set<UUID>()) { $0.formUnion($1.targetIDs) }
  #expect(keepers.count == 2 && targets.count == 2 && keepers.isDisjoint(with: targets))
  #expect(!targets.contains(reportOnly.id) && !targets.contains(unknown.id))
  #expect(
    selections.allSatisfy { selection in
      selection.targetIDs.allSatisfy { group.canTarget($0, keeperID: selection.keeperID) }
    })
}

@Test("One rule invocation selects one hundred groups without choosing every member of any group")
func duplicateRuleSelectsOneHundredGroups() {
  let groups = (0..<100).map { index in
    let subset = UUID()
    return DuplicateGroup(
      logicalBytes: 2_000_000,
      members: (0..<3).map { member in
        ruleMember("/fixture/group-\(index)/\(member)", seconds: Int64(member), compatibilityID: subset)
      })
  }
  let selections = DuplicateSelectionRule.smart.selections(groups: groups, homeDirectory: "/fixture")
  #expect(selections.count == 100)
  #expect(selections.allSatisfy { $0.targetIDs.count == 2 && !$0.targetIDs.contains($0.keeperID) })
  #expect(Set(selections.map(\.groupID)) == Set(groups.map(\.id)))
}
