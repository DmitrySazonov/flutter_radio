import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'stations.dart';

class StationStorage {
  static const _keyStations = 'stations_v1';
  static const _keyLastIndex = 'last_index_v1';
  static const _keyVolume = 'volume_v1';
  static const _keyStartLive = 'start_live_on_resume_v1';
  static const _keyWebRemoteEnabled = 'web_remote_enabled_v1'; // <-- NEW

  Future<List<Station>> loadStations() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_keyStations);
    if (raw == null) return const [];
    final List list = jsonDecode(raw) as List;
    return list.map((e) => Station.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveStations(List<Station> stations) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _keyStations,
      jsonEncode(stations.map((e) => e.toJson()).toList()),
    );
  }

  Future<int?> loadLastIndex() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getInt(_keyLastIndex);
  }

  Future<void> saveLastIndex(int index) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_keyLastIndex, index);
  }

  Future<double?> loadVolume() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getDouble(_keyVolume);
  }

  Future<void> saveVolume(double v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_keyVolume, v);
  }

  Future<bool?> loadStartLiveOnResume() async {
    final sp = await SharedPreferences.getInstance();
    if (!sp.containsKey(_keyStartLive)) return null;
    return sp.getBool(_keyStartLive);
  }

  Future<void> saveStartLiveOnResume(bool enabled) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_keyStartLive, enabled);
  }

  Future<bool?> loadWebRemoteEnabled() async {
    final sp = await SharedPreferences.getInstance();
    if (!sp.containsKey(_keyWebRemoteEnabled)) return null;
    return sp.getBool(_keyWebRemoteEnabled);
  }

  Future<void> saveWebRemoteEnabled(bool enabled) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_keyWebRemoteEnabled, enabled);
  }
}
