@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:record_web/record_web.dart';
import 'package:record_web/services/audio_chunks_storage_service.dart';
import 'package:record_web/services/database_manager.dart';
import 'package:record_web/services/metadata_storage_service.dart';

class _FailingChunkDeleteService extends AudioChunksStorageService {
  @override
  Future<void> deleteChunks(String recordingId) => Future.error(StateError('chunk delete failed'));
}

void main() {
  late AudioChunksStorageService chunksService;
  late MetadataStorageService metadataService;
  late RecordPluginWebWrapper plugin;

  setUp(() {
    DatabaseManager.instance.setFactory(newIdbFactoryMemory());
    chunksService = AudioChunksStorageService();
    metadataService = MetadataStorageService();
    plugin = RecordPluginWebWrapper(chunksService: chunksService, metadataService: metadataService);
  });

  tearDown(() => DatabaseManager.instance.close());

  Future<void> saveRecording(String recordingId, {bool withMetadata = true}) async {
    if (withMetadata) {
      await metadataService.saveMetadata(recordingId: recordingId, sampleRate: 16000, numChannels: 1);
    }
    for (var i = 1; i <= 3; i++) {
      await chunksService.saveChunk(recordingId: recordingId, chunkIndex: i, chunkData: Uint8List.fromList([i, 0]));
    }
  }

  group('deleteRecording', () {
    test('leaves neither metadata nor chunks', () async {
      await saveRecording('recording');

      await plugin.deleteRecording('recording');

      expect(await metadataService.getMetadata('recording'), isNull);
      expect(await chunksService.getChunks('recording'), isEmpty);
    });

    test('deletes the metadata first, so a failed chunk delete leaves chunks the sweep clears', () async {
      await saveRecording('recording');
      final failingPlugin = RecordPluginWebWrapper(
        chunksService: _FailingChunkDeleteService(),
        metadataService: metadataService,
      );

      await expectLater(failingPlugin.deleteRecording('recording'), throwsStateError);

      expect(await metadataService.getMetadata('recording'), isNull);
      expect(await plugin.recoverRecording('recording'), isNull);

      await chunksService.deleteOrphanChunks();

      expect(await chunksService.getChunks('recording'), isEmpty);
    });
  });

  group('recoverRecording', () {
    test('returns a WAV of the stored chunks', () async {
      await saveRecording('recording');

      final wav = await plugin.recoverRecording('recording');

      expect(String.fromCharCodes(wav!.sublist(0, 4)), 'RIFF');
      expect(Int16List.sublistView(wav, 44), [1, 2, 3]);
    });

    test('returns null for chunks without metadata', () async {
      await saveRecording('orphan', withMetadata: false);

      expect(await plugin.recoverRecording('orphan'), isNull);
    });
  });

  group('create', () {
    test('sweeps orphan chunks on the first call and keeps recoverable recordings', () async {
      await saveRecording('orphan', withMetadata: false);
      await saveRecording('recoverable');

      await plugin.create('recorder');
      await plugin.orphanSweep;

      expect(await chunksService.getChunks('orphan'), isEmpty);
      expect(await chunksService.getChunks('recoverable'), hasLength(3));
    });

    test('sweeps only once per page load', () async {
      await plugin.create('first');
      final firstSweep = plugin.orphanSweep;

      await plugin.create('second');

      expect(plugin.orphanSweep, same(firstSweep));
    });
  });
}
