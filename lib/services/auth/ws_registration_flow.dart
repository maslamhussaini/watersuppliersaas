// =============================================================================
// lib/services/auth/ws_registration_flow.dart
// The registration state machine. NOT WIRED TO ANYTHING.
//
// ─── WHAT THIS IS FOR ────────────────────────────────────────────────────────
//
// WsPhoneVerification performs operations. This holds the STATE between them,
// so that wiring a UI later is a rendering job rather than another
// architectural decision. Every branch below already has a test.
//
//     notStarted
//         │ start()
//         ├──────────────► emailConfirmationPending   (no session: project
//         │                                            requires email confirm)
//         ├──────────────► sessionMissing             (session absent/expired)
//         ├──────────────► phoneAlreadyConfirmed      (phone_autoconfirm ON)
//         └──────────────► phoneOtpSent
//                              │ submitCode()
//                              ├── wrong/expired ──► phoneOtpSent (lastError)
//                              └── correct ────────► phoneOtpVerified
//                                                          │
//                                            markOrganizationProvisioned()
//
// ─── THE INVARIANT THIS CLASS OWNS ───────────────────────────────────────────
//
//     ONE signUp → ONE auth user → phoneChange verification
//                → ONE clientuuid → ONE organization
//
// The clientuuid is generated ONCE, when the attempt starts, and never
// regenerated — not on a wrong code, not on a resend, not on a provisioning
// timeout, not on a retry after the app was killed. That is the whole point of
// it: migration 014 returns the organization it already made when it sees the
// same key, so a second key would produce a second organization and the
// idempotency would silently be worth nothing.
//
// Nothing here calls signInWithOtp. It is not reachable from this class.
// =============================================================================

import '../outbox/ws_outbox.dart' show wsNewUuid;
import 'ws_auth_client.dart';
import 'ws_phone_verification.dart';
import 'ws_registration_attempt_store.dart';

class WsRegistrationFlow {
  final WsPhoneVerification verification;

  /// Injected so tests can pin it. Production uses the same generator the
  /// outbox uses for document idempotency.
  final String Function() _newUuid;

  /// Optional. Without it the flow behaves exactly as before — everything in
  /// memory — which is what every pre-existing test exercises.
  final WsRegistrationAttemptStore? store;

  /// Business details collected by the wizard, carried so a resume does not
  /// have to ask for them a second time. Never secrets: see the attempt store.
  String email;
  String orgName;
  String ownerName;
  String orgPhone;
  String address;

  DateTime _startedAt = DateTime.now().toUtc();

  WsRegistrationFlow(
    this.verification, {
    String Function()? newUuid,
    this.store,
    this.email = '',
    this.orgName = '',
    this.ownerName = '',
    this.orgPhone = '',
    this.address = '',
  }) : _newUuid = newUuid ?? wsNewUuid;

  /// Restores an attempt that is already under way.
  ///
  /// THE UUID COMES FROM STORAGE. It is injected as the generator so that even
  /// the code path that would normally mint one returns the original instead —
  /// there is no branch here that can produce a replacement key while claiming
  /// to be the same attempt.
  static Future<WsRegistrationFlow?> resume({
    required WsPhoneVerification verification,
    required WsRegistrationAttemptStore store,
    DateTime? now,
  }) async {
    final saved = await store.load(now: now);
    if (saved == null) return null;

    final flow = WsRegistrationFlow(
      verification,
      store: store,
      newUuid: () => saved.clientUuid,
      email: saved.email,
      orgName: saved.orgName,
      ownerName: saved.ownerName,
      orgPhone: saved.orgPhone,
      address: saved.address,
    );

    flow._clientUuid = saved.clientUuid;
    flow._phone = saved.phone.isEmpty ? null : saved.phone;
    flow._startedAt = saved.startedAt;
    flow._organizationId = saved.organizationId;
    // An add-organization attempt resumes as one, keeping its gate open so the
    // retry can finish what the lost response left behind.
    flow._existingUserSession = saved.state == existingUserStateName;

    flow._state = WsRegistrationState.values.firstWhere(
      (v) => v.name == saved.state,
      // An unrecognised state from a newer build resumes as "nothing has
      // happened" rather than throwing. The KEY is what must survive; the
      // step can be re-walked.
      orElse: () => WsRegistrationState.notStarted,
    );

    // ─── RECONCILE THE STORED STATE WITH THE LIVE SESSION ───────────────────
    //
    // emailConfirmationPending and sessionMissing both record that there was
    // no session AT THE MOMENT THE ATTEMPT WAS SAVED. Neither says anything
    // about now, and the thing that resolves both happens OUTSIDE this app:
    // the person opens the confirmation link in their mail client, comes back,
    // and signs in. The stored label is then a memory, not a fact.
    //
    // Trusting the label was a real defect, found only against a real project
    // with mailer_autoconfirm off — Supabase's default. The sequence was:
    //
    //   sign up  →  saved as emailConfirmationPending (correct, no session)
    //   confirm the email in another tab
    //   sign in  →  a REAL session now exists
    //   Create Organization  →  resume() restored the stale label, the
    //                           provisioning gate read the label rather than
    //                           the session, and threw
    //                           "Cannot provision from state
    //                            emailConfirmationPending"
    //
    // leaving the user with an account, no business, and no way forward: every
    // retry restored the same stale label.
    //
    // No local test could reach it. FakeAuthClient's session always agrees with
    // what was persisted, because a fake cannot mint a session out of band. It
    // takes a real email round trip to produce "stale state + live session".
    //
    // The session is the fact. When the stored state is one of the two
    // no-session states and a session now exists, the attempt is what
    // beginForExistingUser() would have produced: a signed-in user finishing an
    // organization. Resuming it as one opens the same gate that path opens, and
    // the next _persist() rewrites the label (see :126), so the staleness does
    // not survive.
    //
    // Deliberately narrow: ONLY those two states, and ONLY when a session is
    // actually present. Every other stored state resumes exactly as before, and
    // an unauthenticated user is untouched — hasSession is false, so nothing
    // here fires.
    final storedStateAssumedNoSession =
        flow._state == WsRegistrationState.emailConfirmationPending ||
            flow._state == WsRegistrationState.sessionMissing;

    if (storedStateAssumedNoSession && verification.client.hasSession) {
      flow._existingUserSession = true;
    }

    flow._outcome = WsRegistrationOutcome(flow._state);
    return flow;
  }

  /// Writes the current attempt through the seam. No-op without a store.
  Future<void> _persist() async {
    final key = _clientUuid;
    if (store == null || key == null) return;
    await store!.save(WsRegistrationAttempt(
      clientUuid: key,
      state: _existingUserSession ? existingUserStateName : _state.name,
      assurance: assurance.name,
      phone: _phone ?? '',
      email: email,
      orgName: orgName,
      ownerName: ownerName,
      orgPhone: orgPhone,
      address: address,
      startedAt: _startedAt,
      organizationId: _organizationId,
    ));
  }

  /// Records provisioning AND clears the persisted attempt, in that order.
  ///
  /// Order matters: clearing first would mean a crash between the two lines
  /// left an attempt that looks unprovisioned, and the retry would mint a new
  /// key for an organization that already exists.
  Future<void> completeProvisioning(int organizationId) async {
    markOrganizationProvisioned(organizationId);
    await store?.clear();
  }

  /// Provisions through [provision], which receives THE ORIGINAL clientuuid.
  ///
  /// This is the only sanctioned way to reach ws_create_organization from a
  /// registration attempt, and it exists so that no caller has to remember the
  /// ordering rules:
  ///
  ///   * the gate is checked BEFORE the RPC, not after
  ///   * the key handed over is the persisted one, never a fresh one
  ///   * a THROW leaves the attempt untouched, so the retry resolves to the
  ///     organization the failed call may already have committed
  ///   * only a returned id clears the attempt
  ///
  /// A caller that wires these by hand will eventually get one of them wrong,
  /// and the one it gets wrong will be the fourth.
  Future<int> provisionOrganization(
    Future<int> Function(String clientUuid) provision,
  ) async {
    if (!canProvisionOrganization) {
      throw StateError(
        'Cannot provision from state ${_state.name}'
        '${_organizationId != null ? ' (already provisioned '
            '$_organizationId)' : ''}.',
      );
    }

    // Deliberately NOT wrapped in try/catch. A failure — including a timeout
    // that may already have committed — must propagate with the attempt still
    // on disk, because the next attempt has to reuse this key to resolve it.
    final organizationId = await provision(_clientUuid!);

    await completeProvisioning(organizationId);
    return organizationId;
  }

  /// ─── THE EXISTING-USER PATH ───────────────────────────────────────────────
  ///
  /// An owner who already has an organization adding ANOTHER one. There is no
  /// signUp, no phone step and no OTP — they are already authenticated — but
  /// they still need a durable key, because ws_create_organization is just as
  /// capable of committing and losing its response here as anywhere else.
  ///
  /// The gate below is opened by this flag rather than by a phone state, and
  /// [assurance] deliberately stays [WsPhoneAssurance.none]: nothing about this
  /// path is evidence that anybody holds a phone number. Anything that later
  /// gates quota or trial credit must keep asking for otpProven and must not
  /// mistake an add-organization attempt for a verified one.
  bool _existingUserSession = false;

  bool get isExistingUserSession => _existingUserSession;

  /// The state name persisted for this path. Not a member of
  /// [WsRegistrationState] because it is not a phone state — adding it to that
  /// enum would put a non-phone concept in a phone machine, and every switch
  /// over it would grow a meaningless branch.
  static const existingUserStateName = 'existingUserSession';

  /// Begins an add-organization attempt and PERSISTS IT BEFORE RETURNING.
  ///
  /// The await on _persist() is the whole point: the previous version minted a
  /// key in memory and went straight to the RPC, so a commit whose response was
  /// lost left nothing on disk to resume, and the retry built a second
  /// organization.
  static Future<WsRegistrationFlow> beginForExistingUser({
    required WsPhoneVerification verification,
    required WsRegistrationAttemptStore store,
    required String orgName,
    required String ownerName,
    required String orgPhone,
    required String address,
    String Function()? newUuid,
  }) async {
    final flow = WsRegistrationFlow(
      verification,
      store: store,
      newUuid: newUuid,
      orgName: orgName,
      ownerName: ownerName,
      orgPhone: orgPhone,
      address: address,
    );
    flow._existingUserSession = true;
    flow._clientUuid = flow._newUuid();
    await flow._persist();
    return flow;
  }

  /// The user gave up. The attempt is over and must never be resumed — a new
  /// registration is genuinely a new attempt and gets a new key.
  Future<void> abandon() async {
    await store?.clear();
  }

  WsRegistrationState _state = WsRegistrationState.notStarted;
  WsRegistrationOutcome? _outcome;
  String? _clientUuid;
  String? _phone;
  WsOtpError? _lastError;
  int _codeAttempts = 0;
  int _resends = 0;
  int? _organizationId;

  WsRegistrationState get state => _state;
  WsRegistrationOutcome? get outcome => _outcome;

  /// The key for THIS registration attempt. Null until [start] is called.
  ///
  /// Pass it to ws_create_organization on every provisioning attempt, including
  /// retries — see the header.
  String? get clientUuid => _clientUuid;

  String? get phone => _phone;
  WsOtpError? get lastError => _lastError;
  int get codeAttempts => _codeAttempts;
  int get resendCount => _resends;
  int? get organizationId => _organizationId;

  /// How much the phone number is worth as evidence. [WsPhoneAssurance.none]
  /// until a terminal phone state is reached.
  WsPhoneAssurance get assurance =>
      _outcome?.assurance ?? WsPhoneAssurance.none;

  /// Whether somebody demonstrably received a message at that number.
  ///
  /// NOT the same question as [canProvisionOrganization] — read the doc on
  /// [WsRegistrationState.phoneAlreadyConfirmed] before using either to gate
  /// quota or trial credit.
  bool get isPhoneOwnershipProven => assurance == WsPhoneAssurance.otpProven;

  /// ─── THE ONE PROVISIONING RULE ────────────────────────────────────────────
  ///
  /// Both gates delegate here. They used to state the rule separately, and the
  /// copies drifted: markOrganizationProvisioned consulted only the phone
  /// outcome, so an add-organization attempt passed the outer gate, reached the
  /// RPC, and was then refused on the way back. Two checks that must agree
  /// should not be two pieces of code.
  ///
  /// Two ways to be provisionable, and only two:
  ///   * a phone state that satisfies the machine (verified, or autoconfirmed)
  ///   * an already-authenticated owner adding another organization
  bool get _isProvisionable =>
      (_outcome?.canProvisionOrganization ?? false) || _existingUserSession;

  bool get canProvisionOrganization =>
      _isProvisionable && _organizationId == null;

  bool get isAwaitingCode => _state == WsRegistrationState.phoneOtpSent;

  bool get isComplete => _organizationId != null;

  /// True when this attempt cannot continue in the registration screen and the
  /// person has to do something elsewhere — confirm an email, or sign in again.
  /// A reconciled attempt is excluded: once resume() has seen a live session,
  /// the thing that had to happen elsewhere has already happened. Saying
  /// otherwise would tell someone to go and confirm an email they confirmed
  /// five seconds ago. Unauthenticated attempts are unaffected —
  /// _existingUserSession stays false for them.
  bool get needsUserActionOutsideRegistration =>
      !_existingUserSession &&
      (_state == WsRegistrationState.emailConfirmationPending ||
          _state == WsRegistrationState.sessionMissing);

  // ─── transitions ───────────────────────────────────────────────────────────

  /// Creates the auth user and, if a session came back, attaches the phone.
  ///
  /// Calling this twice on the same instance is refused rather than allowed to
  /// create a second auth user. A genuinely new attempt gets a new instance,
  /// and therefore a new clientuuid, which is correct.
  Future<WsRegistrationState> start({
    required String email,
    required String password,
    required String phone,
    String? redirectTo,
  }) async {
    if (_state != WsRegistrationState.notStarted) {
      throw StateError(
        'This registration has already started. Reusing it would risk a '
        'second signUp against the same clientuuid.',
      );
    }

    _clientUuid = _newUuid();
    _phone = wsNormalisePhone(phone);
    _lastError = null;

    try {
      final outcome = await verification.startRegistration(
        email: email,
        password: password,
        phone: phone,
        redirectTo: redirectTo,
      );
      _apply(outcome);
      await _persist();
      return _state;
    } on WsAuthException catch (e) {
      final r = _fail(e);
      await _persist();
      return r;
    }
  }

  /// Re-attaches the phone for an attempt that was interrupted after signUp.
  ///
  /// The auth user already exists, so this must NEVER go back through signUp —
  /// that would be the second identity the whole design exists to prevent.
  Future<WsRegistrationState> resumeWithSession({String? phone}) async {
    final target = phone ?? _phone;
    if (target == null) {
      throw StateError('No phone number to resume with.');
    }

    _clientUuid ??= _newUuid();
    _phone = wsNormalisePhone(target);
    _lastError = null;

    try {
      _apply(await verification.attachPhone(_phone!));
      await _persist();
      return _state;
    } on WsAuthException catch (e) {
      final r = _fail(e);
      await _persist();
      return r;
    }
  }

  /// Submits a code. A wrong or expired code leaves the machine awaiting
  /// another one rather than collapsing the attempt — the auth user and the
  /// clientuuid both survive, so a retype costs nothing.
  Future<WsRegistrationState> submitCode(String code) async {
    if (_state != WsRegistrationState.phoneOtpSent) {
      throw StateError('Not waiting for a code (state: ${_state.name}).');
    }

    _codeAttempts++;
    _lastError = null;

    try {
      _apply(await verification.confirmPhone(phone: _phone!, token: code));
      await _persist();
      return _state;
    } on WsAuthException catch (e) {
      _lastError = wsClassifyOtpError(e);
      // Stays in phoneOtpSent unless the session itself has gone. Either way
      // the KEY is untouched — a wrong code costs a retype, never a second
      // organization.
      if (_lastError == WsOtpError.sessionMissing) {
        _state = WsRegistrationState.sessionMissing;
      }
      await _persist();
      return _state;
    }
  }

  /// Asks for another code. Never regenerates the clientuuid, and never
  /// re-runs signUp.
  Future<WsRegistrationState> resendCode() async {
    if (_state != WsRegistrationState.phoneOtpSent) {
      throw StateError('Not waiting for a code (state: ${_state.name}).');
    }

    _lastError = null;
    try {
      await verification.resendCode(_phone!);
      _resends++;
    } on WsAuthException catch (e) {
      _lastError = wsClassifyOtpError(e);
    }
    await _persist();
    return _state;
  }

  /// Records that provisioning succeeded.
  ///
  /// Idempotent: calling it twice with the same id is a no-op, which is what a
  /// retry after a lost response looks like from here. A DIFFERENT id is an
  /// error, because it means two organizations exist for one clientuuid and
  /// something upstream has broken migration 014's guarantee.
  void markOrganizationProvisioned(int organizationId) {
    if (_organizationId != null && _organizationId != organizationId) {
      throw StateError(
        'This registration already provisioned organization $_organizationId; '
        'refusing to record $organizationId as well. One clientuuid must map '
        'to exactly one organization.',
      );
    }
    // The SAME predicate the outer gate uses, minus the already-provisioned
    // clause, which the check above owns. Delegating rather than restating is
    // the point: see [_isProvisionable].
    if (!_isProvisionable) {
      throw StateError(
        'Cannot provision from state ${_state.name}.',
      );
    }
    _organizationId = organizationId;
  }

  // ─── internals ─────────────────────────────────────────────────────────────

  WsRegistrationState _apply(WsRegistrationOutcome outcome) {
    _outcome = outcome;
    _state = outcome.state;
    if (outcome.user?.phone != null) _phone = outcome.user!.phone;
    return _state;
  }

  WsRegistrationState _fail(WsAuthException e) {
    _lastError = wsClassifyOtpError(e);
    if (_lastError == WsOtpError.sessionMissing) {
      _state = WsRegistrationState.sessionMissing;
      _outcome = const WsRegistrationOutcome(
        WsRegistrationState.sessionMissing,
      );
    }
    return _state;
  }
}
