import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mangabaka_app/core/constants/app_constants.dart';
import 'package:mangabaka_app/core/di/service_locator.dart';
import 'package:mangabaka_app/core/localization/localization_service.dart';
import 'package:mangabaka_app/core/logging/logging_service.dart';
import 'package:mangabaka_app/core/theme/app_typography.dart';
import 'package:mangabaka_app/core/utils/widget_utils.dart';
import 'package:mangabaka_app/core/widgets/design/mb_pill.dart';
import 'package:mangabaka_app/core/widgets/design/mb_screen_header.dart';
import 'package:mangabaka_app/desktop/desktop_layout.dart';
import 'package:mangabaka_app/desktop/widgets/desktop_surfaces.dart';
import 'package:mangabaka_app/features/browse/screens/browse_results_screen.dart';
import 'package:mangabaka_app/features/collections/models/edition.dart';
import 'package:mangabaka_app/features/collections/screens/collection_detail_screen.dart';
import 'package:mangabaka_app/features/collections/services/collection_service.dart';
import 'package:mangabaka_app/features/collections/widgets/collection_card.dart';
import 'package:mangabaka_app/features/publisher/models/publisher.dart';
import 'package:mangabaka_app/features/publisher/services/publisher_search_service.dart';
import 'package:mangabaka_app/features/series/models/series_collection.dart';
import 'package:mangabaka_app/shared/transitions/app_transitions.dart';

/// Browse collections and editions.
///
/// Collections belong to a publisher, so the Collections tab starts from one:
/// search for a publisher, then see its collections and narrow them by edition.
/// The Editions tab lists every edition with what it means; choosing one
/// narrows the open publisher's collections to it.
class CollectionsBrowseScreen extends StatefulWidget {
  final Publisher? initialPublisher;

  const CollectionsBrowseScreen({super.key, this.initialPublisher});

  /// Opens the browser over the current screen.
  static void open(BuildContext context, {Publisher? publisher}) => Navigator.of(
    context,
  ).push(AppTransitions.slideRight(CollectionsBrowseScreen(initialPublisher: publisher)));

  @override
  State<CollectionsBrowseScreen> createState() =>
      _CollectionsBrowseScreenState();
}

class _CollectionsBrowseScreenState extends State<CollectionsBrowseScreen>
    with SingleTickerProviderStateMixin {
  static final _logger = LoggingService.logger;

  late final TabController _tabs = TabController(length: 2, vsync: this);
  late final CollectionService _collections = getIt<CollectionService>();
  late final PublisherSearchService _publishers =
      getIt<PublisherSearchService>();

  final TextEditingController _query = TextEditingController();
  Timer? _debounce;

  // Publisher search.
  List<Publisher> _matches = const [];
  bool _searching = false;

  // The open publisher's collections.
  Publisher? _publisher;
  final List<SeriesCollection> _list = [];
  int _page = 1;
  bool _hasNext = false;
  bool _loadingList = false;
  bool _listFailed = false;
  String? _editionFilter;

  // Editions.
  List<Edition>? _editions;
  bool _editionsFailed = false;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTabChange);
    _loadEditions();
    if (widget.initialPublisher != null) {
      _publisher = widget.initialPublisher;
      _loadCollections();
    }
  }

  void _onTabChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChange);
    _debounce?.cancel();
    _query.dispose();
    _tabs.dispose();
    super.dispose();
  }

  // ─── Loading ───────────────────────────────────────────────────────────────

  Future<void> _loadEditions() async {
    setState(() => _editionsFailed = false);
    try {
      final editions = await _collections.fetchEditions();
      if (mounted) setState(() => _editions = editions);
    } catch (e) {
      _logger.warning('Editions failed: $e');
      if (mounted) setState(() => _editionsFailed = true);
    }
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() => _matches = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(value));
  }

  Future<void> _search(String value) async {
    setState(() => _searching = true);
    try {
      final found = await _publishers.searchPublishers(
        query: value.trim(),
        limit: 20,
      );
      if (mounted && value == _query.text) {
        setState(() => _matches = found);
      }
    } catch (e) {
      _logger.warning('Publisher search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _choosePublisher(Publisher publisher) {
    FocusScope.of(context).unfocus();
    setState(() {
      _publisher = publisher;
      _list.clear();
      _page = 1;
      _hasNext = false;
      _editionFilter = null;
    });
    _loadCollections();
  }

  void _clearPublisher() {
    setState(() {
      _publisher = null;
      _list.clear();
      _editionFilter = null;
    });
  }

  Future<void> _loadCollections() async {
    final publisher = _publisher;
    if (publisher == null || _loadingList) return;
    setState(() {
      _loadingList = true;
      _listFailed = false;
    });
    try {
      final page = await _collections.fetchPublisherCollections(
        publisher.id,
        page: _page,
      );
      if (!mounted || _publisher != publisher) return;
      setState(() {
        _list.addAll(page.items);
        _hasNext = page.hasNext;
        _page++;
      });
    } catch (e) {
      _logger.warning('Publisher collections failed: $e');
      if (mounted) setState(() => _listFailed = true);
    } finally {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  void _pickEdition(Edition edition) {
    if (_publisher == null) return;
    setState(() => _editionFilter = edition.name);
    _tabs.animateTo(0);
  }

  void _openCollection(SeriesCollection collection) {
    Navigator.of(context).push(
      AppTransitions.slideRight(CollectionDetailScreen(collection: collection)),
    );
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = LocalizationService();
    if (DesktopLayout.isActive(context)) {
      return _buildDesktop(l10n);
    }
    return _buildMobile(l10n);
  }

  Widget _buildDesktop(LocalizationService l10n) {
    return Scaffold(
      backgroundColor: AppConstants.primaryBackground,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DesktopPageHeader(
            leading: DesktopIconButton(
              icon: Icons.arrow_back_rounded,
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: l10n.translate('collections_and_editions'),
            subtitle: _publisher?.name,
            actions: [
              DesktopSegmented<int>(
                value: _tabs.index,
                segments: [
                  (0, l10n.translate('tab_collections'), Icons.collections_bookmark_rounded),
                  (1, l10n.translate('editions'), Icons.auto_stories_rounded),
                ],
                onChanged: (index) {
                  _tabs.animateTo(index);
                  setState(() {});
                },
              ),
            ],
          ),
          Expanded(
            child: WidgetUtils.responsiveConstraint(
              maxWidth: 960,
              TabBarView(
                controller: _tabs,
                children: [_collectionsTab(l10n), _editionsTab(l10n)],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobile(LocalizationService l10n) {
    return Scaffold(
      backgroundColor: AppConstants.primaryBackground,
      appBar: mbScreenAppBar(
        title: l10n.translate('collections_and_editions'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Container(
              decoration: BoxDecoration(
                color: AppConstants.tertiaryBackground,
                borderRadius: BorderRadius.circular(AppConstants.pillRadius),
              ),
              child: TabBar(
                controller: _tabs,
                dividerColor: Colors.transparent,
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                  color: AppConstants.accentColor,
                  borderRadius: BorderRadius.circular(AppConstants.pillRadius),
                ),
                indicatorPadding: EdgeInsets.zero,
                labelColor: AppConstants.onAccent,
                unselectedLabelColor: AppConstants.textMutedColor,
                labelStyle: AppTypography.display(fontSize: 12),
                unselectedLabelStyle: AppTypography.display(fontSize: 12),
                overlayColor: WidgetStateProperty.all(Colors.transparent),
                splashFactory: NoSplash.splashFactory,
                tabs: [
                  Tab(
                    height: 36,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.collections_bookmark_rounded, size: 16),
                        const SizedBox(width: 8),
                        Text(l10n.translate('tab_collections').toUpperCase()),
                      ],
                    ),
                  ),
                  Tab(
                    height: 36,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.auto_stories_rounded, size: 16),
                        const SizedBox(width: 8),
                        Text(l10n.translate('editions').toUpperCase()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: WidgetUtils.responsiveConstraint(
        maxWidth: 900,
        TabBarView(
          controller: _tabs,
          children: [_collectionsTab(l10n), _editionsTab(l10n)],
        ),
      ),
    );
  }

  Widget _collectionsTab(LocalizationService l10n) {
    return _publisher == null ? _publisherPicker(l10n) : _publisherList(l10n);
  }

  Widget _publisherPicker(LocalizationService l10n) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        TextField(
          controller: _query,
          onChanged: _onQueryChanged,
          textInputAction: TextInputAction.search,
          style: AppTypography.sans(color: AppConstants.textColor),
          decoration: InputDecoration(
            hintText: l10n.translate('search_publishers_hint'),
            suffixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
        ),
        const SizedBox(height: 16),
        if (_matches.isEmpty && _query.text.trim().isEmpty)
          _hint(l10n.translate('collections_pick_publisher'))
        else if (_matches.isEmpty && !_searching)
          _hint(l10n.translate('no_results'))
        else
          for (final p in _matches)
            _PublisherRow(publisher: p, onTap: () => _choosePublisher(p)),
      ],
    );
  }

  Widget _publisherList(LocalizationService l10n) {
    final publisher = _publisher!;
    final filter = _editionFilter;
    final shown = filter == null
        ? _list
        : _list.where((c) => c.editionName == filter).toList();
    final editionNames = {
      for (final c in _list)
        if (c.editionName.isNotEmpty) c.editionName,
    }.toList()..sort();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: AppConstants.secondaryBackground,
            borderRadius: BorderRadius.circular(AppConstants.cardRadius),
            border: Border.all(color: AppConstants.borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppConstants.tertiaryBackground,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.business_rounded,
                      color: AppConstants.accentColor,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          publisher.name,
                          style: AppTypography.display(
                            color: AppConstants.textColor,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (publisher.subType.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppConstants.accentColor
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  publisher.subType.toUpperCase(),
                                  style: AppTypography.monoLabel(
                                    color: AppConstants.accentColor,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            if (publisher.founded != null)
                              Text(
                                'Est. ${publisher.founded}',
                                style: AppTypography.sans(
                                  color: AppConstants.textMutedColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            if (publisher.closed != null)
                              Text(
                                'Closed ${publisher.closed}',
                                style: AppTypography.sans(
                                  color: AppConstants.errorColor
                                      .withValues(alpha: 0.8),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            if (publisher.imprints.isNotEmpty)
                              Text(
                                '${publisher.imprints.length} Imprints',
                                style: AppTypography.sans(
                                  color: AppConstants.textMutedColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (widget.initialPublisher == null)
                    TextButton(
                      onPressed: _clearPublisher,
                      child: Text(l10n.translate('change').toUpperCase()),
                    ),
                ],
              ),
              if (publisher.description != null &&
                  publisher.description!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  publisher.description!,
                  style: AppTypography.sans(
                    color: AppConstants.textMutedColor,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.menu_book_rounded, size: 16),
                label: Text(l10n.translate('series')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppConstants.textColor,
                  side: BorderSide(color: AppConstants.borderColor),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: () {
                  Navigator.of(context).push(
                    AppTransitions.slideRight(
                      BrowseResultsScreen(
                        sortType: publisher.name,
                        sortBy: 'name_asc',
                        publisher: publisher.name,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        if (editionNames.length > 1) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MbPill(
                label: l10n.translate('all_editions'),
                selected: filter == null,
                onTap: () => setState(() => _editionFilter = null),
              ),
              for (final name in editionNames)
                MbPill(
                  label: name,
                  selected: filter == name,
                  onTap: () => setState(() => _editionFilter = name),
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        for (final c in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: CollectionCard(
              collection: c,
              showPublisher: false,
              onTap: () => _openCollection(c),
            ),
          ),
        if (_loadingList)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_listFailed)
          Center(
            child: TextButton(
              onPressed: _loadCollections,
              child: Text(l10n.translate('retry')),
            ),
          )
        else if (_hasNext)
          Center(
            child: TextButton(
              onPressed: _loadCollections,
              child: Text(l10n.translate('load_more').toUpperCase()),
            ),
          )
        else if (shown.isEmpty)
          _hint(l10n.translate('no_collections_available')),
      ],
    );
  }

  Widget _editionsTab(LocalizationService l10n) {
    if (_editionsFailed) {
      return Center(
        child: TextButton(
          onPressed: _loadEditions,
          child: Text(l10n.translate('retry')),
        ),
      );
    }
    final editions = _editions;
    if (editions == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        if (_publisher == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              l10n.translate('editions_pick_publisher'),
              style: AppTypography.sans(
                color: AppConstants.textMutedColor,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
          ),
        for (final e in editions)
          _EditionRow(
            edition: e,
            selected: _editionFilter == e.name,
            onTap: _publisher == null ? null : () => _pickEdition(e),
          ),
      ],
    );
  }

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: AppTypography.sans(color: AppConstants.textMutedColor),
      ),
    ),
  );
}

class _PublisherRow extends StatelessWidget {
  final Publisher publisher;
  final VoidCallback onTap;

  const _PublisherRow({required this.publisher, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppConstants.secondaryBackground,
        borderRadius: BorderRadius.circular(AppConstants.cardRadius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppConstants.cardRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    publisher.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.sans(
                      color: AppConstants.textColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppConstants.textMutedColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EditionRow extends StatelessWidget {
  final Edition edition;
  final bool selected;
  final VoidCallback? onTap;

  const _EditionRow({
    required this.edition,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppConstants.secondaryBackground,
        borderRadius: BorderRadius.circular(AppConstants.cardRadius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppConstants.cardRadius),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  edition.name.toUpperCase(),
                  style: AppTypography.display(
                    color: selected
                        ? AppConstants.accentColor
                        : AppConstants.textColor,
                    fontSize: 14,
                  ),
                ),
                if (edition.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    edition.description,
                    style: AppTypography.sans(
                      color: AppConstants.textMutedColor,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
