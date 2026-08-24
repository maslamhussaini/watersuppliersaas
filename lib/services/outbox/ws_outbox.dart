// =============================================================================
// lib/services/outbox/ws_outbox.dart
// The offline queue. PURE DART — no Flutter, no Supabase, no accounting.
//
// This file knows three things: that an operation is a named RPC with a map of
// arguments, that operations have an order, and that some failures are worth
// retrying. It does not know what a delivery is, how a journal entry is
// posted, how bottle balances are derived, or that Supabase exists.
//
// That isolation is the point. The posting rules live in Postgres where they
// are enforced; duplicating any of them here would create the second source of
// truth we spent migration 009 avoiding.
//
// Being pure Dart also means the lifecycle can be tested with `dart test`,
// with no device, no emulator and no network.
//
// ─── LIFECYCLE ───────────────────────────────────────────────────────────────
//
//   pending ──▶ syncing ──▶ synced
//                  │
//                  └──▶ failed ──(retry)──▶ pending
//
// ─── THE GUARANTEE, AND WHERE IT COMES FROM ──────────────────────────────────
//
// Every item carries a clientuuid generated when the user saved the document,
// before any network existed. Postgres holds a unique index on
// (orgid, clientuuid) and the posting functions look the key up before
// writing (migration 010). So re-posting is not merely tolerated — it is a
// read.
//
// This is what makes the dangerous case survivable: Postgres commits, the
// response is lost, the client retries. The retry returns the original
// document id and writes nothing.
//
// The queue therefore NEVER has to answer "did that land?" before retrying.
// It could not answer it correctly anyway.
// =============================================================================

import 'dart:async';
import 'dart:math';

import 'ws_outbox_store.dart';

// ─── Idempotency keys ─────────────────────────────────────────────────────────

final _rng = Random.secure();

/// A RFC 4122 version-4 UUID, from the cryptographic RNG.
///
/// Written here rather than pulled from the `uuid` package: it is twenty lines,
/// it keeps the queue dependency-free (and therefore testable with plain
/// `dart test`), and this project has lost builds to package-version surprises
/// twice already.
///
/// Random.secure() matters. A predictable key is not merely untidy — two
/// devices generating the same key would have their documents silently
/// collapsed into one by the server's idempotency check.
String wsNewUuid() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
  String h(int start, int end) =>
      b.sublist(start, end).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}

// ─── Status ───────────────────────────────────────────────────────────────────

enum WsOutboxStatus { pending, syncing, synced, failed }

WsOutboxStatus _statusFrom(String? s) => switch (s) {
      'syncing' => WsOutboxStatus.syncing,
      'synced' => WsOutboxStatus.synced,
      'failed' => WsOutboxStatus.failed,
      _ => WsOutboxStatus.pending,
    };

String _statusName(WsOutboxStatus s) => s.name;

// ─── Result of one post attempt ───────────────────────────────────────────────

enum WsPostOutcome {
  /// Posted, or already posted. Either way the server has it exactly once.
  success,

  /// Worth trying again: no network, timeout, 5xx, connection reset.
  retryable,

  /// Will never succeed as-is: validation, permission, a missing customer.
  /// Retrying it forever would block every item behind it.
  permanent,
}

class WsPostResult {
  final WsPostOutcome outcome;

  /// Server-assigned document id, when known.
  final int? documentId;

  final String? error;
  final int? statusCode;

  /// Postgres SQLSTATE, when the failure came from the database.
  final String? code;

  /// TRUE when the request never reached a server: no signal, dead wifi,
  /// dropped connection, timeout.
  ///
  /// This distinction exists because the two kinds of retryable failure mean
  /// completely different things. A driver in a basement is not a problem with
  /// the delivery — trying again in ten minutes is the correct and only
  /// answer, and there is no number of failed attempts that should change
  /// that. A 500 from the server IS a problem: if it is still happening after
  /// several tries, someone needs to look at it.
  ///
  /// So network failures leave the item pending forever, and only non-network
  /// retryable failures consume the budget that ends in Failed.
  final bool isNetwork;

  const WsPostResult.success({this.documentId})
      : outcome = WsPostOutcome.success,
        error = null,
        statusCode = null,
        code = null,
        isNetwork = false;

  /// A failure the server produced: 5xx, a lock timeout, a unique-key race.
  /// Worth retrying, but it counts against the budget.
  const WsPostResult.retryable(this.error, {this.statusCode, this.code})
      : outcome = WsPostOutcome.retryable,
        documentId = null,
        isNetwork = false;

  /// The request did not reach a server at all. Retried indefinitely and
  /// NEVER marked failed, because nothing about it is wrong.
  const WsPostResult.network(this.error, {this.statusCode, this.code})
      : outcome = WsPostOutcome.retryable,
        documentId = null,
        isNetwork = true;

  const WsPostResult.permanent(this.error, {this.statusCode, this.code})
      : outcome = WsPostOutcome.permanent,
        documentId = null,
        isNetwork = false;
}

/// Sends one operation. Supplied by the caller — this is the only seam through
/// which the queue touches the network.
typedef WsOutboxPoster = Future<WsPostResult> Function(WsOutboxItem item);

// ─── One queued operation ─────────────────────────────────────────────────────

class WsOutboxItem {
  /// Monotonic, assigned at enqueue. Defines processing order and never
  /// changes — retrying an item does not move it to the back of the queue,
  /// because a later document may depend on it.
  final int seq;

  /// The idempotency key. Generated on the device at save time and reused by
  /// every attempt, forever. This is the single most important field here.
  final String clientUuid;

  /// What to call, and with what. Stored verbatim so a retry is byte-identical
  /// to the original attempt.
  final String rpc;
  final Map<String, dynamic> args;

  /// For showing the user something meaningful in a queue list without the
  /// outbox having to understand the payload.
  final String label;

  final DateTime createdAt;

  WsOutboxStatus status;

  /// EVERY attempt, including the ones that died in the network. Diagnostic
  /// only — it is what the sync screen shows.
  int attempts;

  /// Attempts that actually reached a server and were refused in a way worth
  /// retrying. ONLY THIS counts towards maxAutoAttempts.
  ///
  /// Kept separate so that a week of no signal cannot push a perfectly good
  /// delivery into Failed.
  int budgetedAttempts;

  /// Whether the most recent failure was a network one. Lets the UI say
  /// "waiting for a connection" instead of "error".
  bool lastWasNetwork;

  DateTime? lastAttemptAt;
  String? lastError;
  int? lastStatusCode;
  String? lastCode;

  /// WHO CREATED THIS DOCUMENT, captured at Save time.
  ///
  /// The queue is durable and survives sign-out. Without this, a delivery
  /// queued by one driver drained under the next driver's session: the server
  /// derives orgid from the customer, so RLS blocks a DIFFERENT organization —
  /// but two staff in the SAME organization is the normal shared-tablet case,
  /// and the document would post attributed to the wrong person.
  ///
  /// Payload-authoritative, exactly like clientUuid, storeid and the GPS fix:
  /// captured when the document was created and never rewritten afterwards.
  ///
  /// Null means one of two things, and they are NOT the same:
  ///   * ownership is not in use (no provider given — the pre-existing
  ///     behaviour every older test relies on), or
  ///   * a legacy item queued before this field existed. See _adoptLegacy.
  String? authUserId;

  /// Server document id, once posted.
  int? documentId;
  DateTime? syncedAt;

  WsOutboxItem({
    required this.seq,
    required this.clientUuid,
    required this.rpc,
    required this.args,
    required this.label,
    required this.createdAt,
    this.status = WsOutboxStatus.pending,
    this.attempts = 0,
    this.budgetedAttempts = 0,
    this.lastWasNetwork = false,
    this.lastAttemptAt,
    this.lastError,
    this.lastStatusCode,
    this.lastCode,
    this.authUserId,
    this.documentId,
    this.syncedAt,
  });

  bool get isTerminal => status == WsOutboxStatus.synced;
  bool get needsAttention => status == WsOutboxStatus.failed;

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'clientUuid': clientUuid,
        'rpc': rpc,
        'args': args,
        'label': label,
        'createdAt': createdAt.toIso8601String(),
        'status': _statusName(status),
        'attempts': attempts,
        'budgetedAttempts': budgetedAttempts,
        'lastWasNetwork': lastWasNetwork,
        'lastAttemptAt': lastAttemptAt?.toIso8601String(),
        'lastError': lastError,
        'lastStatusCode': lastStatusCode,
        'lastCode': lastCode,
        'authUserId': authUserId,
        'documentId': documentId,
        'syncedAt': syncedAt?.toIso8601String(),
      };

  factory WsOutboxItem.fromJson(Map<String, dynamic> j) => WsOutboxItem(
        seq: (j['seq'] as num?)?.toInt() ?? 0,
        clientUuid: '${j['clientUuid']}',
        rpc: '${j['rpc']}',
        args: Map<String, dynamic>.from(j['args'] as Map? ?? const {}),
        label: '${j['label'] ?? j['rpc']}',
        createdAt:
            DateTime.tryParse('${j['createdAt']}') ?? DateTime.now(),
        status: _statusFrom(j['status'] as String?),
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        // Absent in queues written before the network/budget split. Falling
        // back to `attempts` preserves the OLD behaviour for those items
        // rather than silently handing them a fresh budget.
        budgetedAttempts: (j['budgetedAttempts'] as num?)?.toInt() ??
            (j['attempts'] as num?)?.toInt() ??
            0,
        lastWasNetwork: j['lastWasNetwork'] == true,
        lastAttemptAt: DateTime.tryParse('${j['lastAttemptAt']}'),
        lastError: j['lastError'] as String?,
        lastStatusCode: (j['lastStatusCode'] as num?)?.toInt(),
        lastCode: j['lastCode'] as String?,
        // Absent in files written before ownership existed. Stays null, which
        // _adoptLegacy resolves once — never guessed at read time.
        authUserId: j['authUserId'] as String?,
        documentId: (j['documentId'] as num?)?.toInt(),
        syncedAt: DateTime.tryParse('${j['syncedAt']}'),
      );
}

// ─── The queue ────────────────────────────────────────────────────────────────

class WsOutbox {
  final WsOutboxStore store;
  final WsOutboxPoster poster;

  /// Who is signed in right now. NULL MEANS OWNERSHIP IS NOT IN USE.
  ///
  /// That is deliberately distinct from "the provider returned null", which
  /// means nobody is signed in. With no provider the queue behaves exactly as
  /// it did before ownership existed — which is what the pre-existing suites
  /// and the Postgres matrix exercise, unchanged.
  ///
  /// Production supplies it in ws_outbox_supabase.dart.
  final String? Function()? currentUserId;

  /// Attempts before an item stops retrying automatically and waits for a
  /// human. Not infinite: an item that has failed eight times is not going to
  /// succeed on the ninth without someone looking at it, and it is holding up
  /// everything behind it.
  final int maxAutoAttempts;

  /// How many synced items to keep for diagnosis before pruning.
  final int keepSynced;

  /// How long to keep synced items regardless of count.
  final Duration keepSyncedFor;

  List<WsOutboxItem> _items = [];
  bool _loaded = false;
  bool _draining = false;

  /// Fires whenever the queue changes, so a badge or list can rebuild.
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  WsOutbox({
    required this.store,
    required this.poster,
    this.currentUserId,
    this.maxAutoAttempts = 8,
    this.keepSynced = 100,
    this.keepSyncedFor = const Duration(days: 7),
  });

  // ── Loading ──────────────────────────────────────────────────────────────

  /// Non-null when the last [load] could not read the stored queue cleanly.
  ///
  /// Deliberately sticky: it is NOT cleared by draining or by a successful
  /// save, only by a clean load or by [acknowledgeLoadIssue]. A corrupt queue
  /// is something a human has to be told about, and clearing it the moment
  /// anything else succeeded would put it back to being invisible.
  WsOutboxLoadIssue? get loadIssue => _loadIssue;
  WsOutboxLoadIssue? _loadIssue;

  /// Called when the user has been shown the problem.
  void acknowledgeLoadIssue() {
    _loadIssue = null;
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> load() async {
    final raw = await store.load();
    _loadIssue = store.lastLoadIssue;
    _items = raw.map(WsOutboxItem.fromJson).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));

    // CRASH RECOVERY.
    //
    // An item left in `syncing` means the app died mid-attempt. We cannot know
    // whether the server applied it — that is precisely the unanswerable
    // question — so we put it back to `pending` and let it be posted again.
    //
    // This is safe ONLY because of the clientuuid: a re-post of something that
    // landed returns the original id and writes nothing. Without migration 010
    // this line would duplicate documents on every crash.
    var recovered = 0;
    for (final it in _items) {
      if (it.status == WsOutboxStatus.syncing) {
        it.status = WsOutboxStatus.pending;
        recovered++;
      }
    }
    _loaded = true;
    if (recovered > 0) await _persist();
  }

  Future<void> _ensureLoaded() async {
    if (!_loaded) await load();
  }

  Future<void> _persist() async {
    await store.save(_items.map((e) => e.toJson()).toList());
    if (!_changes.isClosed) _changes.add(null);
  }

  // ── Reading ──────────────────────────────────────────────────────────────

  List<WsOutboxItem> get items => List.unmodifiable(_items);

  /// ─── WHO MAY SEE OR TOUCH AN ITEM ───────────────────────────────────────
  ///
  /// The drain has always been owner-aware; the UI never was. WsSyncScreen
  /// rendered [items] raw, so on a shared tablet driver B could read driver A's
  /// customer names and amounts out of the labels — and, worse, permanently
  /// discard A's unsent deliveries, because discard() and retry() matched on
  /// clientUuid alone.
  ///
  /// The rule, deliberately NOT `authUserId == uid`:
  ///
  ///   no session          nothing is visible or touchable
  ///   authUserId == null  allowed — unowned work that _adoptLegacy will claim
  ///                       for whoever drains next. Hiding it would make live
  ///                       work invisible to everyone, which is worse than
  ///                       showing it to the wrong person
  ///   authUserId == uid   allowed
  ///   anything else       refused
  ///
  /// This mirrors the drain, which adopts nulls BEFORE filtering, so what the
  /// screen shows and what the drain will post stay in step.
  bool _mayAccess(WsOutboxItem item, String? uid) =>
      uid != null && (item.authUserId == null || item.authUserId == uid);

  /// Authorisation for the mutators.
  ///
  /// When no [currentUserId] provider is installed, ownership is NOT IN USE and
  /// every item is touchable — the same opt-in the drain honours at :509, and
  /// the reason every pre-ownership caller and test keeps working unchanged.
  /// Distinct from "the provider returned null", which means no session and
  /// refuses.
  bool _mayMutate(WsOutboxItem item) {
    final provider = currentUserId;
    if (provider == null) return true;
    return _mayAccess(item, provider());
  }

  /// The queue as [uid] is allowed to see it. Null uid yields nothing.
  ///
  /// Read-only and side-effect free. Device-wide counts ([pendingCount],
  /// [failedCount]) are deliberately NOT scoped — the sign-out warning depends
  /// on them never under-reporting, which is a separate, settled decision.
  List<WsOutboxItem> visibleTo(String? uid) =>
      _items.where((e) => _mayAccess(e, uid)).toList();

  /// [visibleTo] resolved through the installed session provider.
  ///
  /// Honours the same opt-in as [_mayMutate]: with no provider installed
  /// ownership is not in use and everything is visible, which is what keeps
  /// pre-ownership callers behaving as they always did. This is what the sync
  /// screen renders, so the screen needs no session lookup of its own.
  List<WsOutboxItem> get visibleToCurrentUser {
    final provider = currentUserId;
    if (provider == null) return List.unmodifiable(_items);
    return visibleTo(provider());
  }

  List<WsOutboxItem> get pending => _items
      .where((e) =>
          e.status == WsOutboxStatus.pending ||
          e.status == WsOutboxStatus.syncing)
      .toList();

  List<WsOutboxItem> get failed =>
      _items.where((e) => e.status == WsOutboxStatus.failed).toList();

  int get pendingCount => pending.length;
  int get failedCount => failed.length;

  WsOutboxItem? byUuid(String uuid) {
    for (final it in _items) {
      if (it.clientUuid == uuid) return it;
    }
    return null;
  }

  // ── Writing ──────────────────────────────────────────────────────────────

  /// Queue an operation. Returns the stored item.
  ///
  /// Enqueue is ALWAYS the first thing that happens, before any network call,
  /// including when the device is online. A document that exists only in a
  /// pending HTTP request exists nowhere if the app is killed.
  Future<WsOutboxItem> enqueue({
    required String clientUuid,
    required String rpc,
    required Map<String, dynamic> args,
    required String label,
  }) async {
    await _ensureLoaded();

    // Enqueueing the same key twice is a bug in the caller, not a second
    // document. Return what is already there.
    final existing = byUuid(clientUuid);
    if (existing != null) return existing;

    final seq = _items.isEmpty
        ? 1
        : _items.map((e) => e.seq).reduce(max) + 1;

    final item = WsOutboxItem(
      seq: seq,
      clientUuid: clientUuid,
      rpc: rpc,
      args: args,
      label: label,
      createdAt: DateTime.now(),
      // AT SAVE TIME, not at sync time. The session that syncs may be somebody
      // else's; the session that created the document is the truthful one, and
      // it is the one recorded.
      authUserId: currentUserId?.call(),
    );
    _items.add(item);
    await _persist();
    return item;
  }

  /// Move a failed item back to pending so the next drain picks it up.
  /// Its seq is unchanged, so it keeps its place in the order.
  Future<bool> retry(String clientUuid) async {
    await _ensureLoaded();
    final it = byUuid(clientUuid);
    if (it == null || it.status != WsOutboxStatus.failed) return false;

    // Somebody else's item. Refused BEFORE anything is written, so status,
    // attempts and budgetedAttempts are all left exactly as they were — a
    // refused retry must not quietly strip another driver's failure history
    // out of their own triage list.
    if (!_mayMutate(it)) return false;

    it.status = WsOutboxStatus.pending;
    it.attempts = 0; // manual retry gets a fresh budget
    it.budgetedAttempts = 0;
    await _persist();
    return true;
  }

  /// Abandon an item. For an operation that will never be valid — a customer
  /// deleted while the document sat in the queue, say.
  ///
  /// It is dropped rather than marked, because a discarded document must not
  /// look like a synced one in the history.
  Future<bool> discard(String clientUuid) async {
    await _ensureLoaded();

    // The data-loss guard. Without it, matching on clientUuid alone let one
    // driver permanently destroy another's unsent delivery — no tombstone, no
    // undo. Refused before removeWhere, so the item stays present and
    // persisted exactly as it was.
    final target = byUuid(clientUuid);
    if (target == null) return false;
    if (!_mayMutate(target)) return false;

    final before = _items.length;
    _items.removeWhere((e) =>
        e.clientUuid == clientUuid && e.status != WsOutboxStatus.synced);
    if (_items.length == before) return false;
    await _persist();
    return true;
  }

  // ── Draining ─────────────────────────────────────────────────────────────

  /// Post everything pending, oldest first.
  ///
  /// ORDER IS PRESERVED AND THE DRAIN STOPS AT THE FIRST FAILURE. If item 3
  /// cannot post, items 4 and 5 wait. They may depend on it — a payment
  /// against a delivery that has not been created yet is the obvious case —
  /// and posting them out of order would produce documents that reference
  /// nothing.
  ///
  /// A PERMANENT failure is the exception: it will never succeed, so blocking
  /// the queue behind it forever is worse. It is marked failed and skipped,
  /// and surfaced for a human.
  Future<WsDrainReport> drain() async {
    await _ensureLoaded();

    // One drain at a time. Two concurrent drains would post the same item
    // twice — harmless thanks to idempotency, but it would double the
    // attempt counts and confuse the diagnostics.
    if (_draining) {
      return const WsDrainReport(skippedBusy: true);
    }
    _draining = true;

    var posted = 0, failedNow = 0, blocked = 0;
    try {
      // ── OWNERSHIP ────────────────────────────────────────────────────────
      //
      // Skipped entirely when no provider was given, so the queue behaves
      // exactly as it always has for callers that do not use ownership.
      String? uid;
      if (currentUserId != null) {
        uid = currentUserId!();

        // NO SESSION, NO DRAIN. At startup the queue loads before the auth gate
        // has resolved anything, so this is reached with uid == null on a cold
        // launch. Posting then would use whatever session Supabase restored —
        // possibly the next user's. Deferring is always safe: the queue is
        // durable and the next drain picks it up.
        if (uid == null) {
          _draining = false;
          return const WsDrainReport();
        }

        await _adoptLegacy(uid);
      }

      final queue = _items
          .where((e) =>
              (e.status == WsOutboxStatus.pending ||
                  e.status == WsOutboxStatus.syncing) &&
              // Someone else's document waits for them. NEVER deleted, never
              // posted under this session, and not counted as a failure —
              // there is nothing wrong with it.
              (uid == null || e.authUserId == uid))
          .toList()
        ..sort((a, b) => a.seq.compareTo(b.seq));

      for (final item in queue) {
        item.status = WsOutboxStatus.syncing;
        item.attempts += 1;
        item.lastAttemptAt = DateTime.now();
        // Persisted BEFORE the call, so a crash mid-flight leaves evidence
        // that this item was in the air. load() turns it back to pending.
        await _persist();

        late WsPostResult result;
        try {
          result = await poster(item);
        } catch (e) {
          // The poster is supposed to classify its own failures. If it throws
          // instead, assume retryable — losing a document to an unhandled
          // exception is far worse than one extra attempt.
          result = WsPostResult.retryable('$e');
        }

        switch (result.outcome) {
          case WsPostOutcome.success:
            item.status = WsOutboxStatus.synced;
            item.documentId = result.documentId;
            item.syncedAt = DateTime.now();
            item.lastError = null;
            item.lastStatusCode = null;
            item.lastCode = null;
            posted++;
            await _persist();

          case WsPostOutcome.permanent:
            item.status = WsOutboxStatus.failed;
            item.lastError = result.error;
            item.lastStatusCode = result.statusCode;
            item.lastCode = result.code;
            failedNow++;
            await _persist();
          // Skipped, not blocking: it cannot succeed, so waiting changes
          // nothing except stopping every later document too.

          case WsPostOutcome.retryable:
            item.lastError = result.error;
            item.lastStatusCode = result.statusCode;
            item.lastCode = result.code;
            item.lastWasNetwork = result.isNetwork;

            // A NETWORK FAILURE IS NOT THE DOCUMENT'S FAULT.
            //
            // It never reached a server, so there is nothing to judge it on
            // and no number of attempts that makes it more wrong. It stays
            // pending indefinitely and the next drain after the connection
            // returns picks it up on its own — no red badge, no manual Retry,
            // no chance of a driver's whole day sitting in Failed because the
            // van spent the morning out of coverage.
            //
            // Only failures a SERVER produced consume the budget.
            if (!result.isNetwork) {
              item.budgetedAttempts += 1;
              if (item.budgetedAttempts >= maxAutoAttempts) {
                item.status = WsOutboxStatus.failed;
                failedNow++;
              } else {
                item.status = WsOutboxStatus.pending;
                blocked++;
              }
            } else {
              item.status = WsOutboxStatus.pending;
              blocked++;
            }
            await _persist();
            // STOP. Almost always this is "the network is gone", and trying
            // the next twenty items produces twenty identical failures and
            // twenty wasted attempt counts.
            return WsDrainReport(
              posted: posted,
              failed: failedNow,
              blocked: blocked,
              stoppedOn: item,
            );
        }
      }
    } finally {
      _draining = false;
      await _prune();
    }

    return WsDrainReport(posted: posted, failed: failedNow, blocked: blocked);
  }

  // ── Retention ────────────────────────────────────────────────────────────

  /// Successful items are KEPT, so a "where did that delivery go?" question
  /// can be answered later. They are pruned by age and count, never
  /// immediately, and pending or failed items are never pruned at any age.
  Future<void> _prune() async {
    final cutoff = DateTime.now().subtract(keepSyncedFor);
    final synced = _items
        .where((e) => e.status == WsOutboxStatus.synced)
        .toList()
      ..sort((a, b) => (b.syncedAt ?? b.createdAt)
          .compareTo(a.syncedAt ?? a.createdAt));

    final drop = <String>{};
    for (var i = 0; i < synced.length; i++) {
      final it = synced[i];
      final tooOld = (it.syncedAt ?? it.createdAt).isBefore(cutoff);
      if (i >= keepSynced || tooOld) drop.add(it.clientUuid);
    }
    if (drop.isEmpty) return;
    _items.removeWhere(
        (e) => e.status == WsOutboxStatus.synced && drop.contains(e.clientUuid));
    await _persist();
  }

  /// ONE-TIME COMPATIBILITY RULE for queues written before ownership existed.
  ///
  /// Such items carry no owner. Refusing to drain them would strand real work
  /// on every device that upgrades mid-round; guessing per item would let two
  /// different users each adopt part of one queue. So: the FIRST authenticated
  /// user after the upgrade adopts ALL of them, in a single pass, and the
  /// adoption is persisted BEFORE anything drains — a crash in between must not
  /// leave half the queue unowned.
  ///
  /// Only nulls are touched. An item that already has an owner is never
  /// reassigned, no matter who is signed in.
  Future<void> _adoptLegacy(String uid) async {
    final orphans = _items.where((e) => e.authUserId == null).toList();
    if (orphans.isEmpty) return;

    for (final item in orphans) {
      item.authUserId = uid;
    }
    await _persist();
  }

  Future<void> clear() async {
    _items = [];
    _loaded = true;
    await store.clear();
    if (!_changes.isClosed) _changes.add(null);
  }

  void dispose() => _changes.close();
}

class WsDrainReport {
  final int posted;
  final int failed;
  final int blocked;
  final WsOutboxItem? stoppedOn;
  final bool skippedBusy;

  const WsDrainReport({
    this.posted = 0,
    this.failed = 0,
    this.blocked = 0,
    this.stoppedOn,
    this.skippedBusy = false,
  });

  bool get allDone => blocked == 0 && stoppedOn == null;

  @override
  String toString() => 'WsDrainReport(posted: $posted, failed: $failed, '
      'blocked: $blocked, stoppedOn: ${stoppedOn?.label})';
}
