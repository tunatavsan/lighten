import Foundation

/// An expected metadata observation. Only a fresh no-follow inspection can
/// establish the current package layout and identifier for an action.
public struct ApplicationPackageObservation: Codable, Sendable, Equatable {
  public let infoRelativePath: String
  public let infoIdentity: FileIdentity
  public let bundleIdentifier: String?

  public init(infoRelativePath: String, infoIdentity: FileIdentity, bundleIdentifier: String?) {
    self.infoRelativePath = infoRelativePath
    self.infoIdentity = infoIdentity
    self.bundleIdentifier = bundleIdentifier
  }
}
