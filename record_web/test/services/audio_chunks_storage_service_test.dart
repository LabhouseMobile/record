import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_io.dart';
import 'package:record_web/services/audio_chunks_storage_service.dart';

void main() {
  group('AudioChunksStorageService', () {
    late AudioChunksStorageService service;
    late IdbFactory factory;

    setUp(() {
      // Use NEW in-memory database for each test
      factory = idbFactoryMemoryFs;
      service = AudioChunksStorageService(idbFactory: factory);
    });

    tearDown(() async {
      await service.close();
      // Delete the database to ensure clean state
      await factory.deleteDatabase('audio_chunks_db');
    });

    group('saveChunk', () {
      group('returns', () {
        test('completes successfully when chunk is saved', () async {
          const recordingId = 'test-recording-id';
          const chunkIndex = 0;
          final chunkData = Uint8List.fromList([1, 2, 3, 4]);

          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: chunkIndex,
            chunkData: chunkData,
          );

          // Verify it was saved
          final chunks = await service.getChunks(recordingId);
          expect(chunks, hasLength(1));
          expect(chunks[0], equals(chunkData));
        });
      });

      group('stores', () {
        test('chunk with correct key and data', () async {
          const recordingId = 'test-recording-id';
          const chunkIndex = 5;
          final chunkData = Uint8List.fromList([1, 2, 3, 4]);

          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: chunkIndex,
            chunkData: chunkData,
          );

          final retrievedChunks = await service.getChunks(recordingId);
          expect(retrievedChunks, hasLength(1));
          expect(retrievedChunks[0], equals(chunkData));
        });

        test('multiple chunks in order', () async {
          const recordingId = 'test-recording-id';
          final chunk0 = Uint8List.fromList([1, 2]);
          final chunk1 = Uint8List.fromList([3, 4]);
          final chunk2 = Uint8List.fromList([5, 6]);

          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: 0,
            chunkData: chunk0,
          );
          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: 1,
            chunkData: chunk1,
          );
          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: 2,
            chunkData: chunk2,
          );

          final chunks = await service.getChunks(recordingId);
          expect(chunks, hasLength(3));
          expect(chunks[0], equals(chunk0));
          expect(chunks[1], equals(chunk1));
          expect(chunks[2], equals(chunk2));
        });
      });
    });

    group('getChunks', () {
      group('returns', () {
        test('empty list when no chunks found', () async {
          const recordingId = 'test-recording-id';

          final result = await service.getChunks(recordingId);

          expect(result, isEmpty);
        });

        test('chunks sorted by index when added out of order', () async {
          const recordingId = 'test-recording-id';
          final chunk0 = Uint8List.fromList([10, 20]);
          final chunk1 = Uint8List.fromList([30, 40]);
          final chunk2 = Uint8List.fromList([50, 60]);

          // Add chunks out of order
          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: 2,
            chunkData: chunk2,
          );
          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: 0,
            chunkData: chunk0,
          );
          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: 1,
            chunkData: chunk1,
          );

          final result = await service.getChunks(recordingId);

          expect(result, hasLength(3));
          expect(result[0], equals(chunk0));
          expect(result[1], equals(chunk1));
          expect(result[2], equals(chunk2));
        });

        test('only chunks for specified recordingId', () async {
          const recordingId = 'test-recording-id';
          const otherRecordingId = 'other-recording-id';
          final chunk0 = Uint8List.fromList([10, 20]);
          final otherChunk0 = Uint8List.fromList([30, 40]);

          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: 0,
            chunkData: chunk0,
          );
          await service.saveChunk(
            recordingId: otherRecordingId,
            chunkIndex: 0,
            chunkData: otherChunk0,
          );

          final result = await service.getChunks(recordingId);

          expect(result, hasLength(1));
          expect(result[0], equals(chunk0));
        });
      });
    });

    group('deleteChunks', () {
      group('returns', () {
        test('completes successfully when chunks are deleted', () async {
          const recordingId = 'test-recording-id';
          final chunk0 = Uint8List.fromList([1, 2, 3]);
          final chunk1 = Uint8List.fromList([4, 5, 6]);

          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: 0,
            chunkData: chunk0,
          );
          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: 1,
            chunkData: chunk1,
          );

          await service.deleteChunks(recordingId);

          final result = await service.getChunks(recordingId);
          expect(result, isEmpty);
        });
      });

      group('deletes', () {
        test('only chunks with matching recordingId', () async {
          const recordingId = 'test-recording-id';
          const otherRecordingId = 'other-recording-id';
          final chunk0 = Uint8List.fromList([1, 2]);
          final chunk1 = Uint8List.fromList([3, 4]);
          final otherChunk = Uint8List.fromList([5, 6]);

          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: 0,
            chunkData: chunk0,
          );
          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: 1,
            chunkData: chunk1,
          );
          await service.saveChunk(
            recordingId: otherRecordingId,
            chunkIndex: 0,
            chunkData: otherChunk,
          );

          await service.deleteChunks(recordingId);

          final result = await service.getChunks(recordingId);
          final otherResult = await service.getChunks(otherRecordingId);

          expect(result, isEmpty);
          expect(otherResult, hasLength(1));
          expect(otherResult[0], equals(otherChunk));
        });
      });
    });

    group('getRecordingIds', () {
      group('returns', () {
        test('empty list when no chunks exist', () async {
          final result = await service.getRecordingIds();

          expect(result, isEmpty);
        });

        test('unique recording IDs when multiple chunks exist', () async {
          final chunk0 = Uint8List.fromList([1, 2]);
          final chunk1 = Uint8List.fromList([3, 4]);

          await service.saveChunk(
            recordingId: 'recording-1',
            chunkIndex: 0,
            chunkData: chunk0,
          );
          await service.saveChunk(
            recordingId: 'recording-1',
            chunkIndex: 1,
            chunkData: chunk1,
          );
          await service.saveChunk(
            recordingId: 'recording-2',
            chunkIndex: 0,
            chunkData: chunk0,
          );
          await service.saveChunk(
            recordingId: 'recording-3',
            chunkIndex: 0,
            chunkData: chunk0,
          );

          final result = await service.getRecordingIds();

          expect(result, hasLength(3));
          expect(result, contains('recording-1'));
          expect(result, contains('recording-2'));
          expect(result, contains('recording-3'));
        });
      });
    });

    group('close', () {
      test('completes successfully', () async {
        await service.close();

        expect(true, isTrue);
      });

      test('can be called multiple times', () async {
        await service.close();
        await service.close();

        expect(true, isTrue);
      });
    });

    group('multiple operations', () {
      test('can save and retrieve large number of chunks', () async {
        const recordingId = 'large-recording';
        const chunkCount = 100;

        // Save chunks
        for (var i = 0; i < chunkCount; i++) {
          await service.saveChunk(
            recordingId: recordingId,
            chunkIndex: i,
            chunkData: Uint8List.fromList([i % 256]),
          );
        }

        // Retrieve and verify
        final chunks = await service.getChunks(recordingId);
        expect(chunks, hasLength(chunkCount));

        for (var i = 0; i < chunkCount; i++) {
          expect(chunks[i], equals(Uint8List.fromList([i % 256])));
        }
      });

      test('handles concurrent saves', () async {
        const recordingId = 'concurrent-recording';
        final futures = <Future>[];

        // Save chunks concurrently
        for (var i = 0; i < 10; i++) {
          futures.add(
            service.saveChunk(
              recordingId: recordingId,
              chunkIndex: i,
              chunkData: Uint8List.fromList([i]),
            ),
          );
        }

        await Future.wait(futures);

        final chunks = await service.getChunks(recordingId);
        expect(chunks, hasLength(10));
      });
    });
  });
}
