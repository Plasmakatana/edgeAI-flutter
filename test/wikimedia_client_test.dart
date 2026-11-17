import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:testapp/services/wikimedia_client.dart';

http.Response _jsonResponse(Object body, {int status = 200}) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic> _pagesResponse(List<Map<String, dynamic>> pages) => {
  'query': {'pages': pages},
};

void main() {
  group('WikimediaClient', () {
    test('fetches extracts, skips empty/missing pages, builds URLs', () async {
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);
        final title = request.url.queryParameters['titles'] ?? '';
        return _jsonResponse(
          _pagesResponse(switch (title) {
            'Alpha' => [
              {'title': 'Alpha', 'extract': 'Alpha text'},
            ],
            'Beta' => [
              {'title': 'Beta', 'extract': '   '},
            ],
            _ => [
              {'title': 'Gamma', 'missing': true},
            ],
          }),
        );
      });
      final wikimedia = WikimediaClient(
        client: client,
        requestDelay: Duration.zero,
      );

      final pages = await wikimedia.fetchExtracts(
        project: 'en.wikipedia.org',
        titles: const ['Alpha', 'Beta', 'Gamma'],
      );

      expect(pages, hasLength(1));
      expect(pages.single.title, 'Alpha');
      expect(pages.single.extract, 'Alpha text');
      expect(pages.single.url, 'https://en.wikipedia.org/wiki/Alpha');
      expect(requested.map((u) => u.queryParameters['titles']), [
        'Alpha',
        'Beta',
        'Gamma',
      ]);
      expect(requested.first.queryParameters['explaintext'], '1');
    });

    test('deduplicates titles case-insensitively', () async {
      var batchTitles = '';
      final client = MockClient((request) async {
        batchTitles = request.url.queryParameters['titles'] ?? '';
        return _jsonResponse(
          _pagesResponse([
            {'title': 'Alpha', 'extract': 'text'},
          ]),
        );
      });
      final wikimedia = WikimediaClient(
        client: client,
        requestDelay: Duration.zero,
      );

      await wikimedia.fetchExtracts(
        project: 'en.wikipedia.org',
        titles: const ['Alpha', ' alpha ', 'ALPHA', ''],
      );

      expect(batchTitles, 'Alpha');
    });

    test('retries 5xx and succeeds', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) return http.Response('oops', 503);
        return _jsonResponse(
          _pagesResponse([
            {'title': 'Alpha', 'extract': 'text'},
          ]),
        );
      });
      final wikimedia = WikimediaClient(
        client: client,
        requestDelay: Duration.zero,
      );

      final pages = await wikimedia.fetchExtracts(
        project: 'en.wikipedia.org',
        titles: const ['Alpha'],
      );

      expect(calls, 2);
      expect(pages, hasLength(1));
    });

    test('does not retry non-transient 4xx', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('forbidden', 403);
      });
      final wikimedia = WikimediaClient(
        client: client,
        requestDelay: Duration.zero,
      );

      await expectLater(
        wikimedia.fetchExtracts(
          project: 'en.wikipedia.org',
          titles: const ['Alpha'],
        ),
        throwsA(isA<Exception>()),
      );
      expect(calls, 1);
    });

    test('falls back to per-title requests when a batch is empty', () async {
      final requested = <String>[];
      final client = MockClient((request) async {
        final titles = request.url.queryParameters['titles'] ?? '';
        requested.add(titles);
        if (titles.contains('|')) return _jsonResponse(_pagesResponse([]));
        return _jsonResponse(
          _pagesResponse([
            {'title': titles, 'extract': 'text for $titles'},
          ]),
        );
      });
      final wikimedia = WikimediaClient(
        client: client,
        batchSize: 2,
        requestDelay: Duration.zero,
      );

      final pages = await wikimedia.fetchExtracts(
        project: 'en.wikipedia.org',
        titles: const ['Alpha', 'Beta'],
      );

      expect(pages.map((p) => p.title), ['Alpha', 'Beta']);
      expect(requested, ['Alpha|Beta', 'Alpha', 'Beta']);
    });

    test(
      'fetches missing titles individually when a batch is incomplete',
      () async {
        final requested = <String>[];
        final client = MockClient((request) async {
          final titles = request.url.queryParameters['titles'] ?? '';
          requested.add(titles);
          if (titles.contains('|')) {
            return _jsonResponse(
              _pagesResponse([
                {'title': 'Alpha', 'extract': 'Alpha text'},
              ]),
            );
          }
          return _jsonResponse(
            _pagesResponse([
              {'title': titles, 'extract': 'text for $titles'},
            ]),
          );
        });
        final wikimedia = WikimediaClient(
          client: client,
          batchSize: 2,
          requestDelay: Duration.zero,
        );

        final pages = await wikimedia.fetchExtracts(
          project: 'en.wikipedia.org',
          titles: const ['Alpha', 'Beta'],
        );

        expect(pages.map((p) => p.title), ['Alpha', 'Beta']);
        expect(requested, ['Alpha|Beta', 'Beta']);
      },
    );

    test('truncates very long extracts at a paragraph boundary', () async {
      final paragraph = 'Sentence ${'x' * 30}.';
      final long = List.generate(20, (_) => paragraph).join('\n\n');
      final client = MockClient((request) async {
        return _jsonResponse(
          _pagesResponse([
            {'title': 'Long', 'extract': long},
          ]),
        );
      });
      final wikimedia = WikimediaClient(
        client: client,
        requestDelay: Duration.zero,
        maxCharsPerPage: 300,
      );

      final pages = await wikimedia.fetchExtracts(
        project: 'en.wikipedia.org',
        titles: const ['Long'],
      );

      final text = pages.single.extract;
      expect(text.length, lessThan(long.length));
      expect(text, endsWith('[Article truncated for offline use.]'));
      expect(text.contains('\n\n[Article truncated'), isTrue);
    });
  });
}
