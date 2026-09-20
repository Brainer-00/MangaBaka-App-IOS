import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mangabaka_app/core/constants/app_constants.dart';
import 'package:mangabaka_app/core/logging/logging_service.dart';
import 'package:mangabaka_app/core/network/api_client.dart';
import 'package:mangabaka_app/core/network/api_envelope.dart';
import 'package:mangabaka_app/features/series/models/series.dart';

/// Resolves a pasted title to canonical series via `/v2/series/match`.
///
/// Match is deliberately strict: it returns nothing rather than guessing when a
/// title is not close to exact, which is what a bulk import wants - a wrong
/// series silently added to a library is worse than a line left unmatched.
class SeriesMatchService {
  final ApiClient _api;

  SeriesMatchService({http.Client? client, ApiClient? api})
    : _api = api ?? ApiClient(healthContext: 'series-match', client: client);

  /// Candidates for [title], best first. Not filtered by the user's content
  /// preference: they named this title, and dropping it would look like a bug.
  Future<List<Series>> match(String title, {int limit = 5}) {
    return _api.getJson(
      ApiClient.uri('${AppConstants.baseApiUrlV2}/series/match', {
        'q': title,
        'limit': limit,
      }),
      operation: 'match series',
      parse: (json) => parseDataList(
        json,
        Series.fromSimilarJson,
      ).where((s) => s.state.isEmpty || s.state == 'active').toList(),
    );
  }

  void dispose() => _api.close();
}

enum ImportRowStatus {
  /// Waiting for its turn to be matched.
  pending,

  /// A series was found and the row can be added.
  matched,

  /// Nothing matched the title.
  notFound,

  /// The series is already in the user's library, so it is left alone (adding
  /// it again would overwrite its state).
  inLibrary,

  /// The lookup itself failed.
  failed,
}

/// One line of the pasted list and what it resolved to.
class ImportRow {
  final String query;
  ImportRowStatus status = ImportRowStatus.pending;
  List<Series> candidates = const [];
  int chosen = 0;
  bool selected = false;

  ImportRow(this.query);

  Series? get match => candidates.isEmpty ? null : candidates[chosen];

  bool get canSelect => status == ImportRowStatus.matched;
}

/// State behind the bulk-import screen: parse a pasted list, match every line,
/// let the user prune, then add the chosen series in one batch.
class BulkImportController extends ChangeNotifier {
  static final _logger = LoggingService.logger;

  /// Longest list accepted. Each line is a request, so an accidental paste of a
  /// whole document should not become hundreds of them.
  static const int maxTitles = 200;

  /// Matches in flight at once - enough to be quick, few enough to stay under
  /// the API's rate limit.
  static const int _concurrency = 4;

  final Future<List<Series>> Function(String title) _match;
  final Future<bool> Function(String seriesId) _isInLibrary;
  final Future<int> Function(List<String> seriesIds, String state) _addBatch;

  BulkImportController({
    required Future<List<Series>> Function(String title) match,
    required Future<bool> Function(String seriesId) isInLibrary,
    required Future<int> Function(List<String> seriesIds, String state)
    addBatch,
    String state = 'plan_to_read',
  }) : _match = match,
       _isInLibrary = isInLibrary,
       _addBatch = addBatch,
       _state = state;

  List<ImportRow> _rows = [];
  String _state;
  bool _matching = false;
  bool _adding = false;
  int _matchedCount = 0;
  bool _disposed = false;

  List<ImportRow> get rows => _rows;
  String get state => _state;
  bool get isMatching => _matching;
  bool get isAdding => _adding;
  bool get hasRows => _rows.isNotEmpty;

  /// Progress through matching, 0..1.
  double get progress => _rows.isEmpty ? 0 : _matchedCount / _rows.length;

  int get selectedCount => _rows.where((r) => r.selected).length;
  int get notFoundCount =>
      _rows.where((r) => r.status == ImportRowStatus.notFound).length;

  void setTargetState(String state) {
    _state = state;
    _notify();
  }

  /// Splits pasted text into titles: one per line, list markers ("1.", "-",
  /// "*") and surrounding whitespace removed, blanks and repeats dropped.
  static List<String> parseTitles(String text) {
    final marker = RegExp(r'^\s*(?:[-*•]+|\d+[.)])\s+');
    final seen = <String>{};
    final titles = <String>[];
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final title = line.replaceFirst(marker, '').trim();
      if (title.isEmpty) continue;
      if (!seen.add(title.toLowerCase())) continue;
      titles.add(title);
      if (titles.length >= maxTitles) break;
    }
    return titles;
  }

  /// Parses [text] and matches every title.
  Future<void> start(String text) async {
    final titles = parseTitles(text);
    _rows = [for (final t in titles) ImportRow(t)];
    _matchedCount = 0;
    _matching = titles.isNotEmpty;
    _notify();
    if (titles.isEmpty) return;

    final rows = _rows;
    var next = 0;
    Future<void> worker() async {
      while (!_disposed) {
        final i = next++;
        if (i >= rows.length) return;
        await _resolve(rows[i]);
        _matchedCount++;
        _notify();
      }
    }

    await Future.wait([
      for (var i = 0; i < min(_concurrency, rows.length); i++) worker(),
    ]);
    _matching = false;
    _notify();
  }

  Future<void> _resolve(ImportRow row) async {
    try {
      final found = await _match(row.query);
      if (found.isEmpty) {
        row.status = ImportRowStatus.notFound;
        return;
      }
      row.candidates = found;
      if (await _isInLibrary(found.first.id)) {
        row.status = ImportRowStatus.inLibrary;
      } else {
        row.status = ImportRowStatus.matched;
        row.selected = true;
      }
    } catch (e) {
      _logger.warning('Import match failed for "${row.query}": $e');
      row.status = ImportRowStatus.failed;
    }
  }

  void toggle(ImportRow row) {
    if (!row.canSelect) return;
    row.selected = !row.selected;
    _notify();
  }

  void selectAll(bool value) {
    for (final row in _rows) {
      if (row.canSelect) row.selected = value;
    }
    _notify();
  }

  /// Switches [row] to another candidate the match returned. The new pick may
  /// already be in the library, in which case the row cannot be added.
  Future<void> choose(ImportRow row, int index) async {
    if (index < 0 || index >= row.candidates.length) return;
    row.chosen = index;
    final inLibrary = await _isInLibrary(row.candidates[index].id);
    row.status = inLibrary
        ? ImportRowStatus.inLibrary
        : ImportRowStatus.matched;
    row.selected = !inLibrary;
    _notify();
  }

  /// Adds every selected row in one batch. Returns how many were newly
  /// created; throws whatever the batch call throws, leaving the rows intact
  /// so the user can retry.
  Future<int> addSelected() async {
    final ids = [
      for (final row in _rows)
        if (row.selected && row.match != null) row.match!.id,
    ];
    if (ids.isEmpty) return 0;
    _adding = true;
    _notify();
    try {
      return await _addBatch(ids, _state);
    } finally {
      _adding = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
