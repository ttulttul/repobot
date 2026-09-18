import Foundation

/// Value-semantic snapshot storage. Changing one record copies a 32-record page,
/// rather than every repository retained by another observer or actor.
public struct SnapshotList<Element>: RandomAccessCollection, MutableCollection, ExpressibleByArrayLiteral {
  private static var pageSize: Int { 32 }
  private var pages: [ContiguousArray<Element>] = []
  public private(set) var count = 0
  public var startIndex: Int { 0 }
  public var endIndex: Int { count }
  public init() {}
  public init<S: Sequence>(_ values: S) where S.Element == Element {
    for value in values { append(value) }
  }
  public init(arrayLiteral elements: Element...) { self.init(elements) }
  public subscript(index: Int) -> Element {
    get {
      precondition(index >= 0 && index < count)
      return pages[index / Self.pageSize][index % Self.pageSize]
    }
    _modify {
      precondition(index >= 0 && index < count)
      yield &pages[index / Self.pageSize][index % Self.pageSize]
    }
  }
  public mutating func append(_ value: Element) {
    if count % Self.pageSize == 0 { pages.append([]) }
    pages[pages.count - 1].append(value)
    count += 1
  }
  @discardableResult public mutating func remove(at index: Int) -> Element {
    var values = Array(self)
    let removed = values.remove(at: index)
    self = Self(values)
    return removed
  }
  @discardableResult public mutating func removeLast() -> Element {
    precondition(count > 0)
    let value = pages[pages.count - 1].removeLast()
    count -= 1
    if count % Self.pageSize == 0 { pages.removeLast() }
    return value
  }
  // Used to verify that retained snapshots share unchanged pages without mutation.
  var pageStorage: [UInt] { pages.map { $0.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) } } }
}
extension SnapshotList: Sendable where Element: Sendable {}
extension SnapshotList: Equatable where Element: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.elementsEqual(rhs) }
}
extension SnapshotList: Codable where Element: Codable {
  public init(from decoder: any Decoder) throws {
    self.init()
    var values = try decoder.unkeyedContainer()
    while !values.isAtEnd { append(try values.decode(Element.self)) }
  }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.unkeyedContainer()
    for value in self { try values.encode(value) }
  }
}
