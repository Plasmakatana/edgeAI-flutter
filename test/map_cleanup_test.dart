import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:testapp/services/map_service.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('map_cleanup_test');
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {
      // Best effort on Windows.
    }
  });

  Future<File> writeTile(String key, String contents) async {
    final file = File(p.join(root.path, 'tiles', '$key.tile'));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
    return file;
  }

  Future<void> writeAccess(
    Map<String, ({int t, List<String> r})> entries,
  ) async {
    final payload = {
      'version': 1,
      'tiles': {
        for (final entry in entries.entries)
          entry.key: {
            't': entry.value.t,
            if (entry.value.r.isNotEmpty) 'r': entry.value.r,
          },
      },
    };
    await File(p.join(root.path, 'tile_access.json'))
        .writeAsString(jsonEncode(payload));
  }

  Future<Map<String, dynamic>> readAccess() async {
    final raw = jsonDecode(
      await File(p.join(root.path, 'tile_access.json')).readAsString(),
    );
    return (raw as Map<String, dynamic>)['tiles'] as Map<String, dynamic>;
  }

  Map<String, Object?> args({
    required int now,
    List<String> pinned = const [],
    int transientTtlMs = 14 * 24 * 60 * 60 * 1000,
    int regionTtlMs = 180 * 24 * 60 * 60 * 1000,
    int maxBytes = 1024 * 1024 * 1024,
    int targetBytes = 800 * 1024 * 1024,
    int graceMs = 60 * 60 * 1000,
  }) => {
    'root': root.path,
    'now': now,
    'pinnedRegionIds': pinned,
    'transientTtlMs': transientTtlMs,
    'regionTtlMs': regionTtlMs,
    'maxBytes': maxBytes,
    'targetBytes': targetBytes,
    'graceMs': graceMs,
  };

  test(
    'expires old transient/region tiles but not pinned or recent ones',
    () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final oldTransient = await writeTile('src/1/0/1', 'aaaa');
      final recent = await writeTile('src/1/0/2', 'bb');
      final oldRegion = await writeTile('src/1/0/3', 'ccc');
      final oldPinned = await writeTile('src/1/0/4', 'dddd');
      final inGrace = await writeTile('src/1/0/5', 'ee');

      await writeAccess({
        'src/1/0/1': (t: now - 7200000, r: <String>[]),
        'src/1/0/2': (t: now - 10, r: <String>[]),
        'src/1/0/3': (t: now - 7200000, r: ['region']),
        'src/1/0/4': (t: now - 7200000, r: ['pinned']),
        'src/1/0/5': (t: now - 1500, r: <String>[]),
      });

      final result = runMapCacheCleanup(
        args(
          now: now,
          pinned: const ['pinned'],
          transientTtlMs: 1000,
          regionTtlMs: 2000,
          graceMs: 60 * 60 * 1000,
        ),
      );

      expect(await oldTransient.exists(), isFalse);
      expect(await oldRegion.exists(), isFalse);
      expect(await recent.exists(), isTrue);
      expect(await oldPinned.exists(), isTrue);
      expect(await inGrace.exists(), isTrue);
      expect(result['deletedTiles'], 2);
      expect(result['remainingTiles'], 3);
      expect(result['totalBytes'], 8);

      final access = await readAccess();
      expect(access.keys, containsAll(['src/1/0/2', 'src/1/0/4', 'src/1/0/5']));
      expect(access.keys, isNot(contains('src/1/0/1')));
    },
  );

  test('evicts oldest unpinned tiles down to the target size', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final files = <File>[];
    for (var i = 0; i < 4; i++) {
      files.add(await writeTile('src/2/0/$i', '0123456789'));
    }
    await writeAccess({
      'src/2/0/0': (t: now - 1000, r: <String>[]),
      'src/2/0/1': (t: now - 3000, r: <String>[]),
      'src/2/0/2': (t: now - 2000, r: <String>[]),
      'src/2/0/3': (t: now - 4000, r: <String>[]),
    });

    final result = runMapCacheCleanup(
      args(now: now, maxBytes: 30, targetBytes: 10, graceMs: 0),
    );

    expect(result['deletedTiles'], 3);
    expect(result['remainingTiles'], 1);
    expect(result['totalBytes'], 10);
    expect(await files[0].exists(), isTrue);
    expect(await files[1].exists(), isFalse);
    expect(await files[2].exists(), isFalse);
    expect(await files[3].exists(), isFalse);
    expect((await readAccess()).keys, ['src/2/0/0']);
  });

  test('pinned tiles are never evicted by the size cap', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final files = <File>[];
    for (var i = 0; i < 4; i++) {
      files.add(await writeTile('src/3/0/$i', '0123456789'));
    }
    await writeAccess({
      for (var i = 0; i < 4; i++)
        'src/3/0/$i': (t: now - 10 * (i + 1), r: ['pin']),
    });

    final result = runMapCacheCleanup(
      args(
        now: now,
        pinned: const ['pin'],
        maxBytes: 15,
        targetBytes: 5,
        graceMs: 0,
      ),
    );

    expect(result['deletedTiles'], 0);
    expect(result['totalBytes'], 40);
    for (final file in files) {
      expect(await file.exists(), isTrue);
    }
  });

  test('drops stale access entries without files', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await writeTile('src/4/0/0', 'aa');
    await writeAccess({
      'src/4/0/0': (t: now, r: <String>[]),
      'src/4/0/9': (t: now, r: <String>[]),
    });

    runMapCacheCleanup(args(now: now));

    final access = await readAccess();
    expect(access.keys, ['src/4/0/0']);
  });

  test('missing tiles directory is a no-op', () {
    final result = runMapCacheCleanup({
      'root': p.join(root.path, 'nope'),
      'now': 0,
      'pinnedRegionIds': const <String>[],
      'transientTtlMs': 0,
      'regionTtlMs': 0,
      'maxBytes': 0,
      'targetBytes': 0,
      'graceMs': 0,
    });
    expect(result['deletedTiles'], 0);
    expect(result['remainingTiles'], 0);
  });
}
