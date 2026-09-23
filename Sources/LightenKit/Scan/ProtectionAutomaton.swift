import Foundation

/// NeverRule patterns compiled into per-rule position sets so a walker can
/// derive a child's protection from its parent's state and one name, without
/// re-splitting full paths. Matching is case-folded, which is a superset of
/// `ProtectionPolicy` (exact spelling, then case aliases).
public struct ProtectionAutomaton: Sendable {
  public struct State: Sendable, Equatable {
    fileprivate var positions: [UInt64]
  }

  private struct Rule: Sendable {
    let rule: NeverRule
    let components: [String]
  }

  private let rules: [Rule]
  /// Rules the automaton cannot compile; callers with a path check them directly.
  public let uncompiled: [NeverRule]
  public let initial: State

  public init(rules: [NeverRule] = NeverRule.all, homeDirectory: String) {
    let locale = Locale(identifier: "en_US_POSIX")
    let home = homeDirectory.lowercased(with: locale).split(separator: "/").map(String.init)
    let compiled = rules.compactMap { rule -> Rule? in
      let pattern = rule.pattern.lowercased(with: locale)
      var parts: [String]
      if pattern == "~" {
        parts = home
      } else if pattern.hasPrefix("~/") {
        parts = home + pattern.dropFirst(2).split(separator: "/").map(String.init)
      } else if pattern.hasPrefix("/") {
        parts = pattern.split(separator: "/").map(String.init)
      } else {
        return nil
      }
      guard parts.count < 63 else { return nil }
      return Rule(rule: rule, components: parts)
    }
    self.rules = compiled
    self.uncompiled = rules.filter { rule in !compiled.contains { $0.rule.id == rule.id } }
    self.initial = State(positions: compiled.map { Self.closure(1, $0.components) })
  }

  /// State after the absolute path's components, starting at "/".
  public func state(forPath path: String) -> State {
    var state = initial
    for component in path.split(separator: "/") where component != "." {
      state = step(state, String(component))
    }
    return state
  }

  public func step(_ state: State, _ name: String) -> State {
    let folded = name.lowercased(with: Locale(identifier: "en_US_POSIX"))
    var next = state.positions
    for index in rules.indices {
      let components = rules[index].components
      let current = state.positions[index]
      var reached: UInt64 = 0
      if current != 0 {
        for position in 0..<components.count where current & (1 << UInt64(position)) != 0 {
          let pattern = components[position]
          if pattern == "**" {
            reached |= 1 << UInt64(position)
          } else if Self.matches(pattern, folded) {
            reached |= 1 << UInt64(position + 1)
          }
        }
      }
      next[index] = Self.closure(reached, components)
    }
    return State(positions: next)
  }

  /// The first rule accepting this exact state, in `NeverRule.all` order.
  public func match(_ state: State) -> NeverRule? {
    for index in rules.indices {
      let accept: UInt64 = 1 << UInt64(rules[index].components.count)
      if state.positions[index] & accept != 0 { return rules[index].rule }
    }
    return nil
  }

  /// Every rule accepting this exact state, in `NeverRule.all` order.
  public func matches(_ state: State) -> [NeverRule] {
    rules.indices.compactMap { index in
      let accept: UInt64 = 1 << UInt64(rules[index].components.count)
      return state.positions[index] & accept != 0 ? rules[index].rule : nil
    }
  }

  /// `matches` plus any uncompiled rule matching `path`, so no rule fails open.
  public func matches(_ state: State, path: String, homeDirectory: String) -> [NeverRule] {
    var result = matches(state)
    for rule in uncompiled where ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory)?.id == rule.id {
      result.append(rule)
    }
    return result
  }

  /// True when no rule can accept this state or any descendant state.
  public func isInert(_ state: State) -> Bool {
    state.positions.allSatisfy { $0 == 0 }
  }

  private static func closure(_ positions: UInt64, _ components: [String]) -> UInt64 {
    var value = positions
    for position in 0..<components.count where value & (1 << UInt64(position)) != 0 {
      if components[position] == "**" { value |= 1 << UInt64(position + 1) }
    }
    return value
  }

  private static func matches(_ pattern: String, _ name: String) -> Bool {
    if !pattern.contains("*") { return pattern == name }
    let tokens = Array(pattern.utf8)
    let characters = Array(name.utf8)
    var states = [Bool](repeating: false, count: characters.count + 1)
    states[0] = true
    for token in tokens {
      var next = [Bool](repeating: false, count: characters.count + 1)
      if token == UInt8(ascii: "*") {
        next[0] = states[0]
        if !characters.isEmpty {
          for index in 1...characters.count { next[index] = states[index] || next[index - 1] }
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
