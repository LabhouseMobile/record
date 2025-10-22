import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_browser.dart';

/// Service to store audio chunks progressively using IndexedDB
/// This allows recovery of recordings if the page is closed during recording
class AudioChunksStorageService {
  AudioChunksStorageService({IdbFactory? idbFactory})
      : _idbFactory = idbFactory;

  static const _kDbName = 'audio_chunks_db';
  static const _kStoreName = 'chunks';
  static const _kDbVersion = 1;

  final IdbFactory? _idbFactory;
  Database? _db;

  Future<Transaction> _getTransaction(String mode) async {
    await _initializeIfNeeded();
    final db = _db;
    if (db == null) {
      throw Exception('Database not initialized');
    }
    return db.transaction(_kStoreName, mode);
  }

  Future<void> _initializeIfNeeded() async {
    if (_db != null) return;

    try {
      final factory = _idbFactory ?? getIdbFactory();

      if (factory == null) {
        throw Exception('No database factory found');
      }

      _db = await factory.open(
        _kDbName,
        version: _kDbVersion,
        onUpgradeNeeded: (VersionChangeEvent event) {
          final db = event.database;
          final chunksStoreExists = db.objectStoreNames.contains(_kStoreName);
          if (!chunksStoreExists) {
            db.createObjectStore(_kStoreName);
          }
        },
      );
    } catch (e) {
      if (kDebugMode) {
        print('Error initializing database: $e');
      }
      rethrow;
    }
  }

  Future<void> saveChunk({
    required String recordingId,
    required int chunkIndex,
    required Uint8List chunkData,
  }) async {
    try {
      final transaction = await _getTransaction(idbModeReadWrite);
      final store = transaction.objectStore(_kStoreName);
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
    try {
      final transaction = await _getTransaction(idbModeReadOnly);
      final store = transaction.objectStore(_kStoreName);

      final chunks = await _getChunksFrom(store, recordingId);
      await transaction.completed;

      final sortedKeys = chunks.keys.toList()..sort();
      return sortedKeys.map((i) => chunks[i]).whereType<Uint8List>().toList();
    } catch (e) {
      if (kDebugMode) {
        print('Error getting chunks: $e');
      }
      return [];
    }
  }

  Future<Map<int, Uint8List>> _getChunksFrom(
      ObjectStore store, String recordingId) async {
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
      final transaction = await _getTransaction(idbModeReadWrite);
      final store = transaction.objectStore(_kStoreName);

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
    return keys
        .where((key) => key.toString().startsWith('${recordingId}_'))
        .map((key) => key.toString())
        .toList();
  }

  Future<void> _deleteEachKey(List<String> keys, ObjectStore store) async {
    for (final key in keys) {
      await store.delete(key);
    }
  }

  Future<List<String>> getRecordingIds() async {
    try {
      final transaction = await _getTransaction(idbModeReadOnly);
      final store = transaction.objectStore(_kStoreName);

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
    return keys
        .where((key) => key.toString().contains('_'))
        .map((key) => key.toString().split('_').first)
        .toSet()
        .toList();
  }

  /// Close the database connection
  Future<void> close() async {
    _db?.close();
    _db = null;
  }
}
