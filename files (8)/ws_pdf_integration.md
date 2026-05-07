# ==============================================================================
# WaterFlow — PDF Ledger System
# Integration Guide & pubspec.yaml snippet
# ==============================================================================


# ──────────────────────────────────────────────────────────────────────────────
# 1. pubspec.yaml — add under dependencies:
# ──────────────────────────────────────────────────────────────────────────────

dependencies:
  flutter:
    sdk: flutter

  # PDF generation
  pdf: ^3.10.8
  printing: ^5.12.0           # preview + print + share via PdfPreview widget

  # Share to WhatsApp / Gmail / Drive / etc.
  share_plus: ^7.2.2

  # Temp file storage for PDF before sharing
  path_provider: ^2.1.2

  # Date formatting
  intl: ^0.19.0


# ──────────────────────────────────────────────────────────────────────────────
# 2. Android Permissions  (android/app/src/main/AndroidManifest.xml)
# ──────────────────────────────────────────────────────────────────────────────

# Inside <manifest>:
#   <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
#   <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />

# Inside <application>:
#   <provider
#     android:name="androidx.core.content.FileProvider"
#     android:authorities="${applicationId}.provider"
#     android:exported="false"
#     android:grantUriPermissions="true">
#     <meta-data
#       android:name="android.support.FILE_PROVIDER_PATHS"
#       android:resource="@xml/provider_paths"/>
#   </provider>

# Create android/app/src/main/res/xml/provider_paths.xml:
# <?xml version="1.0" encoding="utf-8"?>
# <paths>
#   <cache-path name="cache" path="." />
#   <external-cache-path name="external_cache" path="." />
# </paths>


# ──────────────────────────────────────────────────────────────────────────────
# 3. iOS Info.plist  (ios/Runner/Info.plist)
# ──────────────────────────────────────────────────────────────────────────────

# <key>LSApplicationQueriesSchemes</key>
# <array>
#   <string>whatsapp</string>
# </array>
# <key>UIFileSharingEnabled</key>
# <true/>
# <key>LSSupportsOpeningDocumentsInPlace</key>
# <true/>


# ──────────────────────────────────────────────────────────────────────────────
# 4. How to open Customer Ledger screen
# ──────────────────────────────────────────────────────────────────────────────

# Navigator.push(context, MaterialPageRoute(builder: (_) =>
#   WsCustomerLedgerScreen(
#     org: WsOrganization(
#       orgName:   'Kent Water — House of Purity',
#       ownerName: 'Tanveer Ahmed',
#       phone:     '0312-2029171',
#       address:   'Karachi, Sindh',
#     ),
#     customer: WsCustomer(
#       customerId:      1,
#       customerName:    'Ahmed Khan',
#       address:         'House 12, Karachi West',
#       phone:           '0312-1234567',
#       areaName:        'Karachi West',
#       ratePerBottle:   80,
#       bottleBalance:   5,
#     ),
#     deliveries: deliveriesFromSupabase,   // List<WsDeliveryRow>
#     payments:   paymentsFromSupabase,     // List<WsPaymentRow>
#   ),
# ));


# ──────────────────────────────────────────────────────────────────────────────
# 5. How to open Bottle Ledger screen
# ──────────────────────────────────────────────────────────────────────────────

# Navigator.push(context, MaterialPageRoute(builder: (_) =>
#   WsBottleLedgerScreen(
#     org:      org,
#     snapshot: snapshotFromSupabase,    // WsBottleInventorySnapshot
#     ledger:   ledgerRowsFromSupabase,  // List<WsBottleLedgerEntry>
#     bottles:  bottleListFromSupabase,  // List<WsBottle>
#   ),
# ));


# ──────────────────────────────────────────────────────────────────────────────
# 6. Share options produced by WsShareSheet
# ──────────────────────────────────────────────────────────────────────────────
#
#  💬  WhatsApp       — share_plus XFile → user selects WhatsApp
#  📧  Email          — share_plus with subject line
#  📁  Google Drive   — share_plus → user selects Drive
#  🖨️  Print          — printing package layoutPdf → AirPrint / network printers
#  📤  Save / Other   — system share sheet (Telegram, Messenger, Files, etc.)
#
# All options use the native OS share sheet so every app installed on the
# device (WhatsApp, Telegram, Gmail, Outlook, Google Drive, iCloud, etc.)
# is automatically available without extra packages.


# ──────────────────────────────────────────────────────────────────────────────
# 7. Supabase → Model mapping example
# ──────────────────────────────────────────────────────────────────────────────

# WsDeliveryRow from Supabase row:
#
# WsDeliveryRow(
#   deliveryDate:     DateTime.parse(row['DeliveryDate']),
#   bottlesDelivered: row['BottlesDelivered'],
#   bottlesReturned:  row['BottlesReturned'],
#   bottleBalance:    row['BottleBalance'],
#   rateApplied:      (row['RateApplied'] as num).toDouble(),
#   amountCharged:    (row['AmountCharged'] as num).toDouble(),
#   amountReceived:   (row['AmountReceived'] ?? 0.0).toDouble(),
#   runningBalance:   computedRunning,   // compute in Dart or fetch from view
#   deliveredBy:      row['DeliveredBy'] ?? '—',
#   notes:            row['Notes'],
# )


# ──────────────────────────────────────────────────────────────────────────────
# 8. Files summary
# ──────────────────────────────────────────────────────────────────────────────
#
#  ws_customer_ledger_pdf.dart   — Customer ledger PDF + share service + UI screen
#  ws_bottle_ledger_pdf.dart     — Bottle ledger PDF + individual register + UI screen
#  ws_pdf_integration.md         — This file (pubspec + platform setup + usage)
#
# Both PDF generators use:
#   • PdfGoogleFonts (Roboto family — no asset bundling needed)
#   • WsShareSheet   — unified bottom sheet for WhatsApp / Email / Drive / Print
#   • WsPdfShareService.shareFile() — wraps share_plus for any target
