import 'package:flutter/material.dart';
import 'package:mangabaka_app/core/constants/app_constants.dart';
import 'package:mangabaka_app/core/database/database.dart';
import 'package:mangabaka_app/core/di/service_locator.dart';
import 'package:mangabaka_app/core/localization/localization_service.dart';
import 'package:mangabaka_app/core/logging/logging_service.dart';
import 'package:mangabaka_app/core/settings/settings_manager.dart';
import 'package:mangabaka_app/core/theme/app_typography.dart';
import 'package:mangabaka_app/core/utils/number_utils.dart';
import 'package:mangabaka_app/core/utils/widget_utils.dart';
import 'package:mangabaka_app/core/widgets/app_snack_bar.dart';
import 'package:mangabaka_app/desktop/desktop_layout.dart';
import 'package:mangabaka_app/desktop/shell/desktop_shell.dart';
import 'package:mangabaka_app/desktop/widgets/desktop_carousel.dart';
import 'package:mangabaka_app/desktop/widgets/desktop_cover_card.dart';
import 'package:mangabaka_app/desktop/widgets/desktop_sign_in_prompt.dart';
import 'package:mangabaka_app/desktop/widgets/desktop_surfaces.dart';
import 'package:mangabaka_app/features/library/models/library_entry.dart';
import 'package:mangabaka_app/features/library/services/library_service.dart';
import 'package:mangabaka_app/features/library/services/mappers/db_to_api_mapper.dart';
import 'package:mangabaka_app/features/profile/mixins/profile_data_mixin.dart';
import 'package:mangabaka_app/features/profile/services/profile_auth_service.dart';
import 'package:mangabaka_app/features/profile/services/snapshot_service.dart';
import 'package:mangabaka_app/features/profile/services/statistics_service.dart';
import 'package:mangabaka_app/features/profile/widgets/dialogs/logout_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

/// The profile on desktop: an identity card beside a statistics dashboard.
///
/// The phone splits this over two screens — a four-number summary with a
/// "full statistics" push — because it has no room. Here every statistic, the
/// standout picks and both recent-activity rows fit on one page.
class DesktopProfileScreen extends StatefulWidget {
  static final GlobalKey<DesktopProfileScreenState> stateKey =
      GlobalKey<DesktopProfileScreenState>();

  const DesktopProfileScreen({super.key});

  @override
  State<DesktopProfileScreen> createState() => DesktopProfileScreenState();
}

class DesktopProfileScreenState extends State<DesktopProfileScreen>
    with ProfileDataMixin
    implements DesktopRefreshable {
  static final _logger = LoggingService.logger;

  late final ProfileAuthService _auth;
  late final LibraryService _library;
  late final StatisticsService _stats;
  late final SnapshotService _snapshots;

  bool _wasSyncing = false;

  // The statistics the phone keeps on its separate statistics screen.
  double _completionRate = 0;
  int _totalRereads = 0;
  double _finishRate = 0;
  LibraryEntryWithSeries? _highestRated;
  LibraryEntryWithSeries? _mostReread;

  @override
  ProfileAuthService get auth => _auth;
  @override
  LibraryService get libraryService => _library;
  @override
  StatisticsService get statisticsService => _stats;
  @override
  SnapshotService get snapshotService => _snapshots;

  @override
  void initState() {
    super.initState();
    _auth = getIt<ProfileAuthService>();
    _library = getIt<LibraryService>();
    _stats = StatisticsService(getIt<AppDatabase>());
    _snapshots = getIt<SnapshotService>();
    _auth.addListener(_onAuthChanged);
    _library.syncStatus.addListener(_onSyncChanged);

    profile = _auth.cachedProfile;
    if (profile != null) {
      loading = false;
      _loadAll();
      _auth
          .fetchProfile(forceRefresh: true)
          .then((p) {
            if (mounted) setState(() => profile = p);
          })
          .catchError((Object e) {
            _logger.warning('Background profile refresh failed: $e');
          });
    } else if (_auth.isLoggedIn) {
      bootstrap().then((_) => _fetchExtendedStats());
    } else {
      loading = false;
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _library.syncStatus.removeListener(_onSyncChanged);
    super.dispose();
  }

  void _loadAll() {
    fetchStatistics();
    _fetchExtendedStats();
    _reloadSnapshots();
  }

  void _reloadSnapshots() {
    pageChanged = 1;
    pageAdded = 1;
    hasMoreChanged = true;
    hasMoreAdded = true;
    fetchRecentlyChanged(initial: true);
    fetchRecentlyAdded(initial: true);
  }

  @override
  Future<void> refresh() async {
    if (!_auth.isLoggedIn) return;
    await bootstrap();
    await _fetchExtendedStats();
  }

  Future<void> _fetchExtendedStats() async {
    final prefs = SettingsManager().contentPreferences;
    final results = await Future.wait<Object?>([
      _stats.getCompletionRate(contentPreferences: prefs),
      _stats.getTotalRereads(contentPreferences: prefs),
      _stats.getFinishRate(contentPreferences: prefs),
      _stats.getHighestRatedSeries(contentPreferences: prefs),
      _stats.getMostRereadSeries(contentPreferences: prefs),
    ]);
    if (!mounted) return;
    setState(() {
      _completionRate = results[0] as double;
      _totalRereads = results[1] as int;
      _finishRate = results[2] as double;
      _highestRated = results[3] as LibraryEntryWithSeries?;
      _mostReread = results[4] as LibraryEntryWithSeries?;
    });
  }

  void _onSyncChanged() {
    if (!mounted) return;
    final syncing = _library.syncStatus.value.isSyncing;
    if (_wasSyncing && !syncing && _auth.isLoggedIn) _loadAll();
    _wasSyncing = syncing;
  }

  void _onAuthChanged() {
    if (!mounted) return;
    setState(() {
      profile = _auth.cachedProfile;
      if (!_auth.isLoggedIn) {
        profile = null;
        totalSeries = 0;
        chaptersRead = 0;
        volumesRead = 0;
        meanScore = 0;
        recentlyChanged.clear();
        recentlyAdded.clear();
        _highestRated = null;
        _mostReread = null;
        loading = false;
        error = null;
      } else if (profile == null) {
        bootstrap().then((_) => _fetchExtendedStats());
      }
    });
  }

  Future<void> _logout() async {
    final confirmed = await LogoutDialog.showLogoutConfirmationDialog(context);
    if (confirmed != true) return;
    try {
      await _auth.logout();
    } catch (e) {
      if (!mounted) return;
      AppSnackBar.show(context, 'Logout failed: $e', isError: true);
    }
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([LocalizationService(), SettingsManager()]),
      builder: (context, _) {
        final l10n = LocalizationService();

        if (loading) return const Center(child: CircularProgressIndicator());
        if (profile == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DesktopPageHeader(title: l10n.translate('profile')),
              Expanded(
                child: error != null
                    ? DesktopEmptyState(
                        icon: Icons.error_outline_rounded,
                        message: error!,
                        action: DesktopPillButton(
                          label: l10n.translate('retry'),
                          onPressed: login,
                        ),
                      )
                    : DesktopSignInPrompt(
                        title: l10n.translate('profile'),
                        message: l10n.translate('login_prompt_profile'),
                        onLogin: login,
                        icon: Icons.person_outline_rounded,
                      ),
              ),
            ],
          );
        }

        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: DesktopTokens.maxPageWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                DesktopTokens.pagePadding,
                32,
                DesktopTokens.pagePadding,
                48,
              ),
              children: [
                _IdentityCard(
                  name: _displayName(l10n),
                  username: profile!.preferredUsername,
                  role: profile!.role,
                  avatarUrl: profile!.avatarUrl,
                  onLogout: _logout,
                ),
                const SizedBox(height: DesktopTokens.sectionGap),
                DesktopSectionTitle(title: l10n.translate('reading_stats')),
                _statsGrid(l10n),
                if (_highestRated != null || _mostReread != null) ...[
                  const SizedBox(height: DesktopTokens.sectionGap),
                  DesktopSectionTitle(title: l10n.translate('standout_picks')),
                  _standouts(l10n),
                ],
                const SizedBox(height: DesktopTokens.sectionGap),
                _activity(
                  l10n.translate('recently_changed'),
                  recentlyChanged,
                  onNearEnd: fetchRecentlyChanged,
                  loading: isLoadingChanged && recentlyChanged.isEmpty,
                ),
                const SizedBox(height: DesktopTokens.sectionGap),
                _activity(
                  l10n.translate('recently_added'),
                  recentlyAdded,
                  onNearEnd: fetchRecentlyAdded,
                  loading: isLoadingAdded && recentlyAdded.isEmpty,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _displayName(LocalizationService l10n) {
    final p = profile!;
    if (p.nickname?.isNotEmpty == true) return p.nickname!;
    if (p.preferredUsername?.isNotEmpty == true) return p.preferredUsername!;
    return l10n.translate('your_profile');
  }

  Widget _statsGrid(LocalizationService l10n) {
    final tiles = [
      _StatTile(
        Icons.book_rounded,
        l10n.translate('total_series'),
        NumberUtils.formatCount(totalSeries),
      ),
      _StatTile(
        Icons.article_rounded,
        l10n.translate('chapters_read'),
        NumberUtils.formatCount(chaptersRead),
      ),
      _StatTile(
        Icons.library_books_rounded,
        l10n.translate('volumes_read'),
        NumberUtils.formatCount(volumesRead),
      ),
      _StatTile(
        Icons.star_rounded,
        l10n.translate('mean_score'),
        meanScore.toStringAsFixed(1),
      ),
      _StatTile(
        Icons.check_circle_rounded,
        l10n.translate('completion'),
        '${_completionRate.toStringAsFixed(1)}%',
      ),
      _StatTile(
        Icons.flag_rounded,
        l10n.translate('finish_rate'),
        '${_finishRate.toStringAsFixed(1)}%',
      ),
      _StatTile(
        Icons.replay_rounded,
        l10n.translate('total_rereads'),
        NumberUtils.formatCount(_totalRereads),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 16.0;
        // All seven in a row when they fit, otherwise four-and-three — never
        // a lone tile orphaned on its own row.
        final columns = constraints.maxWidth >= 7 * 190
            ? 7
            : constraints.maxWidth >= 4 * 190
            ? 4
            : 2;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final t in tiles) SizedBox(width: width, child: t)],
        );
      },
    );
  }

  Widget _standouts(LocalizationService l10n) {
    final cards = <Widget>[
      if (_highestRated != null)
        _StandoutCard(
          entry: _highestRated!,
          label: l10n.translate('highest_rated'),
          icon: Icons.star_rounded,
          value:
              '${l10n.translate('score')}: ${_highestRated!.libraryEntry.rating ?? 0}',
        ),
      if (_mostReread != null)
        _StandoutCard(
          entry: _mostReread!,
          label: l10n.translate('most_reread'),
          icon: Icons.replay_rounded,
          value:
              '${_mostReread!.libraryEntry.numberOfRereads} ${l10n.translate('rereads')}',
        ),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(width: 16),
          Expanded(child: cards[i]),
        ],
        if (cards.length == 1) const Spacer(),
      ],
    );
  }

  Widget _activity(
    String title,
    List<LibraryEntry> entries, {
    required VoidCallback onNearEnd,
    required bool loading,
  }) {
    const width = 140.0;
    if (!loading && entries.isEmpty) return const SizedBox.shrink();
    return DesktopCarousel(
      title: title,
      loading: loading,
      itemCount: entries.length,
      itemWidth: width,
      height: width * 1.5 + 70,
      onNearEnd: onNearEnd,
      itemBuilder: (context, i) => DesktopCoverCard(
        series: entries[i].series,
        width: width,
        heroTag: 'profile_${title}_$i',
        caption: LocalizationService().translate(entries[i].state),
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  final String name;
  final String? username;
  final String role;
  final String? avatarUrl;
  final VoidCallback onLogout;

  const _IdentityCard({
    required this.name,
    required this.username,
    required this.role,
    this.avatarUrl,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = LocalizationService();
    return DesktopCard(
      showBorder: false,
      padding: const EdgeInsets.all(28),
      child: Row(
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: AppConstants.accentColor,
              shape: BoxShape.circle,
            ),
            child: ClipOval(
              child: avatarUrl != null && avatarUrl!.isNotEmpty
                  ? WidgetUtils.networkImage(
                      url: avatarUrl!,
                      fit: BoxFit.cover,
                      width: 88,
                      height: 88,
                      errorWidget: Center(
                        child: Text(
                          name.isEmpty ? '?' : name[0].toUpperCase(),
                          style: AppTypography.display(
                            color: AppConstants.onAccent,
                            fontSize: 40,
                          ),
                        ),
                      ),
                    )
                  : Center(
                      child: Text(
                        name.isEmpty ? '?' : name[0].toUpperCase(),
                        style: AppTypography.display(
                          color: AppConstants.onAccent,
                          fontSize: 40,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 26),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.display(
                    color: AppConstants.textColor,
                    fontSize: 32,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (username != null && username != name) ...[
                      Text(
                        '@$username',
                        style: AppTypography.sans(
                          color: AppConstants.textMutedColor,
                          fontSize: 14.5,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    if (role.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppConstants.tertiaryBackground,
                          borderRadius: BorderRadius.circular(
                            AppConstants.pillRadius,
                          ),
                        ),
                        child: Text(
                          role.toUpperCase(),
                          style: AppTypography.monoLabel(
                            color: AppConstants.textMutedColor,
                            fontSize: 10.5,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          DesktopPillButton(
            label: l10n.translate('account_settings'),
            icon: Icons.open_in_new_rounded,
            onPressed: () => launchUrl(
              Uri.parse('https://mangabaka.org/my/settings/profile'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          const SizedBox(width: 10),
          DesktopIconButton(
            icon: Icons.logout_rounded,
            filled: true,
            color: AppConstants.errorColor,
            tooltip: l10n.translate('logout'),
            onPressed: onLogout,
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatTile(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return DesktopCard(
      showBorder: false,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.display(
                    color: AppConstants.textColor,
                    fontSize: 26,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Icon(icon, size: 18, color: AppConstants.textMutedColor),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.monoLabel(
              color: AppConstants.textMutedColor,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _StandoutCard extends StatelessWidget {
  final LibraryEntryWithSeries entry;
  final String label;
  final IconData icon;
  final String value;

  const _StandoutCard({
    required this.entry,
    required this.label,
    required this.icon,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final series = DbToApiMapper.seriesFromDb(entry.series);
    return DesktopHoverSurface(
      onTap: () => openSeriesDetail(context, series, heroTag: 'standout'),
      idleColor: AppConstants.secondaryBackground,
      hoverColor: AppConstants.tertiaryBackground,
      borderRadius: BorderRadius.circular(DesktopTokens.panelRadius),
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: WidgetUtils.networkImage(
              url: series.coverUrl,
              width: 72,
              height: 108,
              memCacheWidth: 160,
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 16, color: AppConstants.starColor),
                    const SizedBox(width: 6),
                    Text(
                      label.toUpperCase(),
                      style: AppTypography.monoLabel(
                        color: AppConstants.textMutedColor,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  series.getDisplayTitle(
                    SettingsManager().defaultTitleLanguage,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.display(
                    color: AppConstants.textColor,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
                  style: AppTypography.sans(
                    color: AppConstants.accentColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
