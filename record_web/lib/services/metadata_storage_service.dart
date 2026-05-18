import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb.dart';

import 'database_manager.dart';

/// Service for storing recording metadata in IndexedDB
class MetadataStorageService {
  MetadataStorageService() {
    DatabaseManager.registerStore(kMetadataStoreName);
  }

  static const kMetadataStoreName = 'metadata';

  Future<void> saveMetadata({
    required String recordingId,
    required int sampleRate,
    required int numChannels,
  }) async {
    try {
      final transaction = await _getTransaction(idbModeReadWrite);
      final store = transaction.objectStore(kMetadataStoreName);

      final metadata = {
        'sampleRate': sampleRate,
        'numChannels': numChannels,
      };
      await store.put(metadata, recordingId);
      await transaction.completed;
    } catch (e) {
      if (kDebugMode) {
        print('Error saving metadata: $e');
      }
    }
  }

  Future<Map<String, dynamic>?> getMetadata(String recordingId) async {
    final transaction = await _getTransaction(idbModeReadOnly);
    final store = transaction.objectStore(kMetadataStoreName);

    final data = await store.getObject(recordingId);
    await transaction.completed;

    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return null;
  }

  Future<void> deleteMetadata(String recordingId) async {
    final transaction = await _getTransaction(idbModeReadWrite);
    final store = transaction.objectStore(kMetadataStoreName);
    await store.delete(recordingId);
    await transaction.completed;
  }

  Future<Transaction> _getTransaction(String mode) {
    return DatabaseManager.instance.getTransaction(kMetadataStoreName, mode);
  }
}
