import 'package:idb_shim/idb_browser.dart';

/// Singleton manager for IndexedDB database
/// Ensures all services share the same database instance
class DatabaseManager {
  DatabaseManager._();

  static final DatabaseManager instance = DatabaseManager._();

  static const kDbName = 'audio_chunks_db';
  static const kDbVersion = 2;

  Database? _db;
  IdbFactory? _customFactory;

  /// Initialize with a custom factory (for testing)
  void setFactory(IdbFactory? factory) {
    _customFactory = factory;
  }

  Future<Database> getDatabase() async {
    final db = _db;
    if (db != null) return db;

    final factory = _customFactory ?? getIdbFactory();

    if (factory == null) {
      throw Exception('No database factory found');
    }

    _db = await factory.open(
      kDbName,
      version: kDbVersion,
      onUpgradeNeeded: (VersionChangeEvent event) {
        _createAllRequiredStores(event.database);
      },
    );

    final openedDb = _db;
    if (openedDb == null) {
      throw Exception('Failed to open database');
    }

    return openedDb;
  }

  void _createAllRequiredStores(Database db) {
    final storeNames = db.objectStoreNames;
    if (!storeNames.contains('chunks')) {
      db.createObjectStore('chunks');
    }
    if (!storeNames.contains('metadata')) {
      db.createObjectStore('metadata');
    }
  }

  Future<void> close() async {
    _db?.close();
    _db = null;
  }
}
