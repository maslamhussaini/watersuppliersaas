// =============================================================================
// lib/screens/delivery_screen.dart
// =============================================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/ws_models.dart';
import '../services/location_service.dart';
import '../services/lookup_service.dart';
import '../services/store_service.dart';
import '../services/supabase_service.dart';
import '../services/outbox/ws_outbox.dart';
import '../services/outbox/ws_outbox_supabase.dart';
import '../theme/ws_theme.dart';
import '../widgets/ws_lookup_field.dart';
import 'sync_screen.dart';

class WsDeliveryScreen extends StatefulWidget {
  final WsCustomer? preselectedCustomer;
  const WsDeliveryScreen({super.key, this.preselectedCustomer});
  @override State<WsDeliveryScreen> createState() => _WsDeliveryScreenState();
}

class _WsDeliveryScreenState extends State<WsDeliveryScreen> {
  final _form       = GlobalKey<FormState>();
  final _delivered  = TextEditingController(text: '0');
  final _returned   = TextEditingController(text: '0');
  final _payment    = TextEditingController(text: '0');
  final _notes      = TextEditingController();

  List<WsInternalUser>  _staff     = <WsInternalUser>[];
  WsCustomer?           _selCustomer;
  WsInternalUser?       _selStaff;
  WsPaymentMethod       _payMethod = WsPaymentMethod.cash;
  DateTime              _date      = DateTime.now();
  bool                  _loading   = false;

  /// The idempotency key for the delivery currently being entered.
  ///
  /// STATE, NOT A LOCAL IN _save(). One user Save action gets exactly one key,
  /// and every attempt at that same delivery — queued or direct, first try or
  /// fifth — carries it.
  ///
  /// This was previously a local, which was correct for the queued path (the
  /// screen closes, so there is no second attempt) but wrong for the direct
  /// fallback: that path leaves the screen open on error, and a driver tapping
  /// Save again after a timeout minted a FRESH key. To the server a fresh key
  /// is a different delivery, so the one case the whole design exists to
  /// prevent — a lost response followed by a retry — produced two deliveries
  /// on exactly the path that had no queue to fall back on.
  ///
  /// Regenerated only after a save the user is done with, so the next delivery
  /// is a new document rather than resolving to the previous one.
  String _clientUuid = wsNewUuid();

  /// Server-resolved price for the selected customer. Null until loaded.
  double? _resolvedRate;

  int  get _deliveredInt => int.tryParse(_delivered.text) ?? 0;
  int  get _returnedInt  => int.tryParse(_returned.text)  ?? 0;
  int  get _newBalance   => (_selCustomer?.bottleBalance ?? 0) + _deliveredInt - _returnedInt;

  /// Falls back to the local estimate only while the server value is in flight.
  /// effectiveRate cannot see customer-group pricing or effective-date windows,
  /// so previewing it alone showed a figure the invoice then contradicted.
  double get _rate       => _resolvedRate ?? _selCustomer?.effectiveRate ?? 0;
  double get _charged    => _deliveredInt * _rate;

  @override void initState() {
    super.initState();
    _load();
    _delivered.addListener(() => setState(() {}));
    _returned.addListener(()  => setState(() {}));
  }

  @override
  void dispose() {
    // _delivered and _returned have listeners attached in initState. Without
    // dispose those listeners keep this State alive after the screen is gone,
    // and setState on a defunct State throws.
    _delivered.dispose();
    _returned.dispose();
    _payment.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // THE CUSTOMER LIST IS NO LONGER FETCHED HERE.
    //
    // This used to call fetchCustomers() and hold every customer in the
    // organization in memory, purely to populate a dropdown — a full table
    // download on the critical path of the app's most-used screen. The lookup
    // field queries the server as the driver types instead, so opening this
    // screen now costs one small staff query regardless of how many customers
    // exist.
    //
    // It also no longer defaults to "whichever customer sorted first", which
    // was only ever an artefact of having the list to hand.
    //
    // _staff was declared but never populated, so the "delivered by" dropdown
    // was permanently empty and every delivery was saved with a null driver.
    final staff = await WsDataService.fetchStaff();
    if (!mounted) return;
    setState(() {
      _staff       = staff;
      _selCustomer = widget.preselectedCustomer;
      _selStaff    = staff.isNotEmpty ? staff.first : null;
    });
    await _refreshRate();
  }

  /// The current selection, in the shape the picker displays.
  WsLookupResult? get _customerPick {
    final c = _selCustomer;
    if (c == null) return null;
    return WsLookupResult(
      id: c.customerId,
      label: c.customerName,
      subtitle: [
        c.customerCode ?? '',
        c.phone ?? '',
        c.areaName ?? '',
      ].where((s) => s.isNotEmpty).join(' · '),
    );
  }

  /// Loads the full record for a picked result.
  ///
  /// The lookup returns only enough to display a row; this screen needs the
  /// bottle balance and the rate, so the record is fetched before it becomes
  /// the selection. On failure the previous selection is kept rather than
  /// silently cleared.
  Future<void> _pickCustomer(WsLookupResult r) async {
    setState(() => _resolvedRate = null);
    try {
      final full = await WsDataService.fetchCustomerById(r.id);
      if (!mounted || full == null) return;
      setState(() => _selCustomer = full);
      await _refreshRate();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not load ${r.label}: $e'),
        backgroundColor: WsColors.red,
      ));
    }
  }

  Future<void> _refreshRate() async {
    final c = _selCustomer;
    if (c == null) return;
    try {
      final rate = await WsDataService.resolveDefaultRate(c.customerId, on: _date);
      if (!mounted) return;
      setState(() => _resolvedRate = rate > 0 ? rate : null);
    } catch (_) {
      // Keep the local estimate rather than blocking the driver from recording
      // a delivery; the server prices the line authoritatively either way.
    }
  }

  /// Saves the delivery and any cash collected in ONE server-side transaction.
  ///
  /// This previously inserted the delivery, then inserted the payment as a
  /// separate call. When the second call failed — offline driver, expired token,
  /// RLS rejection — the delivery had already committed. The customer was billed
  /// and the money they had just handed over existed nowhere, which is the one
  /// class of bug a delivery app must not have.
  ///
  /// ws_record_delivery also computes the bottle movements, the resolved price
  /// and the journal entries, so none of those are sent from here.
  Future<void> _save() async {
    if (!_form.currentState!.validate() || _selCustomer == null) return;
    setState(() => _loading = true);

    // Capture before the first await: using context across an async gap is
    // unsafe once the widget may have been disposed.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      final payAmt = double.tryParse(_payment.text) ?? 0;

      // ── ONE USER ACTION = ONE IDENTITY ──────────────────────────────────
      //
      // Read from state, not generated here. It already existed before this
      // Save was pressed, and it survives a failed attempt, so both the queued
      // path and the direct fallback post the SAME value on every try.
      //
      // See the field declaration for why a local was wrong.
      final clientUuid = _clientUuid;

      // The branch this document belongs to, captured alongside the key and
      // for the same reason: both must survive into the queue unchanged.
      final storeId = WsStoreService.currentStoreId;
      if (storeId == null) {
        throw StateError('No store selected — cannot record a delivery.');
      }

      // WHERE the driver is, read ONCE, here.
      //
      // Never a reason to refuse the save: a declined permission, a disabled
      // service or a timeout all leave `position` null and the delivery is
      // recorded exactly as before. From this point the coordinates live in
      // the queued payload, so a retry two hours later reports where the
      // delivery happened rather than where the van is now.
      final located = await WsLocationService.capture();
      final position = located.position;

      // ── DURABLE FIRST, THEN POST ────────────────────────────────────────
      //
      // The delivery is written to the on-device queue BEFORE any network
      // call, then posted immediately. Online, that post happens in the same
      // breath and the user sees the same "Delivery saved" as before — the
      // RPC, its arguments and its server-side behaviour are unchanged.
      //
      // What changes is only what happens when the post does NOT succeed.
      // Previously the delivery existed solely inside an in-flight HTTP
      // request: lose the connection, or have the app killed, and it was gone
      // with nothing to show for it. Now it survives on disk and syncs later.
      //
      // The clientuuid is generated HERE, at the moment of saving, and is what
      // makes the retry safe (migration 010).
      final outbox = WsOutboxService.instanceOrNull;

      if (outbox == null) {
        // Queue unavailable (init failed). Fall back to the original direct
        // path rather than refusing to record the delivery.
        await WsDataService.recordDelivery(
          customerId: _selCustomer!.customerId,
          date: _date,
          delivered: _deliveredInt,
          returned: _returnedInt,
          amountPaid: payAmt,
          paymentMethod: _payMethod.name,
          deliveredById: _selStaff?.internalUserId,
          notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          // The emergency path gets the SAME protection as the queued one.
          // Without this it was the only route in the app that could
          // double-post after a lost response.
          clientUuid: clientUuid,
          storeId: storeId,
          position: position,
        );
        // Recorded. The key is spent, so a subsequent delivery entered from
        // this screen is a new document. Reached only on success — if the call
        // above threw, the key is deliberately left alone so that tapping Save
        // again is a RETRY of this delivery, not a second one.
        _clientUuid = wsNewUuid();
        if (!mounted) return;
        messenger.showSnackBar(const SnackBar(
          content: Text('Delivery saved'),
          backgroundColor: WsColors.green,
        ));
        navigator.pop(true);
        return;
      }

      final item = await WsOutboxService.recordDelivery(
        clientUuid: clientUuid,
        position: position,
        // Read ONCE, here, at Save time. From this point the store
        // travels in the queued payload; the sync path never re-reads it.
        storeId: storeId,
        customerId: _selCustomer!.customerId,
        customerName: _selCustomer!.customerName,
        deliveryDate: _date,
        delivered: _deliveredInt,
        returned: _returnedInt,
        amountPaid: payAmt,
        paymentMethod: _payMethod.name,
        deliveredById: _selStaff?.internalUserId,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      );

      // Durably queued — the delivery now exists on disk under this key and
      // the outbox owns every retry from here. Spent, for the same reason as
      // the direct path above.
      _clientUuid = wsNewUuid();

      if (!mounted) return;

      // The message must match REALITY. A queued delivery reported as "saved"
      // in green is exactly how a driver walks away from a delivery that never
      // reached the server.
      switch (item.status) {
        case WsOutboxStatus.synced:
          messenger.showSnackBar(const SnackBar(
            content: Text('Delivery saved'),
            backgroundColor: WsColors.green,
          ));
        case WsOutboxStatus.failed:
          messenger.showSnackBar(SnackBar(
            content: Text('Saved on this device, but the server refused it: '
                '${item.lastError ?? 'unknown error'}'),
            backgroundColor: WsColors.red,
            duration: const Duration(seconds: 6),
          ));
        case WsOutboxStatus.pending:
        case WsOutboxStatus.syncing:
          messenger.showSnackBar(SnackBar(
            content: const Text('Saved on this device — waiting to sync'),
            backgroundColor: WsColors.amber,
            action: SnackBarAction(
              label: 'View',
              textColor: Colors.white,
              onPressed: () => navigator.push(MaterialPageRoute(
                  builder: (_) => const WsSyncScreen())),
            ),
          ));
      }
      navigator.pop(true);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: WsColors.red),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
        title: const Text('Record Delivery'),
    ),
    body: Form(
      key: _form,
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 40), children: [
        // ── Customer & Date ──────────────────────────────────────────────
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          const Text('Customer & Date', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          const Text('Customer', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          // Searchable, and bounded on the server. The dropdown this replaces
          // held every customer in the organization in memory — fine at twelve,
          // unusable at four thousand, which is what a CSV import produces.
          //
          // The SELECTION is still a full WsCustomer, because the bottle
          // balance preview and the resolved rate below need one. Picking a
          // result fetches that record; nothing downstream changed.
          WsLookupField(
            label: 'Customer',
            icon: Icons.person_search_outlined,
            value: _customerPick,
            search: WsLookupService.customers,
            onSelected: _pickCustomer,
          ),
          const SizedBox(height: 16),
          const Text('Date', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          InkWell(
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(2020),
                lastDate: DateTime.now(),
              );
              if (d != null) setState(() => _date = d);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(DateFormat('dd/MM/yyyy').format(_date), style: const TextStyle(fontSize: 16)),
                  const Icon(Icons.calendar_today, size: 20, color: WsColors.text2),
                ],
              ),
            ),
          ),
          // Need to add Delivered By since it's in the screenshot
          const SizedBox(height: 16),
          const Text('Delivered By', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          // Was hardcoded to a placeholder name with an empty onChanged, so the
          // driver on every delivery record was whoever the mock said it was.
          DropdownButtonFormField<WsInternalUser>(
            initialValue: _selStaff,
            decoration: InputDecoration(
              hintText: _staff.isEmpty ? 'No staff configured' : 'Select staff',
            ),
            items: _staff
                .map((u) => DropdownMenuItem(value: u, child: Text(u.fullName)))
                .toList(),
            onChanged: _staff.isEmpty
                ? null
                : (u) => setState(() => _selStaff = u),
          ),
        ]))),

        // ── Bottle Movement ───────────────────────────────────────────────
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          const Text('Bottle Movement', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 16),
          const Text('🚛 Bottles Delivered (Full → Customer)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          TextFormField(
            controller: _delivered,
            decoration: const InputDecoration(hintText: '0'),
            keyboardType: TextInputType.number,
            validator: (v) => int.tryParse(v ?? '') == null ? 'Enter a number' : null,
          ),
          const SizedBox(height: 16),
          const Text('📦 Bottles Returned (Empty ← Customer)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WsColors.text2)),
          const SizedBox(height: 6),
          TextFormField(
            controller: _returned,
            decoration: const InputDecoration(hintText: '0'),
            keyboardType: TextInputType.number,
            validator: (v) => int.tryParse(v ?? '') == null ? 'Enter a number' : null,
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFE1F5FE),
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Bottle Balance (auto)', style: TextStyle(color: WsColors.primaryDark, fontSize: 13, fontWeight: FontWeight.w500)),
                Text('${_selCustomer?.bottleBalance ?? 0} → $_newBalance',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: WsColors.primaryDark, fontSize: 16)),
              ]),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Amount Charged (auto)', style: TextStyle(color: WsColors.primaryDark, fontSize: 13, fontWeight: FontWeight.w500)),
                Text('Rs ${NumberFormat('#,##0').format(_charged)}',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: WsColors.primaryDark, fontSize: 16)),
              ]),
            ]),
          ),
        ]))),

        // ── Optional Payment ──────────────────────────────────────────────
        Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Payment (optional)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _payment,
              decoration: const InputDecoration(
                  labelText: 'Amount Received', prefixText: 'Rs '),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<WsPaymentMethod>(
              initialValue: _payMethod,
              decoration: const InputDecoration(labelText: 'Payment Method'),
              items: WsPaymentMethod.values.map((m) => DropdownMenuItem(
                  value: m, child: Text('${m.emoji} ${m.label}'))).toList(),
              onChanged: (m) => setState(() => _payMethod = m!),
            ),
          ],
        ))),

        // ── Notes ─────────────────────────────────────────────────────────
        Card(child: Padding(padding: const EdgeInsets.all(14), child:
          TextFormField(
            controller: _notes,
            decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                prefixIcon: Icon(Icons.note_outlined)),
            maxLines: 2,
          ),
        )),

        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _loading ? null : _save,
          child: _loading
              ? const SizedBox(height: 20, width: 20,
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('Save Delivery ✓'),
        ),
      ]),
    ),
  );
}

