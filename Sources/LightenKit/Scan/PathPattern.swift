public struct PathPattern: Sendable {
  public let pattern: String
  public let homeDirectory: String
  private let compiled: Compiled?

  private enum Component: Sendable {
    case recursive
    case literal(String)
    case glob([Character])

    func matches(_ value: String) -> Bool {
      switch self {
      case .recursive: return false
      case .literal(let literal): return literal == value
      case .glob(let tokens): return PathPattern.matchesComponent(tokens, value)
      }
    }
  }

  private struct Compiled: Sendable {
    let components: [Component]
    let prefixCount: Int
    let minimumDepth: Int
  }

  public init(_ pattern: String, homeDirectory: String) {
    self.pattern = pattern
    self.homeDirectory = homeDirectory
    self.compiled = Self.compile(pattern, homeDirectory: homeDirectory)
  }

  public func matches(_ path: String) -> Bool {
    guard let target = Self.components(path) else { return false }
    return matches(components: target)
  }

  func matches(components target: [String]) -> Bool {
    guard let compiled, target.count >= compiled.minimumDepth else { return false }
    let rule = compiled.components
    for index in 0..<compiled.prefixCount {
      if !rule[index].matches(target[index]) { return false }
    }
    if compiled.prefixCount == rule.count { return target.count == rule.count }
    // A final recursive component accepts the already checked prefix and
    // every remaining depth, including the prefix itself.
    if compiled.prefixCount == rule.count - 1 { return true }

    let depth = target.count - compiled.prefixCount
    var states = Array(repeating: false, count: depth + 1)
    states[0] = true
    for component in rule.dropFirst(compiled.prefixCount) {
      var next = Array(repeating: false, count: depth + 1)
      if case .recursive = component {
        next[0] = states[0]
        if depth > 0 {
          for index in 1...depth { next[index] = states[index] || next[index - 1] }
        }
      } else {
        for index in 0..<depth where states[index] {
          if component.matches(target[compiled.prefixCount + index]) { next[index + 1] = true }
        }
      }
      states = next
    }
    return states[depth]
  }

  private static func compile(_ pattern: String, homeDirectory: String) -> Compiled? {
    guard let home = components(homeDirectory) else { return nil }

    let expanded: String
    if pattern == "~" {
      expanded = homeDirectory
    } else if pattern.hasPrefix("~/") {
      expanded = "/" + (home + pattern.dropFirst(2).split(separator: "/").map(String.init)).joined(separator: "/")
    } else {
      expanded = pattern
    }

    guard let rule = components(expanded) else { return nil }
    let compiled = rule.map { component -> Component in
      if component == "**" { return .recursive }
      if component.contains("*") { return .glob(Array(component)) }
      return .literal(component)
    }
    return Compiled(
      components: compiled,
      prefixCount: rule.firstIndex(of: "**") ?? rule.count,
      minimumDepth: rule.filter { $0 != "**" }.count)
  }

  static func components(_ path: String) -> [String]? {
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

  private static func matchesComponent(_ tokens: [Character], _ component: String) -> Bool {
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
