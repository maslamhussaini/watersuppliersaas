// =============================================================================
// test/support/fake_csv_import_ops.dart
// A CSV-import ops double that MODELS STATE, not one that records calls.
//
// The distinction matters for exactly one reason. The behaviour worth testing
// here is the lost response: the server committed, and the client never heard
// about it. A double that throws BEFORE recording the write models something
// else entirely — a server that rejected — and the two leave completely
// different databases behind. So every failure mode below commits first and
// throws second, and the caller chooses which it wants.
//
// It also has to be idempotent on clientuuid the way ws_record_customer is
// (migration 014), because a replay returning the existing id is the whole
// mechanism that makes a partial import resumable.
// =============================================================================

import 'package:watersuppliersaas/services/import/ws_csv_import_ops.dart';

/// A row as this fake stores it.
class FakeCustomer {
  int customerId;
  String name;
  String? clientUuid;
  int? storeId;
  Map<String, dynamic> fields;
  num openingDue;
  num openingQty;

  FakeCustomer({
    required this.customerId,
    required this.name,
    this.clientUuid,
    this.storeId,
    Map<String, dynamic>? fields,
    this.openingDue = 0,
    this.openingQty = 0,
  }) : fields = fields ?? <String, dynamic>{};
}

/// Stands in for a PostgrestException without importing one. The applier
/// stringifies whatever it catches, so only the message shape matters.
class FakeDbException implements Exception {
  final String code;
  final String message;
  const FakeDbException(this.code, this.message);
  @override
  String toString() => 'FakeDbException($code): $message';
}

class FakeCsvImportOps implements WsCsvImportOps {
  FakeCsvImportOps({this.maxActiveCustomers});

  /// Committed state.
  final Map<int, FakeCustomer> customers = {};

  /// Every operation, in order, for assertions about what was attempted.
  final List<String> calls = [];

  int _nextId = 500;

  /// Set to model migration 019's cap. null = unlimited.
  int? maxActiveCustomers;

  // ── failure injection ─────────────────────────────────────────────────────
  //
  // Two families, and the difference is the point of this file:
  //   throwBefore*  the write never happened      (server rejected)
  //   loseAfter*    the write DID happen          (response lost)

  /// Names for which recordCustomer throws without writing.
  final Set<String> throwBeforeRecord = {};

  /// Names for which recordCustomer commits, then throws.
  final Set<String> loseAfterRecord = {};

  /// Customer names for which setCustomerOpening throws without writing.
  final Set<String> throwBeforeOpening = {};

  /// Customer names for which setCustomerOpening commits, then throws.
  final Set<String> loseAfterOpening = {};

  FakeCustomer? byName(String n) {
    for (final c in customers.values) {
      if (c.name == n) return c;
    }
    return null;
  }

  FakeCustomer? byClientUuid(String u) {
    for (final c in customers.values) {
      if (c.clientUuid == u) return c;
    }
    return null;
  }

  int get activeCount => customers.length;

  @override
  Future<int> recordCustomer({
    required int orgId,
    required String name,
    required String clientUuid,
    required int? storeId,
    required Map<String, dynamic> values,
  }) async {
    calls.add('record:$name');

    // IDEMPOTENCY FIRST, exactly like ws_record_customer (014:105-114): the
    // replay returns before any insert, which is also why the plan-limit
    // trigger is not consulted on a retry.
    final existing = byClientUuid(clientUuid);
    if (existing != null) {
      calls.add('record:$name:replay->${existing.customerId}');
      return existing.customerId;
    }

    if (throwBeforeRecord.contains(name)) {
      throw const FakeDbException('XXTEST', 'record refused before writing');
    }

    // The cap, checked where the trigger checks it: after the replay
    // short-circuit, before the insert.
    if (maxActiveCustomers != null && activeCount >= maxActiveCustomers!) {
      throw FakeDbException(
          'P0001',
          'plan limit reached: the free plan allows $maxActiveCustomers '
              'active customers (currently $activeCount)');
    }

    final id = ++_nextId;
    customers[id] = FakeCustomer(
      customerId: id,
      name: name,
      clientUuid: clientUuid,
      storeId: storeId,
      fields: {
        'areaid': values['areaid'],
        'phone': values['phone'],
        'address': values['address'],
        'deposit': values['deposit'] ?? 0,
      },
    );

    if (loseAfterRecord.contains(name)) {
      // COMMITTED, then the caller never hears back.
      throw const FakeDbException('XXLOST', 'connection dropped after commit');
    }
    return id;
  }

  @override
  Future<void> updateCustomer({
    required int orgId,
    required int customerId,
    required Map<String, dynamic> patch,
  }) async {
    final c = customers[customerId];
    calls.add('update:${c?.name ?? customerId}:${patch.keys.join(",")}');
    if (c == null) {
      throw const FakeDbException('P0002', 'customer not found');
    }
    c.fields.addAll(patch);
  }

  @override
  Future<void> setCustomerOpening({
    required int customerId,
    required Object? openingDue,
    required Object? openingQty,
  }) async {
    final c = customers[customerId];
    calls.add('opening:${c?.name ?? customerId}:$openingDue/$openingQty');
    if (c == null) {
      throw const FakeDbException('P0002', 'customer not found');
    }

    if (throwBeforeOpening.contains(c.name)) {
      throw const FakeDbException('XXTEST', 'opening refused before writing');
    }

    // CONVERGENT, like ws_set_customer_opening (017): an absolute target, not
    // an increment, so repeating it cannot double-apply.
    c.openingDue = (openingDue as num?) ?? 0;
    c.openingQty = ((openingQty as num?) ?? 0).toInt();

    if (loseAfterOpening.contains(c.name)) {
      throw const FakeDbException('XXLOST', 'connection dropped after commit');
    }
  }

  /// The deps bundle apply() takes.
  WsCsvImportDeps deps({int orgId = 1, int? storeId = 9}) => WsCsvImportDeps(
        ops: this,
        isConnected: () => true,
        currentOrgId: () async => orgId,
        currentStoreId: () => storeId,
      );
}
