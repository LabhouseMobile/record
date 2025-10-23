import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb.dart';

import 'base_storage_service.dart';

/// Service for storing recording metadata in IndexedDB
class MetadataStorageService extends BaseStorageService {
  MetadataStorageService() : super(storeName: kMetadataStoreName);

  static const kMetadataStoreName = 'metadata';

  Future<void> saveMetadata({
    required String recordingId,
    required int sampleRate,
    required int numChannels,
  }) async {
    try {
      final transaction = await getTransaction(idbModeReadWrite);
      final store = transaction.objectStore(storeName);

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
    try {
      final transaction = await getTransaction(idbModeReadOnly);
      final store = transaction.objectStore(storeName);

      final data = await store.getObject(recordingId);
      await transaction.completed;

      if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        print('Error getting metadata: $e');
      }
      return null;
    }
  }

  Future<void> deleteMetadata(String recordingId) async {
    try {
      final transaction = await getTransaction(idbModeReadWrite);
      final store = transaction.objectStore(storeName);
      await store.delete(recordingId);
      await transaction.completed;
    } catch (e) {
      if (kDebugMode) {
        print('Error deleting metadata: $e');
      }
    }
  }
}
