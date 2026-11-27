import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb.dart';

import 'database_manager.dart';
import 'metadata_storage_service.dart';

/// Service to store audio chunks progressively using IndexedDB
/// This allows recovery of recordings if the page is closed during recording
class AudioChunksStorageService {
  AudioChunksStorageService({this.readPageSize = 5000}) {
    DatabaseManager.registerStore(kChunksStoreName);
  }

  static const kChunksStoreName = 'chunks';

  /// Chunks per IndexedDB response when reading a recording back: one response for a whole multi-hour recording
  /// (~115 MB per hour) could exceed a browser's per-response limit.
  final int readPageSize;

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
    final chunks = <int, Uint8List>{};
    var range = _keyRangeOf(recordingId);

    while (true) {
      // Both lists come back in key order, so they line up index by index.
      final keys = await store.getAllKeys(range, readPageSize);
      final values = await store.getAll(range, readPageSize);

      for (var i = 0; i < keys.length; i++) {
        final chunkIndex = int.parse(keys[i].toString().split('_').last);
        final data = values[i];

        if (data is Uint8List && data.isNotEmpty) {
          chunks[chunkIndex] = data;
        }
      }

      if (keys.length < readPageSize) return chunks;
      range = KeyRange.bound(keys.last, _endOfRange(recordingId), true);
    }
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
      after = _endOfRange(recordingId);
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

  /// Every `${recordingId}_<index>` key. Bounding on the index's digits keeps the chunks of an id like `a_b` out of
  /// `a`'s range; an id that starts with `<other id>_<digit>` still falls in the other id's range.
  KeyRange _keyRangeOf(String recordingId) => KeyRange.bound('${recordingId}_0', _endOfRange(recordingId));

  /// `9` then the highest UTF-16 code unit, so it sorts after every `${recordingId}_<index>` key.
  String _endOfRange(String recordingId) => '${recordingId}_9\uffff';

  Future<Transaction> _getTransaction(String mode) {
    return DatabaseManager.instance.getTransaction(kChunksStoreName, mode);
  }
}
