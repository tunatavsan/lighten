import Foundation

/// Uses only names already observed for display; it never walks a selected folder.
enum SelectionWarning {
  nonisolated static func example(in paths: [String]) -> String? {
    paths.first { path in
      let name = (path as NSString).lastPathComponent.lowercased()
      return [".ssh", "keychains", "mail", "messages", ".env", "id_rsa"].contains(name)
        || [".photoslibrary", ".photolibrary", ".fcpbundle", ".logicx", ".band", ".imovielibrary", ".musiclibrary"]
          .contains {
            name.hasSuffix($0)
          }
    }
  }
}
