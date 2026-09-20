import 'package:flutter_test/flutter_test.dart';
import 'package:mangabaka_app/features/library/import/bulk_import_controller.dart';
import 'package:mangabaka_app/features/series/models/series.dart';

Series _series(String id, String title) =>
    Series.fromJson({'id': id, 'title': title, 'state': 'active'});

void main() {
  group('parseTitles', () {
    test('strips list markers, blanks and repeats', () {
      final titles = BulkImportController.parseTitles(
        '1. Frieren\r\n- One Piece\n\n* Berserk\n2) frieren\n  Monster  \n',
      );
      expect(titles, ['Frieren', 'One Piece', 'Berserk', 'Monster']);
    });

    test('caps the list length', () {
      final text = List.generate(500, (i) => 'Title $i').join('\n');
      expect(
        BulkImportController.parseTitles(text),
        hasLength(BulkImportController.maxTitles),
      );
    });
  });

  group('matching and adding', () {
    late List<List<String>> batches;

    BulkImportController build({
      Map<String, List<Series>> matches = const {},
      Set<String> inLibrary = const {},
      Set<String> failing = const {},
    }) {
      batches = [];
      return BulkImportController(
        match: (title) async {
          if (failing.contains(title)) throw Exception('boom');
          return matches[title] ?? const [];
        },
        isInLibrary: (id) async => inLibrary.contains(id),
        addBatch: (ids, state) async {
          batches.add([...ids, state]);
          return ids.length;
        },
      );
    }

    test('classifies each line and preselects only what can be added',
        () async {
      final c = build(
        matches: {
          'Frieren': [_series('1', 'Frieren')],
          'Berserk': [_series('2', 'Berserk')],
        },
        inLibrary: {'2'},
        failing: {'Broken'},
      );
      await c.start('Frieren\nBerserk\nNope\nBroken');

      final byQuery = {for (final r in c.rows) r.query: r};
      expect(byQuery['Frieren']!.status, ImportRowStatus.matched);
      expect(byQuery['Frieren']!.selected, isTrue);
      expect(byQuery['Berserk']!.status, ImportRowStatus.inLibrary);
      expect(byQuery['Berserk']!.selected, isFalse);
      expect(byQuery['Nope']!.status, ImportRowStatus.notFound);
      expect(byQuery['Broken']!.status, ImportRowStatus.failed);
      expect(c.selectedCount, 1);
      expect(c.isMatching, isFalse);
    });

    test('adds only the selected rows, in the chosen state', () async {
      final c = build(matches: {
        'A': [_series('1', 'A')],
        'B': [_series('2', 'B')],
      });
      await c.start('A\nB');
      c.setTargetState('reading');
      c.toggle(c.rows[1]);

      final created = await c.addSelected();

      expect(created, 1);
      expect(batches, [
        ['1', 'reading'],
      ]);
    });

    test('choosing another candidate re-checks the library', () async {
      final c = build(
        matches: {
          'A': [_series('1', 'A'), _series('9', 'A2')],
        },
        inLibrary: {'9'},
      );
      await c.start('A');

      await c.choose(c.rows.single, 1);

      expect(c.rows.single.match!.id, '9');
      expect(c.rows.single.status, ImportRowStatus.inLibrary);
      expect(c.rows.single.selected, isFalse);
    });
  });
}
