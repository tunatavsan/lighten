import Foundation
import Testing

@testable import Lighten

private actor IconLoads {
  var count = 0
  func load(_ path: String) -> Data {
    count += 1
    return Data(path.utf8)
  }
}

@Test("Visible application icons share cached asynchronous loads")
func applicationIconCacheReusesLoad() async {
  let loads = IconLoads()
  let cache = ApplicationIconCache(load: { await loads.load($0) })
  async let first = cache.iconData(for: "/Applications/LightenQA-fixture.app")
  async let second = cache.iconData(for: "/Applications/LightenQA-fixture.app")
  let pair = await (first, second)
  #expect(pair.0 == pair.1)
  #expect(await cache.iconData(for: "/Applications/LightenQA-fixture.app") == pair.0)
  #expect(await loads.count == 1)
}
