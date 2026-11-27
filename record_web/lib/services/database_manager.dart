import 'package:idb_shim/idb_browser.dart';

/// Singleton manager for IndexedDB database
/// Ensures all services share the same database instance
class DatabaseManager {
  DatabaseManager._();

  static final DatabaseManager instance = DatabaseManager._();

  static const kDbName = 'audio_chunks_db';
  static const kDbVersion = 2;

  static final List<String> _registeredStores = [];

  Future<Database>? _opening;
  IdbFactory? _customFactory;

  /// Register a store name that should be created in the database
  /// This should be called by each storage service during initialization
  static void registerStore(String storeName) {
    if (!_registeredStores.contains(storeName)) {
      _registeredStores.add(storeName);
    }
  }

  /// Initialize with a custom factory (for testing)
  void setFactory(IdbFactory? factory) {
    _customFactory = factory;
  }

  /// Concurrent callers share one open, so a page never holds two connections. A failed open is retried by the
  /// next call.
  Future<Database> getDatabase() async {
    final opening = _opening ??= _open();
    try {
      return await opening;
    } catch (_) {
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
  }

  Future<Database> _open() async {
    final factory = _customFactory ?? getIdbFactory();

    if (factory == null) {
      throw Exception('No database factory found');
    }

    return factory.open(
      kDbName,
      version: kDbVersion,
      onUpgradeNeeded: (VersionChangeEvent event) {
        _createAllRequiredStores(event.database);
      },
    );
  }

  void _createAllRequiredStores(Database db) {
    for (final storeName in _registeredStores) {
      if (!db.objectStoreNames.contains(storeName)) {
        db.createObjectStore(storeName);
      }
    }
  }

  /// Get a transaction for a specific store
  Future<Transaction> getTransaction(String storeName, String mode) async {
    final db = await getDatabase();
    return db.transaction(storeName, mode);
  }

  /// Get one transaction spanning several stores, so reads and writes across them are atomic
  Future<Transaction> getTransactionList(List<String> storeNames, String mode) async {
    final db = await getDatabase();
    return db.transactionList(storeNames, mode);
  }

  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening == null) return;
    try {
      (await opening).close();
    } catch (_) {
      // Nothing to close: the open failed.
    }
  }
}
