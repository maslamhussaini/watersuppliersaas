// =============================================================================
// test_harness/lib/ws_outbox.dart
// NOT AN IMPLEMENTATION — a re-export of the production engine.
//
// This file used to be a VENDORED COPY of
// flutter/lib/services/outbox/ws_outbox.dart. It drifted: ownership
// (authUserId) shipped to production and the copy stayed behind, so the
// 160-scenario Postgres matrix was validating an engine one feature older than
// the one users run. The matrix is the strongest evidence in this project, and
// evidence about the wrong code is worth nothing.
//
// Re-exporting rather than copying makes that drift impossible: there is now
// exactly one WsOutbox. The engine is pure Dart — dart:async, dart:math and its
// own store — so this plain Dart package can use it directly with no Flutter
// dependency.
// =============================================================================

export '../../flutter/lib/services/outbox/ws_outbox.dart';
