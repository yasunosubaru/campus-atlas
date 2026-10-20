import 'package:flutter/material.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/result.dart';
import '../../core/storage/settings.dart';
import '../../main.dart';
import '../weather/weather_repository.dart';

/// Modal place picker backed by Open-Meteo geocoding.
///
/// Returns null when dismissed; returns a [Geo] when the user picks a result.
/// On cancel or failure the dialog stays open so a bad network does not throw
/// away what the user already typed.
Future<Geo?> showLocationPicker(BuildContext context) =>
    showModalBottomSheet<Geo>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => const _LocationPickerSheet(),
    );

class _LocationPickerSheet extends StatefulWidget {
  const _LocationPickerSheet();

  @override
  State<_LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<_LocationPickerSheet> {
  final _controller = TextEditingController();
  List<PlaceSearchResult> _results = const [];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final l10n = AppLocalizations.of(context);
    final services = AppScope.of(context, dependOn: false);
    final query = _controller.text.trim();
    if (query.length < 2) {
      setState(() => _error = l10n.errorFor('validation'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await services.weather.searchPlaces(query);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result is Success) {
        _results = result.dataOrNull!;
        if (_results.isEmpty) _error = l10n.mapNoResults;
      } else {
        _error = l10n.errorFor(result.errorOrNull?.kind.name ?? 'unknown');
        _results = const [];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: EdgeInsets.only(
        left: appThemeInset,
        right: appThemeInset,
        bottom: MediaQuery.viewInsetsOf(context).bottom + appThemeInset,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.settingsLocation, style: text.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: l10n.mapHint,
              prefixIcon: const Icon(Icons.search),
            ),
            onSubmitted: (_) => _search(),
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _error!,
                style: text.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _results.length,
                itemBuilder: (context, i) {
                  final r = _results[i];
                  return ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(r.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      r.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.of(context).pop(r.toGeo()),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.cancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy ? null : _search,
                child: Text(l10n.search),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Compact page padding constant.
const double appThemeInset = 16;
