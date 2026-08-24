// =============================================================================
// lib/widgets/ws_lookup_field.dart
// A form field that finds one record out of thousands.
//
// Replaces the dropdown that loaded every customer into memory. The search
// function is injected, so this widget knows nothing about Supabase and can be
// driven by a fake in tests.
//
// ─── THE SELECTED VALUE IS SACRED ────────────────────────────────────────────
//
// A form opened on an existing delivery already has a customer, and that
// customer will usually not be in the results of whatever gets typed next. The
// selection is therefore held separately from the result list and survives
// every search, every empty result and every dismissal of the sheet. Only
// picking a different record replaces it.
//
// Getting this wrong is quiet and expensive: the user edits a note, the picker
// silently loses the customer, and the record saves against somebody else.
// =============================================================================

import 'package:flutter/material.dart';

import '../services/lookup_service.dart';
import '../theme/ws_theme.dart';

typedef WsLookupSearch = Future<List<WsLookupResult>> Function(String query);

class WsLookupField extends StatelessWidget {
  final String label;
  final IconData icon;

  /// What is selected right now. Null shows the placeholder.
  final WsLookupResult? value;

  final WsLookupSearch search;
  final ValueChanged<WsLookupResult> onSelected;

  /// Shown under the field, e.g. "12 bottles out · Rs 300 due".
  final String? helper;
  final String? errorText;
  final bool enabled;

  /// Overridable so tests can drive the debounce without waiting 300ms.
  final Duration debounce;

  const WsLookupField({
    super.key,
    required this.label,
    required this.value,
    required this.search,
    required this.onSelected,
    this.icon = Icons.search,
    this.helper,
    this.errorText,
    this.enabled = true,
    this.debounce = const Duration(milliseconds: 300),
  });

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<WsLookupResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _WsLookupSheet(
        title: label,
        search: search,
        selected: value,
        debounce: debounce,
      ),
    );
    // A dismissed sheet returns null and MUST NOT clear the selection.
    if (picked != null) onSelected(picked);
  }

  @override
  Widget build(BuildContext context) {
    final v = value;
    return InkWell(
      onTap: enabled ? () => _open(context) : null,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          errorText: errorText,
          border: const OutlineInputBorder(),
          prefixIcon: Icon(icon),
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        isEmpty: v == null,
        child: v == null
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(v.label,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (v.subtitle.isNotEmpty)
                    Text(v.subtitle,
                        style: const TextStyle(
                            fontSize: 11.5, color: WsColors.text2),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                ],
              ),
      ),
    );
  }
}

// ─── The sheet ────────────────────────────────────────────────────────────────

class _WsLookupSheet extends StatefulWidget {
  final String title;
  final WsLookupSearch search;
  final WsLookupResult? selected;
  final Duration debounce;

  const _WsLookupSheet({
    required this.title,
    required this.search,
    required this.selected,
    required this.debounce,
  });

  @override
  State<_WsLookupSheet> createState() => _WsLookupSheetState();
}

class _WsLookupSheetState extends State<_WsLookupSheet> {
  final _controller = TextEditingController();
  late final WsSearchDebouncer _debouncer =
      WsSearchDebouncer(delay: widget.debounce);

  List<WsLookupResult> _results = const [];
  bool _searching = false;
  bool _searched = false;
  String? _error;

  @override
  void dispose() {
    _debouncer.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    // An empty or one-character box must not query. The old dropdown's
    // equivalent was loading the whole table before the user typed anything.
    if (!wsSearchable(raw)) {
      _debouncer.cancel();
      setState(() {
        _results = const [];
        _searching = false;
        _searched = false;
        _error = null;
      });
      return;
    }

    setState(() {
      _searching = true;
      _error = null;
    });

    _debouncer.run<List<WsLookupResult>>(
      () => widget.search(raw),
      (results) {
        if (!mounted) return;
        setState(() {
          _results = results;
          _searching = false;
          _searched = true;
        });
      },
      onError: (e) {
        if (!mounted) return;
        setState(() {
          _searching = false;
          _searched = true;
          _error = '$e';
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
              color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(widget.title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          decoration: InputDecoration(
            hintText: 'Search by name, phone or code…',
            prefixIcon: const Icon(Icons.search),
            border: const OutlineInputBorder(),
            suffixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : null,
          ),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.45),
          child: _body(),
        ),
      ]),
    );
  }

  Widget _body() {
    if (_error != null) {
      return _hint(Icons.error_outline, _error!, WsColors.red);
    }
    if (!_searched && !_searching) {
      return _hint(Icons.keyboard_outlined,
          'Type at least $wsLookupMinChars characters to search.');
    }
    if (_searching && _results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_results.isEmpty) {
      return _hint(Icons.search_off, 'Nothing matched that.');
    }

    return ListView.separated(
      shrinkWrap: true,
      itemCount: _results.length +
          (_results.length >= wsLookupLimit ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        // A full page of results almost certainly means there are more, and
        // saying so is better than letting someone conclude their customer is
        // missing.
        if (i == _results.length) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Showing the first $wsLookupLimit matches — keep typing to narrow '
              'them down.',
              style: TextStyle(fontSize: 12, color: WsColors.text2),
            ),
          );
        }

        final r = _results[i];
        final isSelected = widget.selected?.id == r.id;
        return ListTile(
          dense: true,
          leading: Icon(
            isSelected ? Icons.check_circle : Icons.person_outline,
            color: isSelected ? WsColors.primary : WsColors.text2,
          ),
          title: Text(r.label),
          subtitle: r.subtitle.isEmpty ? null : Text(r.subtitle),
          onTap: () => Navigator.pop(context, r),
        );
      },
    );
  }

  Widget _hint(IconData icon, String text, [Color colour = WsColors.text2]) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: colour, size: 30),
          const SizedBox(height: 8),
          Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(color: colour, fontSize: 13)),
        ]),
      );
}
