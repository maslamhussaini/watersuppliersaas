// flutter_test, NOT package:test.
//
// package:test is not in this project's dev_dependencies — flutter_test is,
// and it re-exports the same group/test/expect API. Importing package:test
// here fails with "Target of URI doesn't exist" before a single test runs.
// (My sandbox declared package:test directly, which is why this only shows up
// in your project.)
import 'package:flutter_test/flutter_test.dart';
import 'package:watersuppliersaas/services/outbox/ws_outbox.dart';
void main() {
  test('v4 format, version and variant bits', () {
    final re = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    for (var i = 0; i < 200; i++) {
      expect(re.hasMatch(wsNewUuid()), isTrue, reason: wsNewUuid());
    }
  });
  test('no collisions in 50k', () {
    final s = <String>{};
    for (var i = 0; i < 50000; i++) { s.add(wsNewUuid()); }
    expect(s.length, 50000);
  });
}
