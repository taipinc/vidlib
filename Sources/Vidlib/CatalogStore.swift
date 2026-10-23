import CSQLite
import Foundation

/// Only opens the app-owned database. Media URLs are data, never write targets.
final class CatalogStore {
  private var db: OpaquePointer?
  private let url: URL
  init(url: URL) throws {
    self.url = url
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw failure() }
    try execute("PRAGMA journal_mode=WAL")
    try execute(
      "CREATE TABLE IF NOT EXISTS catalog (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL)"
    )
  }
  deinit { sqlite3_close(db) }

  func load() throws -> CatalogSnapshot {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(db, "SELECT payload FROM catalog WHERE id = 1", -1, &statement, nil)
        == SQLITE_OK
    else { throw failure() }
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return CatalogSnapshot() }
    guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
      throw failure()
    }
    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    var snapshot = try JSONDecoder().decode(CatalogSnapshot.self, from: data)
    if snapshot.schemaVersion == nil {
      try backupLegacyCatalog()
      snapshot.schemaVersion = 2
    }
    return snapshot
  }

  private func backupLegacyCatalog() throws {
    let backupURL = url.deletingPathExtension().appendingPathExtension("before-v2.sqlite")
    guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
    var destination: OpaquePointer?
    guard sqlite3_open(backupURL.path, &destination) == SQLITE_OK else {
      sqlite3_close(destination)
      throw failure()
    }
    defer { sqlite3_close(destination) }
    guard let backup = sqlite3_backup_init(destination, "main", db, "main") else { throw failure() }
    let result = sqlite3_backup_step(backup, -1)
    let finish = sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE, finish == SQLITE_OK else { throw failure() }
  }

  func save(_ snapshot: CatalogSnapshot) throws {
    let data = try JSONEncoder().encode(snapshot)
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db, "INSERT OR REPLACE INTO catalog(id, payload) VALUES(1, ?)", -1, &statement, nil)
        == SQLITE_OK
    else { throw failure() }
    defer { sqlite3_finalize(statement) }
    let result = data.withUnsafeBytes { bytes in
      sqlite3_bind_blob(
        statement, 1, bytes.baseAddress, Int32(bytes.count),
        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
  }
  private func failure() -> NSError {
    NSError(
      domain: "Vidlib.Catalog", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) }
          ?? "Could not open catalog."
      ])
  }
}
