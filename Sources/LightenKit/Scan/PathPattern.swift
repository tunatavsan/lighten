public struct PathPattern: Sendable {
  public let pattern: String
  public let homeDirectory: String

  public init(_ pattern: String, homeDirectory: String) {
    self.pattern = pattern
    self.homeDirectory = homeDirectory
  }

  public func matches(_ path: String) -> Bool {
    guard let target = Self.components(path), let home = Self.components(homeDirectory) else {
      return false
    }

    let expanded: String
    if pattern == "~" {
      expanded = homeDirectory
    } else if pattern.hasPrefix("~/") {
      expanded = "/" + (home + pattern.dropFirst(2).split(separator: "/").map(String.init)).joined(separator: "/")
    } else {
      expanded = pattern
    }

    guard let rule = Self.components(expanded) else { return false }
    var states = Array(repeating: false, count: target.count + 1)
    states[0] = true

    for component in rule {
      var next = Array(repeating: false, count: target.count + 1)
      if component == "**" {
        next[0] = states[0]
        if !target.isEmpty {
          for index in 1...target.count {
            next[index] = states[index] || next[index - 1]
          }
        }
      } else {
        for index in target.indices where states[index] {
          if Self.matchesComponent(component, target[index]) {
            next[index + 1] = true
          }
        }
      }
      states = next
    }
    return states[target.count]
  }

  private static func components(_ path: String) -> [String]? {
    guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
    var components: [String] = []
    for component in path.split(separator: "/") {
      if component == "." { continue }
      if component == ".." {
        guard !components.isEmpty else { return nil }
        components.removeLast()
      } else {
        components.append(String(component))
      }
    }
    return components
  }

  private static func matchesComponent(_ pattern: String, _ component: String) -> Bool {
    if !pattern.contains("*") { return pattern == component }
    let tokens = Array(pattern)
    let characters = Array(component)
    var states = Array(repeating: false, count: characters.count + 1)
    states[0] = true
    for token in tokens {
      var next = Array(repeating: false, count: characters.count + 1)
      if token == "*" {
        next[0] = states[0]
        if !characters.isEmpty {
          for index in 1...characters.count {
            next[index] = states[index] || next[index - 1]
          }
        }
      } else {
        for index in characters.indices where states[index] && characters[index] == token {
          next[index + 1] = true
        }
      }
      states = next
    }
    return states[characters.count]
  }
}
