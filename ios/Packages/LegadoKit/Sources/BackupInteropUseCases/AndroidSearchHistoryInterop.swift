import AndroidBackupInterop
import AppUseCases

public enum AndroidSearchHistoryInteropAdapter {
  public static func restoreValues(
    _ documents: [AndroidSearchHistoryDTO]
  ) -> [SearchHistoryEntry] {
    documents.map {
      SearchHistoryEntry(
        word: $0.word,
        usage: $0.usage,
        lastUseTime: $0.lastUseTime
      )
    }
  }

  public static func backupDocuments(
    _ values: [SearchHistoryEntry]
  ) -> [AndroidSearchHistoryDTO] {
    values.map {
      AndroidSearchHistoryDTO(
        word: $0.word,
        usage: $0.usage,
        lastUseTime: $0.lastUseTime
      )
    }
  }
}
