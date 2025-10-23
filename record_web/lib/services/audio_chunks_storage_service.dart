import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb.dart';

import 'base_storage_service.dart';

/// Service to store audio chunks progressively using IndexedDB
/// This allows recovery of recordings if the page is closed during recording
class AudioChunksStorageService extends BaseStorageService {
  AudioChunksStorageService() : super(storeName: kChunksStoreName);

  static const kChunksStoreName = 'chunks';

  Future<void> saveChunk({
    required String recordingId,
    required int chunkIndex,
    required Uint8List chunkData,
  }) async {
    try {
      final transaction = await getTransaction(idbModeReadWrite);
      final store = transaction.objectStore(storeName);
      final key = '${recordingId}_$chunkIndex';

      await store.put(chunkData, key);
      await transaction.completed;
    } catch (e) {
      if (kDebugMode) {
        print('Error saving chunk: $e');
      }
      rethrow;
    }
  }

  /// Get all chunks for a recording, ordered by chunk index
  Future<List<Uint8List>> getChunks(String recordingId) async {
    final transaction = await getTransaction(idbModeReadOnly);
    final store = transaction.objectStore(storeName);

    final chunks = await _getChunksFrom(store, recordingId);
    await transaction.completed;

    final sortedKeys = chunks.keys.toList()..sort();
    return sortedKeys.map((i) => chunks[i]).whereType<Uint8List>().toList();
  }

  Future<Map<int, Uint8List>> _getChunksFrom(ObjectStore store, String recordingId) async {
    final keys = await store.getAllKeys();
    final chunks = <int, Uint8List>{};

    for (final key in keys) {
      final keyStr = key.toString();
      if (keyStr.startsWith('${recordingId}_')) {
        final chunkIndex = int.parse(keyStr.split('_').last);
        final data = await store.getObject(key);

        if (data is Uint8List && data.isNotEmpty) {
          chunks[chunkIndex] = data;
        }
      }
    }

    return chunks;
  }

  Future<void> deleteChunks(String recordingId) async {
    try {
      final transaction = await getTransaction(idbModeReadWrite);
      final store = transaction.objectStore(storeName);

      final keysToDelete = await _getKeysToDelete(
        store: store,
        recordingId: recordingId,
      );

      await _deleteEachKey(keysToDelete, store);
      await transaction.completed;
    } catch (e) {
      if (kDebugMode) {
        print('Error deleting chunks: $e');
      }
      rethrow;
    }
  }

  Future<List<String>> _getKeysToDelete({
    required ObjectStore store,
    required String recordingId,
  }) async {
    final keys = await store.getAllKeys();
    return keys.where((key) => key.toString().startsWith('${recordingId}_')).map((key) => key.toString()).toList();
  }

  Future<void> _deleteEachKey(List<String> keysToDelete, ObjectStore store) async {
    for (final key in keysToDelete) {
      await store.delete(key);
    }
  }

  /// Get all unique recording IDs that have chunks stored
  Future<List<String>> getRecordingIds() async {
    try {
      final transaction = await getTransaction(idbModeReadOnly);
      final store = transaction.objectStore(storeName);

      final recordingIds = await _getRecordingIdsFrom(store);
      await transaction.completed;

      return recordingIds;
    } catch (e) {
      if (kDebugMode) {
        print('Error getting recording IDs: $e');
      }
      return [];
    }
  }

  Future<List<String>> _getRecordingIdsFrom(ObjectStore store) async {
    final keys = await store.getAllKeys();
    return keys.where((key) => key.toString().contains('_')).map((key) => key.toString().split('_').first).toSet().toList();
  }
}
