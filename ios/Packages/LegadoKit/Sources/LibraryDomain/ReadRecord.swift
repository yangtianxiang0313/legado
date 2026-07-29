public struct ReadRecord: Equatable, Hashable, Sendable {
  public let deviceID: String
  public let bookName: String
  public let readTime: Int64
  public let lastRead: Int64

  public init(
    deviceID: String = "",
    bookName: String,
    readTime: Int64 = 0,
    lastRead: Int64 = 0
  ) {
    self.deviceID = deviceID
    self.bookName = bookName
    self.readTime = readTime
    self.lastRead = lastRead
  }
}

public struct ReadRecordKey: Equatable, Hashable, Sendable {
  public let deviceID: String
  public let bookName: String

  public init(deviceID: String, bookName: String) {
    self.deviceID = deviceID
    self.bookName = bookName
  }
}
