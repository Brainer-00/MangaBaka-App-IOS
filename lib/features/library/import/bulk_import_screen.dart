import 'package:flutter/material.dart';
import 'package:mangabaka_app/core/constants/app_constants.dart';
import 'package:mangabaka_app/core/di/service_locator.dart';
import 'package:mangabaka_app/core/localization/localization_service.dart';
import 'package:mangabaka_app/core/settings/settings_manager.dart';
import 'package:mangabaka_app/core/theme/app_typography.dart';
import 'package:mangabaka_app/core/utils/widget_utils.dart';
import 'package:mangabaka_app/core/widgets/design/mb_screen_header.dart';
import 'package:mangabaka_app/features/library/import/bulk_import_controller.dart';
import 'package:mangabaka_app/features/library/services/library_service.dart';
import 'package:mangabaka_app/features/profile/services/profile_auth_service.dart';
import 'package:mangabaka_app/shared/transitions/app_transitions.dart';
import 'package:mangabaka_app/core/widgets/app_snack_bar.dart';

/// Add many series to the library from a pasted list of titles.
///
/// Paste, match, prune, add: each line is matched against the catalogue
/// (strictly - see [SeriesMatchService]), the user reviews what matched, and
/// the chosen series go in with a single batch request.
class BulkImportScreen extends StatefulWidget {
  const BulkImportScreen({super.key});

  static void open(BuildContext context) => Navigator.of(
    context,
  ).push(AppTransitions.slideRight(const BulkImportScreen()));

  @override
  State<BulkImportScreen> createState() => _BulkImportScreenState();
}

class _BulkImportScreenState extends State<BulkImportScreen> {
  late final SeriesMatchService _matcher = SeriesMatchService();
  late final LibraryService _library = getIt<LibraryService>();
  late final BulkImportController _controller;
  final TextEditingController _text = TextEditingController();

  static const List<String> _states = [
    'plan_to_read',
    'reading',
    'completed',
    'paused',
    'dropped',
    'rereading',
    'considering',
  ];

  @override
  void initState() {
    super.initState();
    _controller = BulkImportController(
      match: _matcher.match,
      isInLibrary: (id) async =>
          await _library.database.libraryEntriesDao.getEntryBySeriesId(id) !=
          null,
      addBatch: _library.createLibraryEntriesBatch,
      state: SettingsManager().addLibraryDefaultTab,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _matcher.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final l10n = LocalizationService();
    try {
      final count = await _controller.addSelected();
      if (!mounted) return;
      AppSnackBar.show(
        context,
        l10n.translate('import_added').replaceAll('{count}', '$count'),
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        l10n.translate('failed_to_add'),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = LocalizationService();
    return Scaffold(
      backgroundColor: AppConstants.primaryBackground,
      appBar: mbScreenAppBar(title: l10n.translate('import_list')),
      body: WidgetUtils.responsiveConstraint(
        maxWidth: 760,
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => !getIt<ProfileAuthService>().isLoggedIn
              ? _message(l10n.translate('import_login_required'))
              : (_controller.hasRows ? _results(l10n) : _input(l10n)),
        ),
      ),
    );
  }

  Widget _message(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: AppTypography.sans(color: AppConstants.textMutedColor),
      ),
    ),
  );

  // ─── Paste ─────────────────────────────────────────────────────────────────

  Widget _input(LocalizationService l10n) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          l10n.translate('import_list_subtitle'),
          style: AppTypography.sans(
            color: AppConstants.textMutedColor,
            fontSize: 14,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _text,
          minLines: 10,
          maxLines: 16,
          style: AppTypography.sans(color: AppConstants.textColor),
          decoration: InputDecoration(
            hintText: l10n.translate('import_paste_hint'),
            contentPadding: const EdgeInsets.all(18),
          ),
        ),
        const SizedBox(height: 16),
        _stateRow(l10n),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: () => _controller.start(_text.text),
          child: Text(l10n.translate('import_match').toUpperCase()),
        ),
      ],
    );
  }

  Widget _stateRow(LocalizationService l10n) {
    return Row(
      children: [
        Expanded(
          child: Text(
            l10n.translate('import_add_as').toUpperCase(),
            style: AppTypography.monoLabel(
              color: AppConstants.textMutedColor,
              fontSize: 11.5,
            ),
          ),
        ),
        DropdownButton<String>(
          value: _controller.state,
          dropdownColor: AppConstants.secondaryBackground,
          underline: const SizedBox.shrink(),
          style: AppTypography.sans(color: AppConstants.textColor),
          items: [
            for (final s in _states)
              DropdownMenuItem(value: s, child: Text(l10n.translate(s))),
          ],
          onChanged: (v) {
            if (v != null) _controller.setTargetState(v);
          },
        ),
      ],
    );
  }

  // ─── Review ────────────────────────────────────────────────────────────────

  Widget _results(LocalizationService l10n) {
    final c = _controller;
    return Column(
      children: [
        if (c.isMatching)
          LinearProgressIndicator(
            value: c.progress,
            color: AppConstants.accentColor,
            backgroundColor: AppConstants.tertiaryBackground,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n
                      .translate('import_summary')
                      .replaceAll('{selected}', '${c.selectedCount}')
                      .replaceAll('{total}', '${c.rows.length}'),
                  style: AppTypography.monoLabel(
                    color: AppConstants.textMutedColor,
                    fontSize: 11.5,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => c.selectAll(c.selectedCount == 0),
                child: Text(
                  l10n
                      .translate(c.selectedCount == 0 ? 'select_all' : 'clear')
                      .toUpperCase(),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            itemCount: c.rows.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _RowTile(
              row: c.rows[i],
              l10n: l10n,
              onToggle: () => c.toggle(c.rows[i]),
              onChange: (index) => c.choose(c.rows[i], index),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: c.selectedCount == 0 || c.isAdding || c.isMatching
                    ? null
                    : _add,
                child: c.isAdding
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        l10n
                            .translate('import_add_n')
                            .replaceAll('{count}', '${c.selectedCount}')
                            .toUpperCase(),
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RowTile extends StatelessWidget {
  final ImportRow row;
  final LocalizationService l10n;
  final VoidCallback onToggle;
  final ValueChanged<int> onChange;

  const _RowTile({
    required this.row,
    required this.l10n,
    required this.onToggle,
    required this.onChange,
  });

  String get _status => switch (row.status) {
    ImportRowStatus.pending => l10n.translate('import_matching'),
    ImportRowStatus.matched => '',
    ImportRowStatus.notFound => l10n.translate('import_no_match'),
    ImportRowStatus.inLibrary => l10n.translate('import_in_library'),
    ImportRowStatus.failed => l10n.translate('import_check_failed'),
  };

  @override
  Widget build(BuildContext context) {
    final match = row.match;
    final muted = !row.canSelect;
    final title = match?.getDisplayTitle(
      SettingsManager().defaultTitleLanguage,
    );

    return Material(
      color: AppConstants.secondaryBackground,
      borderRadius: BorderRadius.circular(AppConstants.cardRadius),
      child: InkWell(
        onTap: row.canSelect ? onToggle : null,
        borderRadius: BorderRadius.circular(AppConstants.cardRadius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: 58,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: match != null && match.coverUrl.isNotEmpty
                      ? WidgetUtils.networkImage(
                          url: match.coverUrl,
                          fit: BoxFit.cover,
                          memCacheWidth: 120,
                        )
                      : Container(color: AppConstants.tertiaryBackground),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title ?? row.query,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.sans(
                        color: muted
                            ? AppConstants.textMutedColor
                            : AppConstants.textColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 14.5,
                      ),
                    ),
                    if (match != null && title != row.query)
                      Text(
                        row.query,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.sans(
                          color: AppConstants.textMutedColor,
                          fontSize: 12,
                        ),
                      ),
                    if (_status.isNotEmpty)
                      Text(
                        _status.toUpperCase(),
                        style: AppTypography.monoLabel(
                          color: row.status == ImportRowStatus.inLibrary
                              ? AppConstants.accentColor
                              : AppConstants.textMutedColor,
                          fontSize: 10.5,
                        ),
                      ),
                  ],
                ),
              ),
              if (row.candidates.length > 1)
                PopupMenuButton<int>(
                  tooltip: l10n.translate('import_change_match'),
                  icon: Icon(
                    Icons.swap_horiz_rounded,
                    color: AppConstants.textMutedColor,
                  ),
                  onSelected: onChange,
                  itemBuilder: (_) => [
                    for (var i = 0; i < row.candidates.length; i++)
                      PopupMenuItem(
                        value: i,
                        child: Text(
                          row.candidates[i].getDisplayTitle(
                            SettingsManager().defaultTitleLanguage,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              if (row.canSelect)
                Checkbox(value: row.selected, onChanged: (_) => onToggle())
              else
                const SizedBox(width: 48),
            ],
          ),
        ),
      ),
    );
  }
}
