import GRDB

/// Keeps GRDB types behind the platform persistence adapter boundary.
public enum DatabaseGRDBRuntime {
  public static func verifyInMemoryDatabase() throws -> Bool {
    let queue = try DatabaseQueue(path: ":memory:")
    try queue.write { database in
      try database.execute(
        sql: """
          CREATE TABLE dependency_probe (
            id INTEGER PRIMARY KEY,
            value TEXT NOT NULL
          )
          """
      )
      try database.execute(
        sql: "INSERT INTO dependency_probe (value) VALUES (?)",
        arguments: ["ready"]
      )
    }
    return try queue.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT value FROM dependency_probe LIMIT 1"
      ) == "ready"
    }
  }
}
