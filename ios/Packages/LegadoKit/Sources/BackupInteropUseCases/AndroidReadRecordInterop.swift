import AndroidBackupInterop
import LibraryDomain

public enum AndroidReadRecordInteropAdapter {
  public static func restoreValues(
    _ documents: [AndroidReadRecordDTO]
  ) -> [ReadRecord] {
    documents.map { document in
      let value = document.restoreProjection
      return ReadRecord(
        deviceID: value.deviceID,
        bookName: value.bookName,
        readTime: value.readTime,
        lastRead: value.lastRead
      )
    }
  }

  public static func backupDocuments(
    _ values: [ReadRecord]
  ) -> [AndroidReadRecordDTO] {
    values.map { value in
      AndroidReadRecordDTO(
        deviceID: value.deviceID,
        bookName: value.bookName,
        readTime: value.readTime,
        lastRead: value.lastRead
      )
    }
  }
}
