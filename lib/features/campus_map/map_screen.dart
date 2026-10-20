import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../../core/i18n/app_localizations.dart';
import '../../core/result.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../main.dart';
import 'campus_data.dart';
import 'campus_map_geometry.dart';
import 'map_repository.dart';

/// Campus map and place search.
///
/// ## The map is native and offline
///
/// Every facility is drawn by this app from a fixture captured out of
/// OpenStreetMap (`campus_data.dart`): no tile server, no tile-provider
/// agreement, no network — and the attribution OSM's licence requires is on
/// screen. Panning and zooming go through [InteractiveViewer], so the map
/// behaves like a map rather than like a picture.
///
/// The search tab keeps the earlier Nominatim lookup for places the fixture
/// does not contain, with the same rate limit the public service asks for.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

enum _Mode { campus, search }

class _MapScreenState extends State<MapScreen> {
  _Mode _mode = _Mode.campus;

  // Campus map state.
  final _filterController = TextEditingController();
  CampusCategory? _category;

  // Nominatim search state.
  final _searchController = TextEditingController();
  final _focus = FocusNode();
  Result<List<MapPlace>> _results = const Success([]);
  bool _searched = false;
  bool _busy = false;
  DateTime? _lastQuery;

  @override
  void dispose() {
    _filterController.dispose();
    _searchController.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<CampusPlace> get _visiblePlaces {
    final query = _filterController.text.trim().toLowerCase();
    return [
      for (final place in campusPlaces)
        if ((_category == null || place.category == _category) &&
            (query.isEmpty ||
                place.name.toLowerCase().contains(query) ||
                place.nameEn.toLowerCase().contains(query)))
          place,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.mapTitle)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spaceMd,
              AppTheme.spaceSm,
              AppTheme.spaceMd,
              AppTheme.spaceSm,
            ),
            child: SegmentedButton<_Mode>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: _Mode.campus,
                  label: Text(l10n.mapCampusTab),
                ),
                ButtonSegment(
                  value: _Mode.search,
                  label: Text(l10n.mapSearchTab),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (value) =>
                  setState(() => _mode = value.first),
            ),
          ),
          Expanded(
            child:
                _mode == _Mode.campus ? _campusBody(l10n) : _searchBody(l10n),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------- campus

  Widget _campusBody(AppLocalizations l10n) {
    final visible = _visiblePlaces;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.spaceMd),
          child: TextField(
            controller: _filterController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: l10n.mapSearchCampus,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _filterController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _filterController.clear();
                        setState(() {});
                      },
                    ),
            ),
          ),
        ),
        const SizedBox(height: AppTheme.spaceXs),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.spaceMd),
            children: [
              _categoryChip(l10n, null, l10n.mapAll),
              for (final category in CampusCategory.values)
                _categoryChip(
                  l10n,
                  category,
                  _categoryLabel(category, l10n),
                ),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? EmptyState(
                  title: l10n.mapNoFacility,
                  body: l10n.mapSearchCampus,
                  icon: Icons.search_off_outlined,
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final geometry = CampusMapGeometry(constraints.biggest);
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: InteractiveViewer(
                            minScale: 0.9,
                            maxScale: 6,
                            boundaryMargin: const EdgeInsets.all(120),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapUp: (details) {
                                final place = nearestPlace(
                                  visible,
                                  geometry,
                                  details.localPosition,
                                );
                                if (place != null) _showPlace(l10n, place);
                              },
                              child: CustomPaint(
                                key: const ValueKey('campus.map'),
                                size: constraints.biggest,
                                painter: _CampusMapPainter(
                                  places: visible,
                                  geometry: geometry,
                                  background: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.45),
                                  grid: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant
                                      .withValues(alpha: 0.45),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: AppTheme.spaceSm,
                          bottom: AppTheme.spaceSm,
                          child: _pill(
                            l10n.mapPlacesCount
                                .replaceAll('%d', '${visible.length}'),
                          ),
                        ),
                        Positioned(
                          right: AppTheme.spaceSm,
                          bottom: AppTheme.spaceSm,
                          child: GestureDetector(
                            onTap: () => launcher.launchUrl(
                              Uri.parse(
                                  'https://www.openstreetmap.org/copyright'),
                              mode: launcher.LaunchMode.externalApplication,
                            ),
                            child: _pill(l10n.mapAttribution),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _categoryChip(
    AppLocalizations l10n,
    CampusCategory? category,
    String label,
  ) {
    final selected = _category == category;
    return Padding(
      padding: const EdgeInsets.only(right: AppTheme.spaceXs),
      child: FilterChip(
        selected: selected,
        avatar: category == null
            ? null
            : Icon(Icons.circle, size: 10, color: _colorFor(category)),
        label: Text(label),
        onSelected: (_) => setState(() => _category = category),
      ),
    );
  }

  Widget _pill(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall),
    );
  }

  Future<void> _showPlace(AppLocalizations l10n, CampusPlace place) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) {
        final text = Theme.of(sheet).textTheme;
        final scheme = Theme.of(sheet).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spaceMd,
              0,
              AppTheme.spaceMd,
              AppTheme.spaceMd,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(place.name, style: text.titleLarge),
                if (place.nameEn.isNotEmpty)
                  Text(place.nameEn,
                      style: text.bodySmall?.copyWith(color: scheme.outline)),
                const SizedBox(height: AppTheme.spaceSm),
                Row(
                  children: [
                    Icon(Icons.circle,
                        size: 10, color: _colorFor(place.category)),
                    const SizedBox(width: AppTheme.spaceXs),
                    Text(_categoryLabel(place.category, l10n),
                        style: text.labelLarge),
                  ],
                ),
                const SizedBox(height: AppTheme.spaceXs),
                Text(
                  '${l10n.mapCoordinates} · '
                  '${place.latitude.toStringAsFixed(5)}, '
                  '${place.longitude.toStringAsFixed(5)}',
                  style: text.bodySmall?.copyWith(color: scheme.outline),
                ),
                if (place.osmUrl != null) ...[
                  const SizedBox(height: AppTheme.spaceSm),
                  TextButton.icon(
                    onPressed: () => launcher.launchUrl(
                      Uri.parse(place.osmUrl!),
                      mode: launcher.LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(l10n.mapOpenOsm),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------- search

  Future<void> _search() async {
    final l10n = AppLocalizations.of(context);
    final services = AppScope.of(context, dependOn: false);

    final now = DateTime.now();
    final last = _lastQuery;
    if (last != null && now.difference(last).inMilliseconds < 1100) {
      // Nominatim asks for a 1 req/s ceiling; tell the user rather than
      // silently queueing behind an invisible timer.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(l10n.errorFor('rateLimited'))),
        );
      return;
    }
    _lastQuery = now;

    setState(() => _busy = true);
    final result = await services.map.search(_searchController.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _searched = true;
      _results = result;
    });
  }

  Future<void> _openInOsm(MapPlace place) async {
    final url = place.osmUrl;
    if (url == null) return;
    final uri = Uri.parse(url);
    final ok = await launcher.launchUrl(
      uri,
      mode: launcher.LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.errorFor('unsupported'))));
    }
  }

  Widget _searchBody(AppLocalizations l10n) {
    final text = Theme.of(context).textTheme;
    final places =
        _results is Success ? _results.requireValue : const <MapPlace>[];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppTheme.spaceMd),
          child: TextField(
            controller: _searchController,
            focusNode: _focus,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: l10n.mapHint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                tooltip: l10n.search,
                onPressed: _busy ? null : _search,
              ),
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        Expanded(
          child: !_searched
              ? EmptyState(
                  title: l10n.mapTitle,
                  body: l10n.mapHint,
                  icon: Icons.map_outlined,
                )
              : _busy
                  ? const CenterLoader()
                  : _results is Failure
                      ? ErrorState(failure: _results, onRetry: _search)
                      : places.isEmpty
                          ? EmptyState(
                              title: l10n.mapNoResults,
                              body: l10n.mapHint,
                              icon: Icons.search_off_outlined,
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(
                                AppTheme.spaceMd,
                                0,
                                AppTheme.spaceMd,
                                AppTheme.spaceXl,
                              ),
                              itemCount: places.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: AppTheme.spaceSm),
                              itemBuilder: (context, i) {
                                final place = places[i];
                                return Card(
                                  child: ListTile(
                                    leading: const Icon(Icons.place_outlined),
                                    title: Text(
                                      place.name.isEmpty
                                          ? place.details
                                          : place.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      place.details,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: text.bodySmall,
                                    ),
                                    trailing: const Icon(Icons.open_in_new),
                                    onTap: () => _openInOsm(place),
                                  ),
                                );
                              },
                            ),
        ),
      ],
    );
  }

  static String _categoryLabel(
    CampusCategory category,
    AppLocalizations l10n,
  ) =>
      switch (category) {
        CampusCategory.teaching => l10n.mapCatTeaching,
        CampusCategory.library => l10n.mapCatLibrary,
        CampusCategory.food => l10n.mapCatFood,
        CampusCategory.sport => l10n.mapCatSport,
        CampusCategory.dorm => l10n.mapCatDorm,
        CampusCategory.medical => l10n.mapCatMedical,
      };

  static Color _colorFor(CampusCategory category) => switch (category) {
        CampusCategory.teaching => const Color(0xFF1565C0),
        CampusCategory.library => const Color(0xFF6A1B9A),
        CampusCategory.food => const Color(0xFFEF6C00),
        CampusCategory.sport => const Color(0xFF2E7D32),
        CampusCategory.dorm => const Color(0xFF5D4037),
        CampusCategory.medical => const Color(0xFFC62828),
      };
}

/// Dots on a light background. Deliberately label-free: 300 labels on a phone
/// screen is noise, so the dot is the affordance and the tap opens the name.
class _CampusMapPainter extends CustomPainter {
  _CampusMapPainter({
    required this.places,
    required this.geometry,
    required this.background,
    required this.grid,
  });

  final List<CampusPlace> places;
  final CampusMapGeometry geometry;
  final Color background;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    // A degree grid, drawn only inside the map rectangle, as a sense of scale.
    for (var lat = campusSouth; lat <= campusNorth; lat += 0.005) {
      final y = geometry.offsetOf(lat, campusWest).dy;
      canvas.drawLine(
        Offset(geometry.rect.left, y),
        Offset(geometry.rect.right, y),
        gridPaint,
      );
    }
    for (var lon = campusWest; lon <= campusEast; lon += 0.005) {
      final x = geometry.offsetOf(campusSouth, lon).dx;
      canvas.drawLine(
        Offset(x, geometry.rect.top),
        Offset(x, geometry.rect.bottom),
        gridPaint,
      );
    }

    canvas.drawRect(
      geometry.rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = grid,
    );

    for (final place in places) {
      final point = geometry.offsetOf(place.latitude, place.longitude);
      if (!geometry.rect.contains(point)) continue;
      canvas.drawCircle(point, 5, Paint()..color = const Color(0xFFFFFFFF));
      canvas.drawCircle(point, 3.6, Paint()..color = _colorFor(place.category));
    }
  }

  static Color _colorFor(CampusCategory category) => switch (category) {
        CampusCategory.teaching => const Color(0xFF1565C0),
        CampusCategory.library => const Color(0xFF6A1B9A),
        CampusCategory.food => const Color(0xFFEF6C00),
        CampusCategory.sport => const Color(0xFF2E7D32),
        CampusCategory.dorm => const Color(0xFF5D4037),
        CampusCategory.medical => const Color(0xFFC62828),
      };

  @override
  bool shouldRepaint(covariant _CampusMapPainter old) =>
      old.places != places ||
      old.geometry != geometry ||
      old.background != background ||
      old.grid != grid;
}
