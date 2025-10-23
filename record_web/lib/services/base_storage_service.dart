import 'package:idb_shim/idb.dart';

import 'database_manager.dart';

/// Base class for IndexedDB storage services
/// Provides common transaction handling
abstract class BaseStorageService {
  BaseStorageService({required this.storeName});

  final String storeName;

  Future<Transaction> getTransaction(String mode) async {
    final db = await DatabaseManager.instance.getDatabase();
    return db.transaction(storeName, mode);
  }
}
