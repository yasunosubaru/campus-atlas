import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// Key/value persistence behind an interface so tests never need a plugin
/// implementation (which would otherwise make `flutter test` depend on
/// platform channels).
abstract class SettingsStore {
  Future<String> getString(String key, {String fallback = ''});
  Future<bool> getBool(String key, {bool fallback = false});
  Future<int> getInt(String key, {int fallback = 0});
  Future<void> setString(String key, String value);
  Future<void> setBool(String key, bool value);
  Future<void> setInt(String key, int value);
  Future<void> remove(String key);
}

/// Store backed by `shared_preferences` on real devices.
class PrefsSettingsStore implements SettingsStore {
  PrefsSettingsStore(this._prefs);
  final SharedPreferences _prefs;

  static Future<PrefsSettingsStore> open() async =>
      PrefsSettingsStore(await SharedPreferences.getInstance());

  @override
  Future<String> getString(String key, {String fallback = ''}) async =>
      _prefs.getString(key) ?? fallback;

  @override
  Future<bool> getBool(String key, {bool fallback = false}) async =>
      _prefs.getBool(key) ?? fallback;

  @override
  Future<int> getInt(String key, {int fallback = 0}) async =>
      _prefs.getInt(key) ?? fallback;

  @override
  Future<void> setString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  @override
  Future<void> setBool(String key, bool value) async {
    await _prefs.setBool(key, value);
  }

  @override
  Future<void> setInt(String key, int value) async {
    await _prefs.setInt(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _prefs.remove(key);
  }
}

/// Store backed by a plain map — used by unit tests.
class InMemorySettingsStore implements SettingsStore {
  final Map<String, Object> _data = {};

  @override
  Future<String> getString(String key, {String fallback = ''}) async =>
      _data[key] as String? ?? fallback;

  @override
  Future<bool> getBool(String key, {bool fallback = false}) async =>
      _data[key] as bool? ?? fallback;

  @override
  Future<int> getInt(String key, {int fallback = 0}) async =>
      _data[key] as int? ?? fallback;

  @override
  Future<void> setString(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> setBool(String key, bool value) async {
    _data[key] = value;
  }

  @override
  Future<void> setInt(String key, int value) async {
    _data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _data.remove(key);
  }
}

/// Typed accessors over [SettingsStore], grouped by concern.
///
/// Feature code reads settings through this type rather than raw keys, so a
/// key rename is a refactor rather than a silent behavioural change.
class AppSettings {
  AppSettings(this._store);

  final SettingsStore _store;

  static const String _kTheme = 'themeMode';
  static const String _kLocale = 'locale';
  static const String _kLat = 'location.latitude';
  static const String _kLon = 'location.longitude';
  static const String _kLocName = 'location.name';
  static const String _kAiBase = 'ai.baseUrl';
  static const String _kAiKey = 'ai.apiKey';
  static const String _kAiModel = 'ai.model';
  static const String _kFirstWeekStart = 'timetable.firstWeekStart';
  static const String _kWeatherUnits = 'weather.metric';
  static const String _kGpaStandard = 'grades.gpaStandard';
  static const String _kGpaRequiredOnly = 'grades.requiredOnly';
  static const String _kRequiredCredits = 'grades.requiredCredits';

  Future<ThemeMode> themeMode() async {
    final raw = await _store.getString(_kTheme, fallback: 'system');
    return switch (raw) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  // Enum lives in Flutter; keep the store primitive to avoid a material import
  // in this file.
  Future<void> setThemeMode(ThemeMode mode) => _store.setString(
        _kTheme,
        switch (mode) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          ThemeMode.system => 'system',
        },
      );

  Future<String> localeCode() => _store.getString(_kLocale, fallback: 'zh');

  Future<void> setLocaleCode(String code) => _store.setString(_kLocale, code);

  Future<Geo> location() async {
    final lat = await _store.getString(_kLat);
    final lon = await _store.getString(_kLon);
    if (lat.isEmpty || lon.isEmpty) return Geo.fromConfig();
    return Geo(
      double.tryParse(lat) ?? AppConfig.defaultLocation.latitude,
      double.tryParse(lon) ?? AppConfig.defaultLocation.longitude,
      name: await _store.getString(_kLocName, fallback: ''),
    );
  }

  Future<void> setLocation(Geo g) async {
    await _store.setString(_kLat, g.latitude.toStringAsFixed(6));
    await _store.setString(_kLon, g.longitude.toStringAsFixed(6));
    await _store.setString(_kLocName, g.name);
  }

  Future<AiEndpoint> aiEndpoint() async => AiEndpoint(
        baseUrl: await _store.getString(_kAiBase),
        apiKey: await _store.getString(_kAiKey),
        model: await _store.getString(_kAiModel, fallback: 'gpt-4o-mini'),
      );

  Future<void> setAiEndpoint(AiEndpoint e) async {
    await _store.setString(_kAiBase, e.baseUrl);
    await _store.setString(_kAiKey, e.apiKey);
    await _store.setString(_kAiModel, e.model);
  }

  /// Epoch day (local midnight) the academic week 1 begins.
  Future<DateTime> firstWeekStart() async {
    final ms = await _store.getInt(_kFirstWeekStart, fallback: 0);
    if (ms == 0) return DateTime(2026, 2, 23);
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setFirstWeekStart(DateTime d) =>
      _store.setInt(_kFirstWeekStart, d.millisecondsSinceEpoch);

  Future<bool> metricWeather() async =>
      _store.getBool(_kWeatherUnits, fallback: true);

  Future<void> setMetricWeather(bool v) => _store.setBool(_kWeatherUnits, v);

  /// The GPA algorithm the grade archive computes with, by its stable id.
  ///
  /// Stored as a string rather than an enum index so reordering the enum cannot
  /// silently change which algorithm a person's archive is showing.
  Future<String> gpaStandard() =>
      _store.getString(_kGpaStandard, fallback: 'whu');

  Future<void> setGpaStandard(String id) => _store.setString(_kGpaStandard, id);

  /// Whether the archive counts compulsory courses only.
  Future<bool> gpaRequiredOnly() => _store.getBool(_kGpaRequiredOnly);

  Future<void> setGpaRequiredOnly(bool v) =>
      _store.setBool(_kGpaRequiredOnly, v);

  /// Credits required for graduation, when the person has set one.
  ///
  /// Null rather than 0 for "not set": the two mean different things, and a
  /// progress bar against an assumed requirement would be a number the app has
  /// no basis for.
  Future<double?> requiredCredits() async {
    final raw = await _store.getString(_kRequiredCredits);
    if (raw.trim().isEmpty) return null;
    final value = double.tryParse(raw);
    return value != null && value > 0 ? value : null;
  }

  Future<void> setRequiredCredits(double value) =>
      _store.setString(_kRequiredCredits, '$value');
}

/// A geographic point with a human label.
class Geo {
  const Geo(this.latitude, this.longitude, {this.name = ''});
  final double latitude;
  final double longitude;
  final String name;

  factory Geo.fromConfig() => const Geo(
        AppConfig.defaultLatitude,
        AppConfig.defaultLongitude,
        name: 'Campus',
      );
}

/// OpenAI-compatible endpoint configuration.
class AiEndpoint {
  const AiEndpoint(
      {required this.baseUrl, required this.apiKey, this.model = ''});
  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is AiEndpoint &&
      other.baseUrl == baseUrl &&
      other.apiKey == apiKey &&
      other.model == model;

  @override
  int get hashCode => Object.hash(baseUrl, apiKey, model);
}
