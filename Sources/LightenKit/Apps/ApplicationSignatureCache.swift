import Darwin
import Foundation
import Synchronization

/// A successful read remains reusable only while the code and signed metadata
/// retain their full filesystem identities. Failed reads are cached as well.
final class ApplicationSignatureCache: Sendable {
  static let native = ApplicationSignatureCache(reader: ApplicationSigningMetadata.read)

  struct Observation: Sendable {
    let identity: ApplicationSignatureIdentity
    let metadata: ApplicationSigningMetadata?
  }

  private let entries = Mutex<[String: Observation]>([:])
  private let reads = Mutex(())
  private let reader: @Sendable (String) -> ApplicationSigningMetadata?

  init(reader: @escaping @Sendable (String) -> ApplicationSigningMetadata?) {
    self.reader = reader
  }

  func observation(at path: String) -> Observation? {
    guard let identity = try? ApplicationSignatureIdentity.capture(path) else { return nil }
    if let cached = entries.withLock({ $0[path] }), cached.identity == identity { return cached }
    return reads.withLock { _ in
      if let cached = entries.withLock({ $0[path] }), cached.identity == identity { return cached }
      let metadata = reader(path)
      guard (try? ApplicationSignatureIdentity.capture(path)) == identity else {
        entries.withLock { _ = $0.removeValue(forKey: path) }
        return nil
      }
      let observation = Observation(identity: identity, metadata: metadata)
      entries.withLock { $0[path] = observation }
      return observation
    }
  }

  func metadata(at path: String) -> ApplicationSigningMetadata? { observation(at: path)?.metadata }

  /// Fast display enrichment reuses only a previously validated, unchanged signer.
  /// A cold signature still goes through the strict native reader in observation(at:).
  func cachedMetadata(at path: String) -> ApplicationSigningMetadata? {
    guard let identity = try? ApplicationSignatureIdentity.capture(path) else { return nil }
    return entries.withLock { $0[path].flatMap { $0.identity == identity ? $0.metadata : nil } }
  }
}

struct ApplicationSignatureIdentity: Sendable, Equatable {
  struct Entry: Sendable, Equatable {
    let path: String
    let identity: FileIdentity?
  }

  let rootPath: String
  let entries: [Entry]

  static func capture(_ path: String) throws -> Self {
    let root = try DescriptorFileSystem.identity(at: path)
    guard root.hasStableTrashProof, root.kind == .regular || root.kind == .directory else {
      throw RelatedFailure.unsupportedInstalledData
    }
    var entries = [Entry(path: path, identity: root)]
    if root.kind == .regular { return Self(rootPath: path, entries: entries) }
    var seen: Set<String> = [path]

    func add(_ candidate: String) throws -> String? {
      let physical: String
      if let resolved = realpath(candidate, nil) {
        physical = String(cString: resolved)
        free(resolved)
        guard physical.hasPrefix(path + "/") else { throw RelatedFailure.unsupportedInstalledData }
      } else {
        guard errno == ENOENT || errno == ENOTDIR else { throw RelatedFailure.unsupportedInstalledData }
        if seen.insert(candidate).inserted { entries.append(Entry(path: candidate, identity: nil)) }
        return nil
      }
      let identity = try DescriptorFileSystem.identity(at: physical)
      guard identity.hasStableTrashProof, identity.device == root.device,
        identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0
      else { throw RelatedFailure.unsupportedInstalledData }
      if seen.insert(physical).inserted { entries.append(Entry(path: physical, identity: identity)) }
      return physical
    }

    let infoCandidates = [path + "/Contents/Info.plist", path + "/Info.plist", path + "/Resources/Info.plist"]
    var infoPath: String?
    for candidate in infoCandidates {
      if let physical = try add(candidate), infoPath == nil { infoPath = physical }
    }
    var executable: String?
    if let infoPath {
      guard let data = try? SecureMetadataFile.read(path: infoPath, limit: 1024 * 1024, ownerOnly: false),
        let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let info = value as? [String: Any]
      else { throw RelatedFailure.unsupportedInstalledData }
      if let name = info["CFBundleExecutable"] as? String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
          throw RelatedFailure.unsupportedInstalledData
        }
        let parent = (infoPath as NSString).deletingLastPathComponent
        let candidate =
          infoPath.hasSuffix("/Contents/Info.plist")
          ? parent + "/MacOS/" + name
          : parent.hasSuffix("/Resources")
            ? (parent as NSString).deletingLastPathComponent + "/" + name
            : parent + "/" + name
        guard let physical = try add(candidate),
          (try? DescriptorFileSystem.identity(at: physical))?.kind == .regular
        else { throw RelatedFailure.unsupportedInstalledData }
        executable = physical
      }
    }
    var signaturePaths = [path + "/Contents/_CodeSignature", path + "/_CodeSignature"]
    if let executable {
      signaturePaths.append((executable as NSString).deletingLastPathComponent + "/_CodeSignature")
    }
    func collectSignature(_ directory: String, depth: Int) throws {
      guard depth <= 16, entries.count < 4096,
        let identity = try? DescriptorFileSystem.identity(at: directory), identity.kind == .directory
      else { throw RelatedFailure.unsupportedInstalledData }
      for name in try DescriptorFileSystem.children(at: directory, expected: identity) {
        let child = directory + "/" + name
        let details = try DescriptorFileSystem.identity(at: child)
        guard details.kind == .regular || details.kind == .directory else {
          throw RelatedFailure.unsupportedInstalledData
        }
        _ = try add(child)
        if details.kind == .directory { try collectSignature(child, depth: depth + 1) }
      }
    }
    for candidate in Set(signaturePaths).sorted() {
      if let directory = try add(candidate) { try collectSignature(directory, depth: 0) }
    }
    return Self(rootPath: path, entries: entries.sorted { $0.path < $1.path })
  }

  /// This check reads only the previously captured selected-owner paths. It
  /// never reads an entitlement or expands an installed-owner inventory.
  func validate(mappedFrom source: String? = nil, to destination: String? = nil, movedRoot: FileIdentity? = nil) throws
  {
    for entry in entries {
      let path: String
      if let source, let destination {
        guard entry.path == source || entry.path.hasPrefix(source + "/") else {
          throw RelatedFailure.changedItem
        }
        path = destination + entry.path.dropFirst(source.count)
      } else {
        path = entry.path
      }
      let current: FileIdentity?
      do { current = try DescriptorFileSystem.identity(at: path) } catch FileSystemFailure.systemCall(_, let code)
        where code == ENOENT || code == ENOTDIR
      {
        current = nil
      } catch { throw RelatedFailure.changedItem }
      let expected = entry.path == source && movedRoot != nil ? movedRoot : entry.identity
      guard current == expected else { throw RelatedFailure.changedItem }
    }
  }
}
