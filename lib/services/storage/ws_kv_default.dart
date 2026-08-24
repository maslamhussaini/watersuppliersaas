// =============================================================================
// lib/services/storage/ws_kv_default.dart
// THE ONLY FILE IN THE APP THAT ASKS WHICH PLATFORM IT IS ON.
//
// If kIsWeb appears anywhere in the outbox, What's New or the registration
// flow, the seam has failed. Those three take a WsKeyValueStore and never learn
// where the bytes go.
// =============================================================================

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

import 'ws_key_value_store.dart';
import 'ws_kv_file.dart';
import 'ws_kv_preferences.dart';
import '../outbox/ws_outbox_kv_store.dart';
import '../outbox/ws_outbox_store.dart';

/// The store this build should use.
///
/// Web gets shared_preferences, because path_provider has no web
/// implementation — the failure that silently disabled the outbox, What's New
/// and GPS before ws_startup.dart separated them.
///
/// Anything else gets a file, keeping the platform's existing behaviour.
/// Neither path throws: a backend that cannot start degrades to memory, which
/// loses state on restart but never prevents the app from running.
Future<WsKeyValueStore> wsOpenDefaultKeyValueStore({
  String fileName = 'ws_store.json',
}) async {
  try {
    if (kIsWeb) {
      return WsPreferencesKeyValueStore(WsSharedPreferencesBackend());
    }
    final dir = await getApplicationSupportDirectory();
    return WsFileKeyValueStore('${dir.path}/$fileName');
  } catch (_) {
    return WsMemoryKeyValueStore();
  }
}

/// The outbox store this build should use.
///
/// Selection lives here, with the rest of the platform knowledge, so that
/// nothing under services/outbox/ has to ask which platform it is on.
///
/// Non-web keeps WsOutboxFileStore unchanged, INCLUDING its .tmp recovery and
/// its brace-scanner salvage for a truncated file. Those guard against a torn
/// write, which is a real failure mode there and not one shared_preferences
/// can produce. Web gets the key/value implementation.
Future<WsOutboxStore> wsOpenDefaultOutboxStore({
  String fileName = 'ws_outbox.json',
}) async {
  try {
    if (kIsWeb) {
      return WsOutboxKvStore(
        WsPreferencesKeyValueStore(WsSharedPreferencesBackend()),
      );
    }
    final dir = await getApplicationSupportDirectory();
    return WsOutboxFileStore('${dir.path}/$fileName');
  } catch (_) {
    // A queue in memory still protects the current session's documents. It is
    // strictly better than an outbox that refuses to start.
    return WsOutboxKvStore(WsMemoryKeyValueStore());
  }
}
