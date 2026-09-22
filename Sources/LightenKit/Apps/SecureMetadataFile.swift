import Darwin
import Foundation

enum SecureMetadataFailure: Error {
  case unsafe, tooLarge, changed
}

enum SecureMetadataFile {
  static func read(path: String, limit: Int, ownerOnly: Bool) throws -> Data? {
    let parentFD: Int32
    let name: String
    do {
      (parentFD, name) =
        try ownerOnly
        ? openParentChecked(path: path, create: false)
        : DescriptorFileSystem.openParent(of: path)
    } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
      return nil
    }
    defer { close(parentFD) }
    let fd = openat(parentFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
    if fd < 0 && errno == ENOENT { return nil }
    guard fd >= 0 else { throw FileSystemFailure.systemCall("open metadata", errno) }
    defer { close(fd) }
    let before = try validated(fd: fd, limit: limit, ownerOnly: ownerOnly)
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let amount = buffer.withUnsafeMutableBytes { pointer in
        Darwin.read(fd, pointer.baseAddress, pointer.count)
      }
      if amount < 0 { throw FileSystemFailure.systemCall("read metadata", errno) }
      if amount == 0 { break }
      guard result.count <= limit - amount else { throw SecureMetadataFailure.tooLarge }
      result.append(contentsOf: buffer.prefix(amount))
    }
    let after = try validated(fd: fd, limit: limit, ownerOnly: ownerOnly)
    guard before == after, result.count == Int(before.logicalBytes) else {
      throw SecureMetadataFailure.changed
    }
    return result
  }

  static func write(path: String, data: Data, limit: Int) throws {
    guard data.count <= limit else { throw SecureMetadataFailure.tooLarge }
    let (parentFD, name) = try openParentChecked(path: path, create: true)
    defer { close(parentFD) }
    // Existing receipt must itself be safe before atomic replacement.
    _ = try read(path: path, limit: limit, ownerOnly: true)
    let temporary = ".receipt-" + UUID().uuidString
    let fd = openat(
      parentFD, temporary,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY, 0o600)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("create receipt", errno) }
    defer {
      close(fd)
      _ = unlinkat(parentFD, temporary, 0)
    }
    try data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var written = 0
      while written < raw.count {
        let amount = Darwin.write(fd, base.advanced(by: written), raw.count - written)
        guard amount > 0 else { throw FileSystemFailure.systemCall("write receipt", errno) }
        written += amount
      }
    }
    guard fsync(fd) == 0 else { throw FileSystemFailure.systemCall("fsync receipt", errno) }
    guard renameat(parentFD, temporary, parentFD, name) == 0 else {
      throw FileSystemFailure.systemCall("replace receipt", errno)
    }
    guard fsync(parentFD) == 0 else {
      let failure = errno
      _ = unlinkat(parentFD, name, 0)
      _ = fsync(parentFD)
      throw FileSystemFailure.systemCall("fsync receipt directory", failure)
    }
    _ = try read(path: path, limit: limit, ownerOnly: true)
  }

  private static func validated(fd: Int32, limit: Int, ownerOnly: Bool) throws -> FileIdentity {
    var details = stat()
    guard fstat(fd, &details) == 0 else { throw FileSystemFailure.systemCall("fstat metadata", errno) }
    guard details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      details.st_nlink == 1, details.st_size >= 0, details.st_size <= limit,
      details.st_flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
      !ownerOnly || (details.st_uid == geteuid() && details.st_mode & 0o077 == 0)
    else { throw SecureMetadataFailure.unsafe }
    return DescriptorFileSystem.identity(from: details)
  }

  private static func openParentChecked(path: String, create: Bool) throws -> (Int32, String) {
    let components = try DescriptorFileSystem.validatedComponents(path)
    guard let name = components.last else { throw FileSystemFailure.invalidPath }
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("open root", errno) }
    for part in components.dropLast() {
      var created = false
      var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
      if create && next < 0 && errno == ENOENT {
        guard mkdirat(fd, part, 0o700) == 0 else {
          close(fd)
          throw FileSystemFailure.systemCall("mkdir receipt directory", errno)
        }
        created = true
        next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
      }
      guard next >= 0 else {
        let failure = errno
        close(fd)
        throw FileSystemFailure.systemCall("open receipt directory", failure)
      }
      var details = stat()
      guard fstat(next, &details) == 0,
        details.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        details.st_flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
        details.st_uid == 0 || details.st_uid == geteuid(),
        details.st_mode & 0o022 == 0
          || (details.st_uid == 0 && details.st_mode & mode_t(S_ISVTX) != 0)
      else {
        close(next)
        close(fd)
        throw SecureMetadataFailure.unsafe
      }
      if created {
        guard fsync(next) == 0, fsync(fd) == 0 else {
          close(next)
          close(fd)
          throw FileSystemFailure.systemCall("fsync receipt directory", errno)
        }
      }
      close(fd)
      fd = next
    }
    return (fd, name)
  }
}
