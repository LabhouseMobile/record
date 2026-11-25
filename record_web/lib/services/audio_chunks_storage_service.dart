import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb.dart';

import 'database_manager.dart';
import 'metadata_storage_service.dart';

/// Service to store audio chunks progressively using IndexedDB
/// This allows recovery of recordings if the page is closed during recording
class AudioChunksStorageService {
  AudioChunksStorageService() {
    DatabaseManager.registerStore(kChunksStoreName);
  }

  static const kChunksStoreName = 'chunks';

  Future<void> saveChunk({
    required String recordingId,
    required int chunkIndex,
    required Uint8List chunkData,
  }) async {
    final transaction = await _getTransaction(idbModeReadWrite);
    final store = transaction.objectStore(kChunksStoreName);
    final key = '${recordingId}_$chunkIndex';

    await store.put(chunkData, key);
    await transaction.completed;
  }

  /// Get all chunks for a recording, ordered by chunk index
  Future<List<Uint8List>> getChunks(String recordingId) async {
    final transaction = await _getTransaction(idbModeReadOnly);
    final store = transaction.objectStore(kChunksStoreName);

    final chunks = await _getChunksFrom(store, recordingId);
    await transaction.completed;

    final sortedKeys = chunks.keys.toList()..sort();
    return sortedKeys.map((i) => chunks[i]).whereType<Uint8List>().toList();
  }

  Future<Map<int, Uint8List>> _getChunksFrom(ObjectStore store, String recordingId) async {
    final range = _keyRangeOf(recordingId);
    // Both lists come back in key order, so they line up index by index.
    final keys = await store.getAllKeys(range);
    final values = await store.getAll(range);
    final chunks = <int, Uint8List>{};

    for (var i = 0; i < keys.length; i++) {
      final chunkIndex = int.parse(keys[i].toString().split('_').last);
      final data = values[i];

      if (data is Uint8List && data.isNotEmpty) {
        chunks[chunkIndex] = data;
      }
    }

    return chunks;
  }

  Future<void> deleteChunks(String recordingId) async {
    final transaction = await _getTransaction(idbModeReadWrite);
    final store = transaction.objectStore(kChunksStoreName);

    await store.delete(_keyRangeOf(recordingId));
    await transaction.completed;
  }

  /// Deletes the chunks of every recording that has no metadata left.
  ///
  /// Recovery needs the metadata, so a recording without it can never be recovered: its chunks are what a tab
  /// closed mid-deletion leaves behind. Metadata is written before a recording's first chunk, so a live recording
  /// is never swept. Visits one key per stored recording, not one per chunk.
  Future<void> deleteOrphanChunks() async {
    String? after;
    while (true) {
      final key = await _firstKeyAfter(after);
      if (key == null) return;

      final recordingId = key.substring(0, key.lastIndexOf('_'));
      await _deleteChunksIfNoMetadata(recordingId);
      after = '${recordingId}_\uffff';
    }
  }

  Future<String?> _firstKeyAfter(String? after) async {
    final transaction = await _getTransaction(idbModeReadOnly);
    final store = transaction.objectStore(kChunksStoreName);
    final keys = await store.getAllKeys(after == null ? null : KeyRange.lowerBound(after, true), 1);
    await transaction.completed;
    return keys.isEmpty ? null : keys.single.toString();
  }

  Future<void> _deleteChunksIfNoMetadata(String recordingId) async {
    final transaction = await DatabaseManager.instance.getTransactionList(
      [kChunksStoreName, MetadataStorageService.kMetadataStoreName],
      idbModeReadWrite,
    );
    final metadata = await transaction.objectStore(MetadataStorageService.kMetadataStoreName).getObject(recordingId);
    if (metadata == null) {
      await transaction.objectStore(kChunksStoreName).delete(_keyRangeOf(recordingId));
    }
    await transaction.completed;
  }

  /// Every key that starts with `${recordingId}_`: chunk keys are `${recordingId}_<index>`.
  KeyRange _keyRangeOf(String recordingId) => KeyRange.bound('${recordingId}_', '${recordingId}_\uffff');

  Future<Transaction> _getTransaction(String mode) {
    return DatabaseManager.instance.getTransaction(kChunksStoreName, mode);
  }
}
