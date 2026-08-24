// =============================================================================
// test/storage_test.dart
// The key/value seam, both implementations, and the registration attempt that
// has to survive a browser reload.
// =============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/auth/ws_registration_attempt_store.dart';
import 'package:watersuppliersaas/services/storage/ws_key_value_store.dart';
import 'package:watersuppliersaas/services/storage/ws_kv_file.dart';
import 'package:watersuppliersaas/services/storage/ws_kv_preferences.dart';
import 'package:watersuppliersaas/services/whats_new.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('ws_kv'));
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  String path() => '${dir.path}/store.json';

  // ═══ THE CONTRACT, BOTH IMPLEMENTATIONS ═══════════════════════════════════

  void contractTests(String name, WsKeyValueStore Function() open) {
    group('$name honours the contract', () {
      test('write then read', () async {
        final s = open();
        await s.write('k', 'v');
        expect(await s.read('k'), 'v');
      });

      test('a missing key reads null rather than throwing', () async {
        expect(await open().read('never-written'), isNull);
      });

      test('overwrite replaces', () async {
        final s = open();
        await s.write('k', 'one');
        await s.write('k', 'two');
        expect(await s.read('k'), 'two');
      });

      test('remove', () async {
        final s = open();
        await s.write('k', 'v');
        await s.remove('k');
        expect(await s.read('k'), isNull);
      });

      test('removing something absent is not an error', () async {
        await expectLater(open().remove('nope'), completes);
      });

      test('clear empties it', () async {
        final s = open();
        await s.write('a', '1');
        await s.write('b', '2');
        await s.clear();
        expect(await s.read('a'), isNull);
        expect(await s.read('b'), isNull);
      });

      test('values with newlines and unicode survive', () async {
        final s = open();
        const awkward = 'line\nbreak "quoted" مرحبا';
        await s.write('k', awkward);
        expect(await s.read('k'), awkward);
      });
    });
  }

  contractTests('the file store', () => WsFileKeyValueStore(path()));
  contractTests('the preferences store',
      () => WsPreferencesKeyValueStore(WsFakePreferencesBackend()));
  contractTests('the memory store', () => WsMemoryKeyValueStore());

  // ═══ PERSISTENCE ACROSS A FRESH INSTANCE ══════════════════════════════════

  group('state survives a restart', () {
    test('file store: a new instance reads what the old one wrote', () async {
      await WsFileKeyValueStore(path()).write('k', 'v');
      expect(await WsFileKeyValueStore(path()).read('k'), 'v',
          reason: 'a fresh instance is what an app restart looks like');
    });

    test('preferences store: the backend outlives the wrapper', () async {
      final backend = WsFakePreferencesBackend();
      await WsPreferencesKeyValueStore(backend).write('k', 'v');
      expect(await WsPreferencesKeyValueStore(backend).read('k'), 'v',
          reason: 'a browser reload keeps localStorage and rebuilds the app');
    });
  });

  // ═══ CORRUPTION ═══════════════════════════════════════════════════════════

  group('corrupt data does not stop the app', () {
    test('unparseable file reads as empty rather than throwing', () async {
      await File(path()).writeAsString('{not json at all');
      expect(await WsFileKeyValueStore(path()).read('k'), isNull);
    });

    test('a leftover .tmp is recovered — the write finished, the rename did not',
        () async {
      await File('${path()}.tmp').writeAsString(jsonEncode({'k': 'rescued'}));
      expect(await WsFileKeyValueStore(path()).read('k'), 'rescued');
    });

    test('non-string values are skipped, not crashed on', () async {
      await File(path()).writeAsString(jsonEncode({'a': 1, 'b': 'ok'}));
      final s = WsFileKeyValueStore(path());
      expect(await s.read('a'), isNull);
      expect(await s.read('b'), 'ok');
    });
  });

  // ═══ NAMESPACING ══════════════════════════════════════════════════════════

  group('namespacing', () {
    test('preferences clear() leaves keys it does not own alone', () async {
      final backend = WsFakePreferencesBackend();
      // Supabase persists its session in the same store. Wiping it would sign
      // the user out every time we cleared our own state.
      await backend.setString('sb-auth-token', 'someone-elses');
      final s = WsPreferencesKeyValueStore(backend);
      await s.write('mine', 'v');

      await s.clear();

      expect(await backend.getString('sb-auth-token'), 'someone-elses');
      expect(await s.read('mine'), isNull);
    });

    test('two prefixed stores over one backend do not collide', () async {
      final backing = WsMemoryKeyValueStore();
      final a = WsPrefixedKeyValueStore(backing, 'outbox');
      final b = WsPrefixedKeyValueStore(backing, 'whatsNew');

      await a.write('k', 'from-a');
      await b.write('k', 'from-b');

      expect(await a.read('k'), 'from-a');
      expect(await b.read('k'), 'from-b');
    });

    test('a prefixed clear does not wipe its neighbour', () async {
      final backing = WsMemoryKeyValueStore();
      final a = WsPrefixedKeyValueStore(backing, 'outbox');
      final b = WsPrefixedKeyValueStore(backing, 'whatsNew');
      await a.write('k', '1');
      await b.write('k', '2');

      await a.clear();

      expect(await a.read('k'), isNull);
      expect(await b.read('k'), '2');
    });
  });

  // ═══ WHAT'S NEW ON THE SEAM ═══════════════════════════════════════════════

  group("What's New over the seam", () {
    test('a recorded version survives a restart', () async {
      final backend = WsFakePreferencesBackend();
      await WsSeenKvStore(WsPreferencesKeyValueStore(backend)).write('1.5.0');

      final after = WsSeenKvStore(WsPreferencesKeyValueStore(backend));
      expect(await after.read(), '1.5.0');
    });

    test('nothing stored reads as never seen', () async {
      expect(await WsSeenKvStore(WsMemoryKeyValueStore()).read(), isNull);
    });

    test('clear forgets it', () async {
      final s = WsSeenKvStore(WsMemoryKeyValueStore());
      await s.write('1.5.0');
      await s.clear();
      expect(await s.read(), isNull);
    });
  });

  // ═══ THE REGISTRATION ATTEMPT ═════════════════════════════════════════════

  group('the registration attempt', () {
    WsRegistrationAttempt attempt({
      String uuid = 'uuid-1',
      String state = 'phoneOtpSent',
      String assurance = 'none',
      DateTime? startedAt,
      int? orgId,
    }) =>
        WsRegistrationAttempt(
          clientUuid: uuid,
          state: state,
          assurance: assurance,
          authUserId: 'auth-1',
          email: 'owner@example.com',
          phone: '+923001234567',
          orgName: 'Kent Water',
          ownerName: 'Essa',
          orgPhone: '+923009999999',
          address: 'Karachi',
          startedAt: startedAt ?? DateTime.utc(2026, 8, 14, 9),
          organizationId: orgId,
        );

    test('round-trips through storage unchanged', () async {
      final kv = WsMemoryKeyValueStore();
      await WsRegistrationAttemptStore(kv).save(attempt());

      final back = await WsRegistrationAttemptStore(kv).load(
        now: DateTime.utc(2026, 8, 14, 10),
      );

      expect(back!.clientUuid, 'uuid-1');
      expect(back.phone, '+923001234567');
      expect(back.state, 'phoneOtpSent');
      expect(back.orgName, 'Kent Water');
    });

    test('THE SAME clientuuid survives a reload', () async {
      final backend = WsFakePreferencesBackend();
      final store = WsRegistrationAttemptStore(
          WsPreferencesKeyValueStore(backend));
      await store.save(attempt(uuid: 'the-one-key'));

      // A browser reload: everything in memory is gone, localStorage is not.
      final afterReload = await WsRegistrationAttemptStore(
        WsPreferencesKeyValueStore(backend),
      ).load(now: DateTime.utc(2026, 8, 14, 10));

      expect(afterReload!.clientUuid, 'the-one-key');
    });

    test('a wrong code does not change the key', () async {
      final kv = WsMemoryKeyValueStore();
      final store = WsRegistrationAttemptStore(kv);
      final a = attempt(uuid: 'k');
      await store.save(a);

      // What a failed verification writes back: attempt count changes, key
      // does not. copyWith cannot even express a new one.
      await store.save(a.copyWith(state: 'phoneOtpSent'));

      final back = await store.load(now: DateTime.utc(2026, 8, 14, 10));
      expect(back!.clientUuid, 'k');
    });

    test('a resend does not change the key', () async {
      final kv = WsMemoryKeyValueStore();
      final store = WsRegistrationAttemptStore(kv);
      await store.save(attempt(uuid: 'k'));
      final mid = await store.load(now: DateTime.utc(2026, 8, 14, 10));
      await store.save(mid!.copyWith());

      expect((await store.load(now: DateTime.utc(2026, 8, 14, 10)))!.clientUuid,
          'k');
    });

    test('a session expiry does not change the key', () async {
      final kv = WsMemoryKeyValueStore();
      final store = WsRegistrationAttemptStore(kv);
      await store.save(attempt(uuid: 'k'));
      final resumed = (await store.load(now: DateTime.utc(2026, 8, 14, 10)))!
          .copyWith(state: 'sessionMissing');
      await store.save(resumed);

      expect((await store.load(now: DateTime.utc(2026, 8, 14, 10)))!.clientUuid,
          'k');
    });

    test('assurance is persisted, so a resume cannot upgrade itself', () async {
      final kv = WsMemoryKeyValueStore();
      await WsRegistrationAttemptStore(kv)
          .save(attempt(state: 'phoneAlreadyConfirmed',
              assurance: 'serverAsserted'));

      final back = await WsRegistrationAttemptStore(kv)
          .load(now: DateTime.utc(2026, 8, 14, 10));

      expect(back!.assurance, 'serverAsserted',
          reason: 'coming back from a reload must not silently become '
              'otpProven');
    });

    test('clearing after provisioning leaves nothing to resume', () async {
      final kv = WsMemoryKeyValueStore();
      final store = WsRegistrationAttemptStore(kv);
      await store.save(attempt(orgId: 42));

      await store.clear();

      expect(await store.load(), isNull);
    });

    test('abandoning is the same operation', () async {
      final kv = WsMemoryKeyValueStore();
      final store = WsRegistrationAttemptStore(kv);
      await store.save(attempt());
      await store.clear();
      expect(await store.load(), isNull);
    });

    test('corrupt JSON yields no attempt and clears itself', () async {
      final kv = WsMemoryKeyValueStore(
          {WsRegistrationAttemptStore.storageKey: '{half a jso'});
      final store = WsRegistrationAttemptStore(kv);

      expect(await store.load(), isNull);
      expect(await kv.read(WsRegistrationAttemptStore.storageKey), isNull,
          reason: 'a payload that cannot be read should not be re-decided on '
              'every launch');
    });

    test('a payload with no key is not resumable', () async {
      final kv = WsMemoryKeyValueStore({
        WsRegistrationAttemptStore.storageKey:
            jsonEncode({'state': 'phoneOtpSent'}),
      });
      expect(await WsRegistrationAttemptStore(kv).load(), isNull,
          reason: 'without a clientuuid there is nothing worth resuming');
    });

    test('a stale attempt is not resumed days later', () async {
      final kv = WsMemoryKeyValueStore();
      await WsRegistrationAttemptStore(kv)
          .save(attempt(startedAt: DateTime.utc(2026, 8, 1)));

      expect(
        await WsRegistrationAttemptStore(kv)
            .load(now: DateTime.utc(2026, 8, 14)),
        isNull,
      );
    });

    // ─── SECRETS ────────────────────────────────────────────────────────────

    test('NO SECRET IS EVER PERSISTED', () async {
      final kv = WsMemoryKeyValueStore();
      await WsRegistrationAttemptStore(kv).save(attempt());
      final raw = (await kv.read(WsRegistrationAttemptStore.storageKey))!;

      // Checked as KEYS, not as substrings. A substring scan reports
      // 'phoneOtpSent' as containing 'otp' and 'token', which is a false
      // positive that would make the test useless the moment someone silenced
      // it. The field NAMES are what say whether a secret is stored.
      final keys = jsonDecode(raw) as Map<String, dynamic>;
      for (final forbidden in [
        'password',
        'accessToken', 'access_token',
        'refreshToken', 'refresh_token',
        'otp', 'otpCode', 'code', 'token', 'session',
      ]) {
        expect(keys.containsKey(forbidden), isFalse,
            reason: 'the persisted attempt must never carry $forbidden — '
                'Supabase owns the session, and writing down the code that '
                'proves possession of the phone would defeat asking for it');
      }

      // And nothing that merely LOOKS like a credential slipped into a value.
      for (final value in keys.values) {
        expect('$value', isNot(matches(RegExp(r'^eyJ[A-Za-z0-9_-]{10,}\.'))),
            reason: 'that is the shape of a JWT');
        expect('$value'.toLowerCase(), isNot(contains('bearer ')));
      }
    });

    test('the persisted surface is exactly the declared fields', () async {
      final json = attempt().toJson();
      expect(
        json.keys.toSet(),
        {
          'clientUuid', 'authUserId', 'email', 'phone', 'state', 'assurance',
          'orgName', 'ownerName', 'orgPhone', 'address', 'startedAt',
        },
        reason: 'a new field here is a deliberate decision, not an accident',
      );
    });
  });
}
