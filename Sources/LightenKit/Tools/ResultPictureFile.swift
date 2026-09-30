import Darwin
import Foundation

/// Scoped descriptors keep reads and atomic replacements inside the checked directory.
enum ResultPictureFile {
  static func read(directory: String, name: String, limit: Int) throws -> Data? {
    let directoryFD: Int32
    do {
      directoryFD = try openDirectory(directory, create: false)
    } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
      return nil
    }
    defer { close(directoryFD) }
    return try read(directoryFD: directoryFD, name: name, limit: limit)
  }

  static func write(directory: String, name: String, data: Data, limit: Int) throws {
    guard data.count <= limit else { throw ResultPictureFailure.tooLarge }
    let directoryFD = try openDirectory(directory, create: true)
    defer { close(directoryFD) }
    _ = try read(directoryFD: directoryFD, name: name, limit: limit)
    let temporary = ".picture-" + UUID().uuidString
    let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY, 0o600)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("create picture", errno) }
    defer {
      close(fd)
      _ = unlinkat(directoryFD, temporary, 0)
    }
    guard fchmod(fd, 0o600) == 0 else { throw FileSystemFailure.systemCall("chmod picture", errno) }
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var written = 0
      while written < bytes.count {
        let amount = Darwin.write(fd, base.advanced(by: written), bytes.count - written)
        if amount < 0 && errno == EINTR { continue }
        guard amount > 0 else { throw FileSystemFailure.systemCall("write picture", errno) }
        written += amount
      }
    }
    guard fsync(fd) == 0 else { throw FileSystemFailure.systemCall("fsync picture", errno) }
    guard renameat(directoryFD, temporary, directoryFD, name) == 0 else {
      throw FileSystemFailure.systemCall("replace picture", errno)
    }
    guard fsync(directoryFD) == 0 else { throw FileSystemFailure.systemCall("fsync picture directory", errno) }
  }

  private static func read(directoryFD: Int32, name: String, limit: Int) throws -> Data? {
    let fd = openat(directoryFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
    if fd < 0 && errno == ENOENT { return nil }
    guard fd >= 0 else { throw FileSystemFailure.systemCall("open picture", errno) }
    defer { close(fd) }
    let before = try validateFile(fd, limit: limit)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let amount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if amount < 0 && errno == EINTR { continue }
      guard amount >= 0 else { throw FileSystemFailure.systemCall("read picture", errno) }
      if amount == 0 { break }
      guard data.count <= limit - amount else { throw ResultPictureFailure.tooLarge }
      data.append(contentsOf: buffer.prefix(amount))
    }
    guard try validateFile(fd, limit: limit) == before, data.count == Int(before.logicalBytes) else {
      throw ResultPictureFailure.changed
    }
    return data
  }

  private static func validateFile(_ fd: Int32, limit: Int) throws -> FileIdentity {
    var details = stat()
    guard fstat(fd, &details) == 0 else { throw FileSystemFailure.systemCall("stat picture", errno) }
    guard details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), details.st_nlink == 1,
      details.st_uid == geteuid(), details.st_mode & 0o777 == 0o600,
      details.st_size >= 0, details.st_size <= limit,
      details.st_flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0
    else { throw ResultPictureFailure.unsafe }
    return DescriptorFileSystem.identity(from: details)
  }

  private static func openDirectory(_ path: String, create: Bool) throws -> Int32 {
    let components = try DescriptorFileSystem.validatedComponents(path)
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("open root", errno) }
    do {
      for (index, component) in components.enumerated() {
        var created = false
        var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        if create && next < 0 && errno == ENOENT {
          let result = mkdirat(fd, component, 0o700)
          guard result == 0 || errno == EEXIST else {
            throw FileSystemFailure.systemCall("create picture directory", errno)
          }
          created = result == 0
          next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard next >= 0 else { throw FileSystemFailure.systemCall("open picture directory", errno) }
        do {
          var details = stat()
          guard fstat(next, &details) == 0 else { throw FileSystemFailure.systemCall("stat picture directory", errno) }
          guard details.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            details.st_flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
            details.st_uid == 0 || details.st_uid == geteuid(),
            details.st_mode & 0o022 == 0
              || (details.st_uid == 0 && details.st_mode & mode_t(S_ISVTX) != 0),
            index != components.count - 1 || (details.st_uid == geteuid() && details.st_mode & 0o777 == 0o700)
          else { throw ResultPictureFailure.unsafe }
          if created {
            guard fsync(next) == 0, fsync(fd) == 0 else {
              throw FileSystemFailure.systemCall("fsync picture directory", errno)
            }
          }
        } catch {
          close(next)
          throw error
        }
        close(fd)
        fd = next
      }
      return fd
    } catch {
      close(fd)
      throw error
    }
  }
}
