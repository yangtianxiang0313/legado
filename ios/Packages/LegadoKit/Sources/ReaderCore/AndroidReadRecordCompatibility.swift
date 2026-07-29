import LibraryDomain

public protocol ReadRecordStore: Sendable {
  func records(bookName: String) async throws -> [ReadRecord]
  func upsert(_ record: ReadRecord) async throws
}

public struct ReadRecordSession: Equatable, Sendable {
  public let bookName: String
  public let deviceID: String
  public let readTime: Int64
  public let readStartTimeMilliseconds: Int64

  public init(
    bookName: String,
    deviceID: String,
    readTime: Int64,
    readStartTimeMilliseconds: Int64
  ) {
    self.bookName = bookName
    self.deviceID = deviceID
    self.readTime = readTime
    self.readStartTimeMilliseconds = readStartTimeMilliseconds
  }
}

public struct ReadRecordSessionUpdate: Equatable, Sendable {
  public let session: ReadRecordSession
  public let recordToPersist: ReadRecord?

  public init(
    session: ReadRecordSession,
    recordToPersist: ReadRecord?
  ) {
    self.session = session
    self.recordToPersist = recordToPersist
  }
}

public enum AndroidReadRecordCompatibility {
  public static func insertingReplacingByCompositeKey(
    _ records: [ReadRecord]
  ) -> [ReadRecord] {
    var result: [ReadRecord] = []
    var indexByKey: [ReadRecordKey: Int] = [:]
    for record in records {
      let key = ReadRecordKey(
        deviceID: record.deviceID,
        bookName: record.bookName
      )
      if let index = indexByKey[key] {
        result[index] = record
      } else {
        indexByKey[key] = result.count
        result.append(record)
      }
    }
    return result
  }

  public static func aggregateReadTime(
    _ records: [ReadRecord],
    bookName: String? = nil
  ) -> Int64 {
    insertingReplacingByCompositeKey(records)
      .lazy
      .filter { bookName == nil || $0.bookName == bookName }
      .reduce(Int64(0)) { $0 &+ $1.readTime }
  }

  public static func readTime(
    _ records: [ReadRecord],
    deviceID: String,
    bookName: String
  ) -> Int64? {
    insertingReplacingByCompositeKey(records)
      .first {
        $0.deviceID == deviceID && $0.bookName == bookName
      }?
      .readTime
  }

  public static func resetSession(
    records: [ReadRecord],
    bookName: String,
    readStartTimeMilliseconds: Int64
  ) -> ReadRecordSession {
    ReadRecordSession(
      bookName: bookName,
      deviceID: "",
      readTime: aggregateReadTime(records, bookName: bookName),
      readStartTimeMilliseconds: readStartTimeMilliseconds
    )
  }

  public static func updateReadTime(
    session: ReadRecordSession,
    nowMilliseconds: Int64,
    recordingEnabled: Bool
  ) -> ReadRecordSessionUpdate {
    guard recordingEnabled else {
      return ReadRecordSessionUpdate(
        session: session,
        recordToPersist: nil
      )
    }
    let elapsedSeconds =
      (nowMilliseconds &- session.readStartTimeMilliseconds) / 1_000
    let updated = ReadRecordSession(
      bookName: session.bookName,
      deviceID: session.deviceID,
      readTime: session.readTime &+ elapsedSeconds,
      readStartTimeMilliseconds: nowMilliseconds
    )
    return ReadRecordSessionUpdate(
      session: updated,
      recordToPersist: ReadRecord(
        deviceID: updated.deviceID,
        bookName: updated.bookName,
        readTime: updated.readTime,
        lastRead: nowMilliseconds
      )
    )
  }

  public static func saveReadWithoutSettling(
    session: ReadRecordSession
  ) -> ReadRecordSession {
    session
  }
}

public enum NativeReadRecordPolicy {
  public static func resetSession(
    records: [ReadRecord],
    bookName: String,
    deviceID: String,
    readStartTimeMilliseconds: Int64
  ) -> ReadRecordSession {
    ReadRecordSession(
      bookName: bookName,
      deviceID: deviceID,
      readTime:
        AndroidReadRecordCompatibility.readTime(
          records,
          deviceID: deviceID,
          bookName: bookName
        ) ?? 0,
      readStartTimeMilliseconds: readStartTimeMilliseconds
    )
  }

  public static func settle(
    session: ReadRecordSession,
    nowMilliseconds: Int64
  ) -> ReadRecordSessionUpdate {
    AndroidReadRecordCompatibility.updateReadTime(
      session: session,
      nowMilliseconds: nowMilliseconds,
      recordingEnabled: true
    )
  }
}
