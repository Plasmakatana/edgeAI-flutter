import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// One downloaded Wikimedia article extract.
class WikimediaPage {
  const WikimediaPage({
    required this.title,
    required this.extract,
    required this.url,
  });

  final String title;
  final String extract;
  final String url;
}

/// Minimal MediaWiki Action API client used to build offline content packs.
///
/// Fetches plain-text extracts (`prop=extracts&explaintext=1`), retries
/// transient failures, and truncates very long articles so one pack cannot
/// explode the on-device library. The extracts extension returns at most one
/// full extract per request, so the default fetch is one article at a time;
/// batching remains available for intro-only requests. Callers are responsible
/// for showing the CC BY-SA attribution stored alongside each document.
class WikimediaClient {
  WikimediaClient({
    http.Client? client,
    this.batchSize = 1,
    this.maxCharsPerPage = 20000,
    this.requestDelay = const Duration(milliseconds: 250),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const String userAgent =
      'GemmaOfflineAssistant/1.0 (Flutter offline assistant; '
      '+https://github.com/Plasmakatana/edgeAI-flutter)';

  final http.Client _client;
  final bool _ownsClient;
  final int batchSize;
  final int maxCharsPerPage;
  final Duration requestDelay;

  /// Fetches extracts for [titles] from [project] (e.g. `en.wikipedia.org`).
  ///
  /// Missing/invalid pages are skipped. [onProgress] reports processed titles.
  Future<List<WikimediaPage>> fetchExtracts({
    required String project,
    required Iterable<String> titles,
    void Function(int done, int total)? onProgress,
  }) async {
    final unique = <String>[];
    final seen = <String>{};
    for (final raw in titles) {
      final title = raw.trim();
      if (title.isEmpty) continue;
      if (seen.add(title.toLowerCase())) unique.add(title);
    }

    final pages = <WikimediaPage>[];
    final pageTitles = <String>{};
    var done = 0;
    for (var start = 0; start < unique.length; start += batchSize) {
      final end = min(start + batchSize, unique.length);
      final batch = unique.sublist(start, end);
      final batchPages = await _fetchBatch(project, batch);
      final returnedTitles = <String>{};
      for (final page in batchPages) {
        final key = page.title.toLowerCase();
        returnedTitles.add(key);
        if (pageTitles.add(key)) pages.add(page);
      }

      // Full extracts are limited to one article per request, so multi-title
      // batches can come back incomplete. Fetch the remaining titles one by
      // one (redirects may return an already-seen title, hence the dedupe).
      if (batch.length > 1 && batchPages.length < batch.length) {
        for (final title in batch) {
          if (returnedTitles.contains(title.toLowerCase())) continue;
          final single = await _fetchBatch(project, [title]);
          for (final page in single) {
            if (pageTitles.add(page.title.toLowerCase())) pages.add(page);
          }
          if (requestDelay > Duration.zero) {
            await Future<void>.delayed(requestDelay);
          }
        }
      }

      done = end;
      onProgress?.call(done, unique.length);
      if (end < unique.length && requestDelay > Duration.zero) {
        await Future<void>.delayed(requestDelay);
      }
    }
    return pages;
  }

  Future<List<WikimediaPage>> _fetchBatch(
    String project,
    List<String> titles,
  ) async {
    final uri = Uri.https(project, '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'formatversion': '2',
      'prop': 'extracts',
      'explaintext': '1',
      'exlimit': 'max',
      'exsectionformat': 'plain',
      'redirects': '1',
      'maxlag': '5',
      'titles': titles.join('|'),
    });

    final body = await _getWithRetry(uri);
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return const [];
    final query = decoded['query'];
    if (query is! Map<String, dynamic>) return const [];
    final rawPages = query['pages'];
    if (rawPages is! List) return const [];

    final out = <WikimediaPage>[];
    for (final raw in rawPages) {
      if (raw is! Map<String, dynamic>) continue;
      if (raw['missing'] == true || raw['invalid'] == true) continue;
      final title = (raw['title'] as String? ?? '').trim();
      final extract = (raw['extract'] as String? ?? '').trim();
      if (title.isEmpty || extract.isEmpty) continue;
      out.add(
        WikimediaPage(
          title: title,
          extract: _truncate(extract),
          url:
              'https://$project/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_'))}',
        ),
      );
    }
    return out;
  }

  Future<String> _getWithRetry(Uri uri) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      http.Response response;
      try {
        response = await _client
            .get(
              uri,
              headers: const {
                'User-Agent': userAgent,
                'Accept': 'application/json',
              },
            )
            .timeout(const Duration(seconds: 30));
      } catch (e) {
        lastError = e;
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 500 * (attempt + 1)),
          );
        }
        continue;
      }
      if (response.statusCode == 200) {
        return utf8.decode(response.bodyBytes);
      }
      if (response.statusCode != 429 && response.statusCode < 500) {
        throw Exception(
          'Wikimedia request failed: HTTP ${response.statusCode}',
        );
      }
      lastError = 'HTTP ${response.statusCode}';
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
    throw Exception('Wikimedia request failed after retries: $lastError');
  }

  String _truncate(String text) {
    if (text.length <= maxCharsPerPage) return text;
    var cut = text.lastIndexOf('\n\n', maxCharsPerPage);
    if (cut < maxCharsPerPage ~/ 2) {
      cut = text.lastIndexOf(' ', maxCharsPerPage);
    }
    if (cut <= 0) cut = maxCharsPerPage;
    return '${text.substring(0, cut).trimRight()}\n\n'
        '[Article truncated for offline use.]';
  }

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}
