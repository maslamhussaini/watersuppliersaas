// =============================================================================
// lib/screens/ws_crud.dart
// One list-and-form engine, reused by every master-data screen.
//
// WHY A GENERIC SCAFFOLD RATHER THAN NINE SCREENS
// Products, bottle types, prices, vendors, routes, groups, staff, purchases and
// vendor payments are the same interaction nine times: list rows, open a form,
// validate, save, deactivate. Written nine times that is nine places to repeat
// the orgid handling and nine chances to repeat the insert-vs-update bug that
// silently duplicated customer rows. Written once it is one place to fix.
//
// Responsive by construction: the list is a single column on a phone and a
// centred, width-capped column on a desktop, because a table row two metres
// wide is not more readable. Forms open as a bottom sheet on mobile and a
// dialog on wider screens, which is the platform convention on each.
// =============================================================================

import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../theme/ws_responsive.dart';
import '../services/lookup_service.dart';
import '../theme/ws_theme.dart';
import '../widgets/ws_lookup_field.dart';

// ─── Field description ────────────────────────────────────────────────────────

enum WsFieldType {
  text,
  number,
  money,
  integer,
  dropdown,
  toggle,
  date,
  multiline,

  /// A searchable picker instead of a dropdown, for anything that can grow
  /// past a screenful. Stores exactly what dropdown stores — the id — so a
  /// field converted from one to the other saves an identical payload.
  lookup,
}

class WsField {
  final String column;
  final String label;
  final WsFieldType type;
  final bool required;
  final String? hint;
  final String? helper;
  final Object? initial;

  /// For [WsFieldType.dropdown]: [{'id': .., 'label': ..}]
  final Future<List<Map<String, dynamic>>> Function()? options;

  /// For [WsFieldType.lookup]: the bounded server search.
  ///
  /// Unlike [options] this is never called to populate the form — only when
  /// the user types. That is the whole point: a dropdown must load everything
  /// before it can be opened, and a lookup loads nothing until asked.
  final WsLookupSearch? search;

  /// For [WsFieldType.lookup]: resolves the stored id back to something
  /// displayable when EDITING an existing record.
  ///
  /// Without it a form opened on an existing purchase would show an empty
  /// vendor field over a perfectly good vendorid, and inviting the user to
  /// "fix" it would silently repoint the document.
  final Future<WsLookupResult?> Function(int id)? resolve;

  /// Fields sharing a group name are MUTUALLY EXCLUSIVE: choosing a value in
  /// one clears the others.
  ///
  /// Product prices are the case this exists for. The schema allows at most one
  /// scope per row (ck_price_single_scope) but the form offered customer, group
  /// and area as three independent dropdowns, so filling two was not just
  /// possible, it was the obvious thing to do — and the only feedback was a
  /// constraint name after a round trip to the server. Enforcing it at
  /// selection time makes the invalid row unrepresentable instead of merely
  /// rejected.
  final String? exclusiveGroup;

  const WsField(
    this.column,
    this.label, {
    this.type = WsFieldType.text,
    this.required = false,
    this.hint,
    this.helper,
    this.initial,
    this.options,
    this.search,
    this.resolve,
    this.exclusiveGroup,
  });
}

// ─── Row rendering ────────────────────────────────────────────────────────────

class WsRowView {
  final String title;
  final String? subtitle;
  final String? trailing;
  final Color? trailingColor;

  const WsRowView({
    required this.title,
    this.subtitle,
    this.trailing,
    this.trailingColor,
  });
}

// ─── The screen ───────────────────────────────────────────────────────────────

class WsCrudScreen extends StatefulWidget {
  final String title;
  final String emptyHint;
  final IconData icon;

  /// Permission code required to add, edit or deactivate. Reads stay open to
  /// anyone who can reach the screen; RLS is the real gate either way.
  final String writePermission;

  final Future<List<Map<String, dynamic>>> Function() load;
  final WsRowView Function(Map<String, dynamic> row) rowBuilder;

  /// Some screens can edit but not create — Staff, where the account itself is
  /// made in Supabase Auth. Showing an Add button there offers an action whose
  /// only possible outcome is an error.
  final bool canCreate;

  /// Null means this screen is read-only (a document log, not master data).
  final List<WsField>? fields;
  final Future<void> Function(Object? pk, Map<String, dynamic> values)? onSave;
  final String? pkColumn;
  final Future<void> Function(Object pk)? onDeactivate;

  const WsCrudScreen({
    super.key,
    required this.title,
    required this.icon,
    required this.load,
    required this.rowBuilder,
    this.writePermission = 'org.manage',
    this.emptyHint = 'Nothing here yet.',
    this.canCreate = true,
    this.fields,
    this.onSave,
    this.pkColumn,
    this.onDeactivate,
  });

  @override
  State<WsCrudScreen> createState() => _WsCrudScreenState();
}

class _WsCrudScreenState extends State<WsCrudScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  // OrderMate puts a search field at the top of every list screen. Here it
  // lives in the shared engine, so all eleven master-data screens get it from
  // one place rather than eleven copies drifting apart — which is exactly what
  // happened in OrderMate, where each list re-declared the same decoration.
  final TextEditingController _search = TextEditingController();
  String _query = '';

  bool get _canWrite =>
      widget.fields != null &&
      widget.onSave != null &&
      AuthService.permissions.has(widget.writePermission);

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Filters on what the row DISPLAYS, not on the raw record.
  ///
  /// Searching the underlying map would match ids, orgids and timestamps the
  /// user cannot see — typing "3" would hit half the table for reasons nobody
  /// could explain. rowBuilder is the same text that is on screen.
  List<Map<String, dynamic>> _filter(List<Map<String, dynamic>> rows) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return rows;
    return rows.where((r) {
      final v = widget.rowBuilder(r);
      return '${v.title} ${v.subtitle ?? ''} ${v.trailing ?? ''}'
          .toLowerCase()
          .contains(q);
    }).toList();
  }

  void _reload() {
    // NOT `setState(() => _future = widget.load())`.
    //
    // An arrow body returns the value of its expression, and the value of an
    // assignment is the thing assigned — here a Future. Flutter rejects that
    // outright ("setState() callback argument returned a Future") because a
    // callback it cannot await usually means someone is doing async work inside
    // setState. The fix is a block body, which returns void.
    //
    // The load is also started BEFORE setState rather than inside it, so the
    // callback does nothing but assign.
    final next = widget.load();
    if (!mounted) return;
    setState(() {
      _future = next;
    });
  }

  Future<void> _openForm([Map<String, dynamic>? row]) async {
    final fields = widget.fields;
    final onSave = widget.onSave;
    if (fields == null || onSave == null) return;

    final pk = row == null || widget.pkColumn == null
        ? null
        : row[widget.pkColumn!];

    final saved = await _showForm(
      context: context,
      title: pk == null ? 'New ${widget.title}' : 'Edit ${widget.title}',
      fields: fields,
      initial: row,
      onSave: (values) => onSave(pk, values),
    );

    if (saved == true && mounted) _reload();
  }

  Future<void> _deactivate(Map<String, dynamic> row) async {
    final pkCol = widget.pkColumn;
    final onDeactivate = widget.onDeactivate;
    if (pkCol == null || onDeactivate == null) return;

    final view = widget.rowBuilder(row);
    final messenger = ScaffoldMessenger.of(context);

    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove?'),
        // "Deactivate", not "delete". Nothing here is hard-deleted: a product
        // with deliveries against it must keep existing or old documents lose
        // their line items.
        content: Text(
          '${view.title} will be hidden from lists.\n\n'
          'Existing records that reference it are kept intact.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: WsColors.red)),
          ),
        ],
      ),
    );

    if (yes != true) return;
    try {
      await onDeactivate(row[pkCol] as Object);
      if (!mounted) return;
      _reload();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: WsColors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        flexibleSpace: const WsGradientBar(),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
          // OrderMate pairs the FAB with a text "New" action in the bar.
          if (_canWrite && widget.canCreate)
            TextButton.icon(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.add, color: Colors.white, size: 18),
              label: const Text('New', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      floatingActionButton: (_canWrite && widget.canCreate)
          ? FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            )
          : null,
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _centered(
              Icons.error_outline,
              WsColors.red,
              'Could not load',
              '${snap.error}',
              onRetry: _reload,
            );
          }

          final all = snap.data ?? const <Map<String, dynamic>>[];

          // Nothing at all — a different situation from "your search matched
          // nothing", and it calls for different advice.
          if (all.isEmpty) {
            return _centered(
              widget.icon,
              WsColors.text3,
              'Nothing yet',
              widget.emptyHint,
            );
          }

          final rows = _filter(all);

          return Column(children: [
            WsMaxWidth(
              maxWidth: 760,
              child: WsSearchField(
                controller: _search,
                hint: 'Search ${widget.title.toLowerCase()}s…',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (rows.isEmpty)
              Expanded(
                child: WsEmptyState(
                  icon: Icons.search_off,
                  message: 'No ${widget.title.toLowerCase()} matches '
                      '"${_query.trim()}".',
                  hint: '${all.length} record'
                      '${all.length == 1 ? '' : 's'} in total.',
                ),
              )
            else
              Expanded(
                child: WsMaxWidth(
            maxWidth: 760,
            child: ListView.separated(
              padding: WsBreakpoints.pagePadding(context)
                  .add(const EdgeInsets.only(bottom: 88)),
              itemCount: rows.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final row = rows[i];
                final view = widget.rowBuilder(row);
                return Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    // OrderMate's list rows lead with a tinted circle holding
                    // the first letter. Cheap, and it gives a long list a
                    // scannable left edge.
                    leading: CircleAvatar(
                      backgroundColor: WsColors.primarySurface,
                      child: Text(
                        view.title.isEmpty
                            ? '?'
                            : view.title.characters.first.toUpperCase(),
                        style: const TextStyle(
                          color: WsColors.primaryDark,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    // Only editable when there is a primary key to update.
                    // Without this, tapping a Purchase row opened a prefilled
                    // form whose Save inserted a duplicate document — complete
                    // with a second journal entry and a second set of bottle
                    // movements.
                    onTap: (_canWrite && widget.pkColumn != null)
                        ? () => _openForm(row)
                        : null,
                    title: Text(
                      view.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: view.subtitle == null
                        ? null
                        : Text(
                            view.subtitle!,
                            style: const TextStyle(fontSize: 12),
                          ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (view.trailing != null)
                          Text(
                            view.trailing!,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: view.trailingColor ?? WsColors.text2,
                            ),
                          ),
                        if (_canWrite && widget.onDeactivate != null)
                          IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: WsColors.text3,
                            ),
                            onPressed: () => _deactivate(row),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
                ),
              ),
          ]);
        },
      ),
    );
  }

  Widget _centered(
    IconData icon,
    Color color,
    String title,
    String body, {
    VoidCallback? onRetry,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: color),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(color: WsColors.text2, fontSize: 13),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ],
      ),
    ),
  );
}

// ─── Form presentation ────────────────────────────────────────────────────────

/// Bottom sheet on a phone, dialog on tablet and desktop.
Future<bool?> _showForm({
  required BuildContext context,
  required String title,
  required List<WsField> fields,
  required Map<String, dynamic>? initial,
  required Future<void> Function(Map<String, dynamic> values) onSave,
}) {
  final form = WsCrudForm(
    title: title,
    fields: fields,
    initial: initial,
    onSave: onSave,
  );

  if (WsBreakpoints.isMobile(context)) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => form,
    );
  }
  return showDialog<bool>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: form,
      ),
    ),
  );
}

/// The form itself, public so it can be driven directly by a widget test.
///
/// Renamed from a private class for exactly that reason — no behaviour was
/// changed. Screens still reach it through _showForm(); this is the seam a
/// test needs to prove that a lookup field hands onSave the same payload a
/// dropdown did.
class WsCrudForm extends StatefulWidget {
  final String title;
  final List<WsField> fields;
  final Map<String, dynamic>? initial;
  final Future<void> Function(Map<String, dynamic> values) onSave;

  const WsCrudForm({
    super.key,
    required this.title,
    required this.fields,
    required this.initial,
    required this.onSave,
  });

  @override
  State<WsCrudForm> createState() => WsCrudFormState();
}

class WsCrudFormState extends State<WsCrudForm> {
  final _key = GlobalKey<FormState>();
  final Map<String, TextEditingController> _text = {};
  final Map<String, Object?> _values = {};
  final Map<String, List<Map<String, dynamic>>> _options = {};

  /// Display labels for lookup fields. The VALUE still lives in _values; this
  /// only carries what to show, so the saved payload is unaffected by it.
  final Map<String, WsLookupResult?> _picked = {};
  bool _saving = false;
  bool _loadingOptions = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      final v = widget.initial?[f.column] ?? f.initial;
      // if/else rather than a switch: no dependence on whether this Dart
      // version wants `break` in a non-empty case body.
      if (f.type == WsFieldType.dropdown ||
          f.type == WsFieldType.lookup ||
          f.type == WsFieldType.toggle ||
          f.type == WsFieldType.date) {
        _values[f.column] = v;
      } else {
        _text[f.column] = TextEditingController(text: v?.toString() ?? '');
      }
    }
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    for (final f in widget.fields) {
      if (f.options != null) {
        try {
          _options[f.column] = await f.options!();
        } catch (_) {
          _options[f.column] = const [];
        }
      }

      // A lookup loads NOTHING up front except the label for a value that is
      // already set — the difference between opening a form and downloading a
      // table.
      if (f.type == WsFieldType.lookup && f.resolve != null) {
        final id = _values[f.column];
        if (id is int) {
          WsLookupResult? resolved;
          try {
            resolved = await f.resolve!(id);
          } catch (_) {
            resolved = null;
          }
          // NOT FOUND AND FAILED TO LOAD ARE THE SAME PROBLEM here: the record
          // holds a real id that cannot be named right now. Showing "#id" says
          // a value is set without pretending to know what it is — an empty
          // field would invite the user to pick something else and silently
          // repoint the document.
          _picked[f.column] = resolved ?? WsLookupResult(id: id, label: '#$id');
        }
      }
    }
    if (mounted) setState(() => _loadingOptions = false);
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_key.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    final out = <String, dynamic>{};
    for (final f in widget.fields) {
      if (f.type == WsFieldType.dropdown ||
          f.type == WsFieldType.lookup ||
          f.type == WsFieldType.toggle) {
        // A lookup stores the id and nothing else, so the payload handed to
        // onSave is byte-identical to what the dropdown produced.
        out[f.column] = _values[f.column];
      } else if (f.type == WsFieldType.date) {
        final d = _values[f.column] as DateTime?;
        out[f.column] =
            (d ?? DateTime.now()).toIso8601String().split('T').first;
      } else {
        final t = _text[f.column]!.text.trim();
        if (f.type == WsFieldType.number || f.type == WsFieldType.money) {
          out[f.column] = t.isEmpty ? null : double.tryParse(t);
        } else if (f.type == WsFieldType.integer) {
          out[f.column] = t.isEmpty ? null : int.tryParse(t);
        } else {
          out[f.column] = t.isEmpty ? null : t;
        }
      }
    }

    final navigator = Navigator.of(context);
    try {
      await widget.onSave(out);
      if (!mounted) return;
      navigator.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _explain(e);
      });
    }
  }

  /// Postgres constraint names are precise and mean nothing to the person
  /// filling in the form. "violates check constraint ck_price_single_scope"
  /// tells them a rule exists; it does not tell them which of the five fields
  /// on screen to change.
  ///
  /// These are the database's rules, not the UI's, so a rule not in this map
  /// still surfaces — just in its raw form. The map is a courtesy, never a
  /// substitute for the constraint.
  static String _explain(Object e) {
    final raw = '$e';

    const known = <String, String>{
      'ck_price_single_scope':
          'A price applies to ONE scope only. Choose a customer, OR a group, '
              'OR an area — or leave all three empty for the organization '
              'default.',
      'ck_product_bottle_consistency':
          'A product either names a product type and moves at least one unit '
              'per unit, or names neither. Set both, or clear both.',
      'ck_price_date_order':
          '"Effective to" must be on or after "effective from".',
    };
    for (final entry in known.entries) {
      if (raw.contains(entry.key)) return entry.value;
    }

    if (raw.contains('duplicate key') || raw.contains('23505')) {
      return 'That code or name is already used by another record here.';
    }
    if (raw.contains('violates foreign key')) {
      return 'One of the selected records no longer exists. Refresh and try '
          'again.';
    }
    if (raw.contains('violates row-level security') ||
        raw.contains('42501')) {
      return 'You do not have permission to do that.';
    }

    return raw
        .replaceFirst('PostgrestException(message: ', '')
        .replaceFirst('Exception: ', '');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _key,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              if (_loadingOptions)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                ...widget.fields.map(_buildField),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: WsColors.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: WsColors.red, fontSize: 12),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: (_saving || _loadingOptions) ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(WsField f) {
    Widget child;

    switch (f.type) {
      case WsFieldType.dropdown:
        final opts = _options[f.column] ?? const [];
        final selected = opts.any((o) => o['id'] == _values[f.column])
            ? _values[f.column]
            : null;
        child = DropdownButtonFormField<Object?>(
          // The key carries the current value, so clearing this field from
          // another field's onChanged rebuilds the FormField with the new
          // value rather than keeping the stale one on screen. FormField
          // treats initialValue as initial, not as a live binding.
          key: ValueKey('${f.column}::$selected'),
          initialValue: selected,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: f.label + (f.required ? ' *' : ''),
            helperText: opts.isEmpty
                ? 'None configured yet — add one first'
                : f.helper,
          ),
          items: [
            // Optional dropdowns need a way back to empty. Without this there
            // was no way to undo a selection short of cancelling the form.
            if (!f.required)
              const DropdownMenuItem<Object?>(
                value: null,
                child: Text(
                  '— none —',
                  style: TextStyle(color: WsColors.text3),
                ),
              ),
            ...opts.map(
              (o) => DropdownMenuItem<Object?>(
                value: o['id'],
                child: Text('${o['label']}', overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
          onChanged: (v) => setState(() {
            _values[f.column] = v;
            // Choosing a scope clears the competing ones. See
            // WsField.exclusiveGroup.
            if (v != null && f.exclusiveGroup != null) {
              for (final other in widget.fields) {
                if (other.column != f.column &&
                    other.exclusiveGroup == f.exclusiveGroup) {
                  _values[other.column] = null;
                }
              }
            }
          }),
          validator: (v) =>
              (f.required && v == null) ? 'Select ${f.label}' : null,
        );

      case WsFieldType.lookup:
        // Wrapped in a FormField so `required` participates in the same
        // validate() gate as every other field — WsLookupField is a plain
        // widget and would otherwise be invisible to the form.
        child = FormField<Object?>(
          key: ValueKey('${f.column}::${_values[f.column]}'),
          initialValue: _values[f.column],
          validator: (v) =>
              (f.required && v == null) ? 'Select ${f.label}' : null,
          builder: (state) => WsLookupField(
            label: f.label + (f.required ? ' *' : ''),
            icon: Icons.search,
            helper: f.helper,
            errorText: state.errorText,
            value: _picked[f.column],
            search: f.search ?? (_) async => const [],
            onSelected: (r) {
              setState(() {
                _values[f.column] = r.id;
                _picked[f.column] = r;
                // Same mutual-exclusion rule as the dropdown.
                if (f.exclusiveGroup != null) {
                  for (final other in widget.fields) {
                    if (other.column != f.column &&
                        other.exclusiveGroup == f.exclusiveGroup) {
                      _values[other.column] = null;
                      _picked[other.column] = null;
                    }
                  }
                }
              });
              state.didChange(r.id);
            },
          ),
        );

      case WsFieldType.toggle:
        child = SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(f.label),
          subtitle: f.helper == null
              ? null
              : Text(f.helper!, style: const TextStyle(fontSize: 11)),
          value: _values[f.column] == true,
          onChanged: (v) => setState(() => _values[f.column] = v),
        );

      case WsFieldType.date:
        final d = _values[f.column] as DateTime? ?? DateTime.now();
        child = InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: d,
              firstDate: DateTime(2015),
              lastDate: DateTime.now().add(const Duration(days: 1)),
            );
            if (picked != null) setState(() => _values[f.column] = picked);
          },
          child: InputDecorator(
            decoration: InputDecoration(labelText: f.label),
            child: Text(
              '${d.day.toString().padLeft(2, '0')}-'
              '${d.month.toString().padLeft(2, '0')}-${d.year}',
            ),
          ),
        );

      default:
        final isNum = f.type == WsFieldType.number ||
            f.type == WsFieldType.money ||
            f.type == WsFieldType.integer;
        child = TextFormField(
          controller: _text[f.column],
          keyboardType: isNum
              ? const TextInputType.numberWithOptions(decimal: true)
              : (f.type == WsFieldType.multiline
                    ? TextInputType.multiline
                    : TextInputType.text),
          maxLines: f.type == WsFieldType.multiline ? 3 : 1,
          decoration: InputDecoration(
            labelText: f.label + (f.required ? ' *' : ''),
            hintText: f.hint,
            helperText: f.helper,
            prefixText: f.type == WsFieldType.money ? 'Rs ' : null,
          ),
          validator: (v) {
            final t = (v ?? '').trim();
            if (f.required && t.isEmpty) return '${f.label} is required';
            if (isNum && t.isNotEmpty) {
              final n = double.tryParse(t);
              if (n == null) return 'Enter a number';
              if (n < 0) return 'Cannot be negative';
            }
            return null;
          },
        );
    }

    return Padding(padding: const EdgeInsets.only(bottom: 12), child: child);
  }
}
