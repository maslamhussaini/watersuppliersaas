// =============================================================================
// lib/screens/store_picker.dart
// Choosing which branch you are working in.
//
// ─── IT HIDES ITSELF ─────────────────────────────────────────────────────────
//
// A business with one shop must never see this. WsStoreService.isMultiStore is
// false for them and the widget renders nothing at all — no empty dropdown, no
// "Main Store" label taking up the app bar. Multi-branch is a feature you opt
// into by creating a second branch, not a tax on everyone else.
//
// ─── AND IT DOES NOT DECIDE WHAT YOU CAN SEE ─────────────────────────────────
//
// The list comes from ws_my_stores(), which applies ws.can_access_store()
// server-side. Nothing here filters anything; it selects which store NEW
// documents are stamped with. A user who is not permitted a branch cannot read
// or write it whatever this widget is showing.
// =============================================================================

import 'package:flutter/material.dart';

import '../services/store_service.dart';
import '../theme/ws_theme.dart';

/// A compact branch selector for an AppBar.
class WsStorePicker extends StatefulWidget {
  /// Called after the branch changes, so the screen can reload its lists.
  final VoidCallback? onChanged;

  const WsStorePicker({super.key, this.onChanged});

  @override
  State<WsStorePicker> createState() => _WsStorePickerState();
}

class _WsStorePickerState extends State<WsStorePicker> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await WsStoreService.load();
    } catch (_) {
      // A branch list that cannot be fetched must not block the screen behind
      // it. The picker stays hidden and every document lands in the
      // organization's default store, which is the pre-015 behaviour.
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || !WsStoreService.isMultiStore) {
      return const SizedBox.shrink();
    }

    final current = WsStoreService.currentStore;

    return PopupMenuButton<int>(
      tooltip: 'Switch branch',
      onSelected: (id) {
        if (WsStoreService.select(id)) {
          setState(() {});
          widget.onChanged?.call();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Now working in '
                '${WsStoreService.currentStore?.storeName ?? 'this branch'}'),
            duration: const Duration(seconds: 2),
          ));
        }
      },
      itemBuilder: (_) => [
        for (final s in WsStoreService.stores)
          PopupMenuItem<int>(
            value: s.storeId,
            child: Row(children: [
              Icon(
                s.storeId == WsStoreService.currentStoreId
                    ? Icons.check_circle
                    : Icons.storefront_outlined,
                size: 18,
                color: s.storeId == WsStoreService.currentStoreId
                    ? WsColors.primary
                    : WsColors.text2,
              ),
              const SizedBox(width: 10),
              Flexible(child: Text(s.storeName)),
            ]),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.storefront_outlined, size: 18, color: Colors.white),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              current?.storeName ?? 'Branch',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
          const Icon(Icons.arrow_drop_down, color: Colors.white),
        ]),
      ),
    );
  }
}
