import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:record_web/services/database_manager.dart';

void main() {
  group('DatabaseManager', () {
    setUp(() => DatabaseManager.instance.setFactory(newIdbFactoryMemory()));

    tearDown(() => DatabaseManager.instance.close());

    test('shares one connection between concurrent first calls', () async {
      final databases = await Future.wait([
        DatabaseManager.instance.getDatabase(),
        DatabaseManager.instance.getDatabase(),
      ]);

      expect(identical(databases[0], databases[1]), isTrue);
    });

    test('opens a new connection after close', () async {
      final first = await DatabaseManager.instance.getDatabase();
      await DatabaseManager.instance.close();

      final second = await DatabaseManager.instance.getDatabase();

      expect(identical(first, second), isFalse);
    });
  });
}
