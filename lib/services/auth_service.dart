// =============================================================================
// lib/services/auth_service.dart
// Sign in / sign up, role routing, and permission loading.
//
// WHAT CHANGED AND WHY
//
// 1. resolveRole() read `internal['Role']`. PostgREST returns 'role' in
//    lowercase, so that key was always null, the comparison to 'admin' was
//    always false, and EVERY admin silently became staff. Owners could not
//    reach admin-only screens in their own organization.
//
// 2. resolveRole() called .maybeSingle() on a query filtered only by
//    authuserid. maybeSingle() raises PGRST116 when more than one row matches,
//    so a user belonging to two organizations crashed at login — the exact
//    multi-organization case the product is supposed to support.
//
// 3. Roles are no longer inferred from a three-value enum. The database defines
//    six staff roles plus a portal role, and authorization is by permission
//    code. loadPermissions() fetches the caller's codes once per organization;
//    WsUserRole survives only to choose between the staff dashboard and the
//    customer portal.
//
// The UI must treat permissions as a convenience. RLS enforces the same rules
// server-side — hiding a button is not access control.
// =============================================================================

import 'package:supabase_flutter/supabase_flutter.dart';
import '../main.dart';
import '../models/ws_models.dart';
import '../supabase_config.dart';
import 'auth/ws_auth_client.dart';
import 'auth/ws_auth_supabase.dart';
import 'auth/ws_phone_verification.dart';
import 'auth/ws_registration_attempt_store.dart';
import 'auth/ws_registration_flow.dart';
import 'storage/ws_kv_default.dart';
import 'demo_service.dart';
import 'tenant_service.dart';

class AuthService {
  static WsPermissions _permissions = const WsPermissions.none();
  static int? _permissionsOrgId;

  // ─── phone verification ────────────────────────────────────────────────────
  //
  // The sequence and all of its rules live in auth/ws_phone_verification.dart,
  // which has no supabase import and is therefore exercised without a network
  // in test/phone_verification_test.dart. The methods below are the app-facing
  // entry points and contain no logic of their own.
  //
  // These are reached through WsRegistrationFlow, which register_screen.dart
  // drives. What remains unverified is the project's real Auth configuration:
  // whether signUp() returns a session at all depends on mailer_autoconfirm,
  // and the flow detects that at runtime rather than assuming it.

  /// Swapped for a recording fake in tests. Null means "use the real client",
  /// resolved lazily so demo mode never touches supabase.
  static WsAuthClient? authClientOverride;

  static WsPhoneVerification get phoneVerification => WsPhoneVerification(
        authClientOverride ?? WsSupabaseAuthClient(supabase.auth),
      );

  // THREE PASS-THROUGHS WERE REMOVED FROM HERE:
  //   verifyPhone()            → confirmPhone()
  //   startPhoneVerification() → attachPhone()
  //   resendPhoneCode()        → resendCode()
  //
  // All three had zero callers, and each handed a step of the OTP sequence to
  // any caller while skipping WsRegistrationFlow — so a phone could be attached
  // without the attempt knowing, a code re-sent outside phoneOtpSent, or
  // verification completed without a code having been sent at all.
  //
  // verifyPhone was the sharp one:
  //
  // It handed confirmPhone() straight to any caller, skipping
  // WsRegistrationFlow.submitCode() and therefore skipping the check that the
  // state is actually phoneOtpSent — that a code was SENT.
  //
  // That is not a cosmetic bypass. confirmPhone() returns phoneOtpVerified
  // whenever the server reports the number confirmed, and under
  // phone_autoconfirm the server reports exactly that WITHOUT ever sending a
  // code. So this method could manufacture otpProven — the one value meant to
  // mean "somebody demonstrably received a message at this number" — out of a
  // dashboard toggle.
  //
  // Nothing behaved wrongly, because nothing called them. They were loaded
  // footguns with no triggers attached, and the fix is removal rather than more
  // gates: WsRegistrationFlow IS THE SOLE OWNER of the registration phone
  // state machine. WsPhoneVerification keeps all three operations — the flow
  // calls them, and that is the only route.
  //
  // Do not reintroduce thin AuthService wrappers around them.

  // ─── registration attempts ─────────────────────────────────────────────────
  //
  // Both screens go through these. NEITHER MINTS A KEY any more:
  // register_screen.dart resumes-or-begins, organization_selector_screen.dart
  // resumes before creating, and WsRegistrationFlow owns every clientuuid.

  static WsRegistrationAttemptStore? attemptStoreOverride;

  static Future<WsRegistrationAttemptStore> registrationStore() async =>
      attemptStoreOverride ??
      WsRegistrationAttemptStore(await wsOpenDefaultKeyValueStore());

  /// Resumes the registration already under way, or null when there is none.
  ///
  /// ALWAYS TRY THIS BEFORE [beginRegistration]. A reload, a route change or a
  /// restart destroys the widget State that used to hold the key; the attempt
  /// on disk is what makes the retry resolve to the same organization instead
  /// of building a second one.
  static Future<WsRegistrationFlow?> resumeRegistration({DateTime? now}) async =>
      WsRegistrationFlow.resume(
        verification: phoneVerification,
        store: await registrationStore(),
        now: now,
      );

  /// A genuinely new attempt, with a new key. Only correct when
  /// [resumeRegistration] returned null.
  static Future<WsRegistrationFlow> beginRegistration({
    required String email,
    required String orgName,
    required String ownerName,
    required String orgPhone,
    required String address,
  }) async =>
      WsRegistrationFlow(
        phoneVerification,
        store: await registrationStore(),
        email: email,
        orgName: orgName,
        ownerName: ownerName,
        orgPhone: orgPhone,
        address: address,
      );

  /// An existing owner adding ANOTHER organization. No signUp, no OTP — but a
  /// durable key, written before this returns.
  static Future<WsRegistrationFlow> beginAdditionalOrganization({
    required String orgName,
    required String ownerName,
    required String orgPhone,
    required String address,
  }) async =>
      WsRegistrationFlow.beginForExistingUser(
        verification: phoneVerification,
        store: await registrationStore(),
        orgName: orgName,
        ownerName: ownerName,
        orgPhone: orgPhone,
        address: address,
      );

  /// Provisions for [flow], reusing its key.
  ///
  /// The existing createOrganizationForCurrentUser is called unchanged — same
  /// RPC, same parameters, same clientuuid semantics from migration 014. The
  /// only difference is where the key comes from.
  static Future<int> provisionForRegistration(WsRegistrationFlow flow) =>
      flow.provisionOrganization((clientUuid) =>
          createOrganizationForCurrentUser(
            orgName: flow.orgName,
            ownerName: flow.ownerName,
            phone: flow.orgPhone,
            address: flow.address,
            clientUuid: clientUuid,
          ));

  /// Permission codes for the active organization. Empty until
  /// [loadPermissions] has run.
  static WsPermissions get permissions => _permissions;

  /// Loads permission codes for [orgId] from the caller's membership. One
  /// round trip, cached per organization for the session.
  ///
  /// Switching organizations must invalidate this — [WsTenantService
  /// .selectOrganization] calls [clearPermissions].
  static Future<WsPermissions> loadPermissions(int orgId) async {
    if (_permissionsOrgId == orgId) return _permissions;

    if (!supabaseClientInitialized) {
      // Demo mode has no server to ask, so grant the demo user everything
      // rather than silently disabling half the UI.
      _permissions = const WsPermissions({
        'org.view', 'org.manage',
        'users.view', 'users.manage',
        'customers.view', 'customers.manage',
        'vendors.view', 'vendors.manage',
        'products.view', 'products.manage',
        'delivery.view', 'delivery.manage',
        'payments.view', 'payments.manage',
        'purchases.view', 'purchases.manage',
        'accounting.view', 'accounting.manage',
        'reports.view', 'reports.all',
      });
      _permissionsOrgId = orgId;
      return _permissions;
    }

    final user = currentUser;
    if (user == null) {
      _permissions = const WsPermissions.none();
      _permissionsOrgId = null;
      return _permissions;
    }

    // Two plain queries rather than a nested PostgREST embed.
    //
    // The previous version used a two-level embed with an alias
    // (`ws_tblrolepermissions:ws_tblroles(ws_tblrolepermissions(permcode))`).
    // Embeds depend on PostgREST inferring the relationship from foreign keys,
    // and a two-level embed through an aliased middle table is exactly the shape
    // that fails with "could not find a relationship" on some schema layouts.
    // A permission loader must not be the clever part of the codebase: if it
    // returns an empty set the whole UI silently degrades to read-only.
    final membership = await supabase
        .from('ws_tblmemberships')
        .select('roleid')
        .eq('authuserid', user.id)
        .eq('orgid', orgId)
        .eq('isactive', true)
        .limit(1)
        .maybeSingle();

    if (membership == null) {
      _permissions = const WsPermissions.none();
      _permissionsOrgId = orgId;
      return _permissions;
    }

    final rows = await supabase
        .from('ws_tblrolepermissions')
        .select('permcode')
        .eq('roleid', membership['roleid'] as Object);

    final codes = <String>{
      for (final r in rows)
        if (r['permcode'] != null) r['permcode'].toString(),
    };

    _permissions = WsPermissions(codes);
    _permissionsOrgId = orgId;
    return _permissions;
  }

  static void clearPermissions() {
    _permissions = const WsPermissions.none();
    _permissionsOrgId = null;
  }

  /// Coarse routing decision only: staff dashboard or customer portal.
  ///
  /// [orgId] should always be supplied. Without it a multi-organization user
  /// cannot be resolved unambiguously, and the query below deliberately takes
  /// the first row rather than throwing — see note 2 in the header.
  static Future<WsUserRole> resolveRole(String authUserId, {int? orgId}) async {
    if (!supabaseClientInitialized) {
      return DemoStore().resolveRole(authUserId, orgId: orgId);
    }

    // A portal membership carries a customerid; staff memberships do not. This
    // single read replaces the old two-query internalusers-then-customers dance
    // and cannot disagree with the RLS policies, which consult the same column.
    var membershipQuery = supabase
        .from('ws_tblmemberships')
        .select('customerid, ws_tblroles(rolecode, isportal)')
        .eq('authuserid', authUserId)
        .eq('isactive', true);

    if (orgId != null) {
      membershipQuery = membershipQuery.eq('orgid', orgId);
    }

    // limit(1) + maybeSingle(), not a bare maybeSingle(): a user in two
    // organizations returns two rows, and maybeSingle() alone throws PGRST116.
    final membership = await membershipQuery.limit(1).maybeSingle();

    if (membership == null) {
      // Authenticated but not a member of anything yet — treat as staff with no
      // permissions so the organization selector can offer to create one.
      return WsUserRole.staff;
    }

    final role = membership['ws_tblroles'];
    final isPortal = role is Map<String, dynamic>
        ? (role['isportal'] == true)
        : false;

    if (isPortal || membership['customerid'] != null) {
      return WsUserRole.customer;
    }

    final roleCode =
        role is Map<String, dynamic> ? '${role['rolecode']}'.toLowerCase() : '';

    return (roleCode == 'owner' || roleCode == 'admin')
        ? WsUserRole.admin
        : WsUserRole.staff;
  }

  static Future<void> signIn(String email, String password) async {
    WsTenantService.clearSelection();
    clearPermissions();
    if (!supabaseClientInitialized) {
      final ok = DemoStore().trySignIn(email, password);
      if (!ok) {
        throw Exception(
          'Invalid demo credentials. Try admin@kentwater.pk / admin123',
        );
      }
      return;
    }
    await supabase.auth.signInWithPassword(email: email, password: password);
  }

  static Future<void> signUp(String email, String password) async {
    WsTenantService.clearSelection();
    clearPermissions();
    if (!supabaseClientInitialized) {
      final ok = DemoStore().trySignIn(email, password);
      if (!ok) {
        DemoStore().registerOrganization(
          email: email,
          password: password,
          orgName: 'Demo Org',
          ownerName: email,
          phone: '',
          address: '',
        );
      }
      return;
    }
    await supabase.auth.signUp(email: email, password: password);
  }

  // registerOrganization() was removed here.
  //
  // It signed the user up and provisioned in one call, and by the end it had
  // ZERO callers — register_screen.dart goes through WsRegistrationFlow now.
  // Leaving it would have left a shortcut that bypassed every guarantee the
  // registration work exists to provide: no attempt persisted before the RPC,
  // no _isProvisionable gate, no record-then-clear, no resume after a lost
  // response. A dead API that can only be used wrongly is worse than no API.
  //
  // THE ONE PRODUCTION ENTRY POINT IS provisionForRegistration().
  //
  // DemoStore().registerOrganization is a different method on a different
  // class and is untouched; supabase_service.dart still uses it.


  /// Provisions an organization for the already-signed-in user.
  ///
  /// [clientUuid] identifies ONE registration attempt. Pass the same value on
  /// every retry of that attempt and the database returns the organization it
  /// already provisioned instead of creating a second one (migration 014).
  /// Omitting it preserves the old behaviour exactly.
  static Future<int> createOrganizationForCurrentUser({
    required String orgName,
    required String ownerName,
    required String phone,
    required String address,
    String currency = 'PKR',
    String? clientUuid,
  }) async {
    final result = await supabase.rpc('ws_create_organization', params: {
      'p_orgname': orgName,
      'p_ownername': ownerName,
      'p_phone': phone,
      'p_address': address,
      'p_currency': currency,
      'p_clientuuid': clientUuid,
    });
    final orgId = (result as num).toInt();

    // No second chart-seeding call: provisioning does it in the same
    // transaction since migration 011. See WsDataService.createOrg.

    WsTenantService.selectOrganization(orgId);
    await loadPermissions(orgId);
    return orgId;
  }

  /// Sends a password-reset email.
  ///
  /// Supabase always reports success, whether or not the address is registered.
  /// That is deliberate on their side and correct: telling a stranger "no such
  /// account" turns the reset form into a way to discover who has an account.
  /// So the UI must say "if that address is registered…" rather than "sent".
  ///
  /// The redirect must be listed under Authentication → URL Configuration in
  /// the Supabase dashboard or the link in the email will be rejected.
  static Future<void> sendPasswordReset(String email) async {
    if (!supabaseClientInitialized) {
      throw Exception(
        'Password reset needs a Supabase connection. The app is running in '
        'demo mode.',
      );
    }
    await supabase.auth.resetPasswordForEmail(
      email.trim(),
      redirectTo: WsConfig.redirectUrl,
    );
  }

  static Future<void> signOut() async {
    clearPermissions();
    if (!supabaseClientInitialized) {
      DemoStore().signOut();
      WsTenantService.clearSelection();
      return;
    }
    await supabase.auth.signOut();
    WsTenantService.clearSelection();
  }

  static User? get currentUser {
    if (!supabaseClientInitialized) return null;
    return supabase.auth.currentUser;
  }
}
