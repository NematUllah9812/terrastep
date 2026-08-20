import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:terrastep_core/data/local/outbox.dart';

/// Durable [Outbox] backed by SharedPreferences.
///
/// Claims are persisted *before* any network attempt, so a force-quit, a
/// crash, or a dead connection can never lose a hex the user earned walking
/// (threshold 2.6 durability). We deliberately keep this as a JSON list in
/// prefs rather than adding a SQLite/Drift dependency: a walker produces at
/// most a few dozen batches, the queue drains within seconds when online, and
/// the whole blob is tiny. If batch volume ever grows (e.g. long offline
/// treks), this is the seam to swap for Drift — nothing else changes.
class PrefsOutbox implements Outbox {
  static const _prefsKey = 'terrastep.outbox.v1';

  final Map<String, OutboxEntry> _entries = {};
  bool _loaded = false;
  SharedPreferences? _prefs;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs?.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        for (final e in list) {
          final entry = OutboxEntry.fromStorage(
              Map<String, dynamic>.from(e as Map));
          _entries[entry.batchUuid] = entry;
        }
      } catch (_) {
        // Corrupt queue is not worth crashing the app over; start fresh.
        // Walking re-creates claims.
      }
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(_prefsKey,
        jsonEncode(_entries.values.map((e) => e.toStorage()).toList()));
  }

  @override
  Future<void> add(OutboxEntry entry) async {
    await _ensureLoaded();
    _entries[entry.batchUuid] = entry;
    await _persist();
  }

  @override
  Future<List<OutboxEntry>> due(
      {required DateTime now, int limit = 5}) async {
    await _ensureLoaded();
    final ready = _entries.values
        .where((e) => !e.notBefore.isAfter(now))
        .toList()
      ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return ready.take(limit).toList();
  }

  @override
  Future<void> remove(String batchUuid) async {
    await _ensureLoaded();
    if (_entries.remove(batchUuid) != null) await _persist();
  }

  @override
  Future<void> recordFailure(
      String batchUuid, String error, DateTime notBefore) async {
    await _ensureLoaded();
    final e = _entries[batchUuid];
    if (e == null) return;
    e.attempts++;
    e.lastError = error;
    e.notBefore = notBefore;
    await _persist();
  }

  @override
  Future<void> backoffAll(String error, DateTime notBefore) async {
    await _ensureLoaded();
    var changed = false;
    for (final e in _entries.values) {
      e.lastError = error;
      if (e.notBefore.isBefore(notBefore)) {
        e.notBefore = notBefore;
        changed = true;
      }
    }
    if (changed) await _persist();
  }

  @override
  Future<int> count() async {
    await _ensureLoaded();
    return _entries.length;
  }

  @override
  Future<List<OutboxEntry>> all() async {
    await _ensureLoaded();
    return _entries.values.toList();
  }
}
