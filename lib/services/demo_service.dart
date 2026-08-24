import '../models/ws_models.dart';

class DemoStore {
  DemoStore._();

  static final DemoStore _instance = DemoStore._();

  factory DemoStore() => _instance;

  String? _currentUserEmail;
  int? _selectedOrgId;
  final List<WsOrganization> _organizations = [];
  final List<WsArea> _areas = [];
  final List<WsCustomer> _customers = [];
  final Map<String, String> _demoUsers = {
    'admin@kentwater.pk': 'admin123',
    'customer@kentwater.pk': 'customer123',
  };

  bool get isSignedIn => _currentUserEmail != null;
  String? get currentUserId => _currentUserEmail;
  int? get selectedOrgId => _selectedOrgId;

  void reset() {
    _currentUserEmail = null;
    _selectedOrgId = null;
    _organizations.clear();
    _areas.clear();
    _customers.clear();
    _seedDefaultData();
  }

  bool trySignIn(String email, String password) {
    final normalizedEmail = email.trim().toLowerCase();
    if (_demoUsers[normalizedEmail] == password) {
      _currentUserEmail = normalizedEmail;
      return true;
    }
    return false;
  }

  void signOut() {
    _currentUserEmail = null;
    _selectedOrgId = null;
  }

  void selectOrganization(int orgId) {
    _selectedOrgId = orgId;
  }

  void clearSelection() {
    _selectedOrgId = null;
  }

  WsUserRole resolveRole(String authUserId, {int? orgId}) {
    final normalized = authUserId.trim().toLowerCase();
    if (normalized.contains('customer')) {
      return WsUserRole.customer;
    }
    return WsUserRole.admin;
  }

  List<WsOrganization> organizationsForCurrentUser() {
    if (_currentUserEmail == null) return [];
    return _organizations
        .where(
          (org) =>
              org.authUserId.toLowerCase() == _currentUserEmail!.toLowerCase(),
        )
        .toList();
  }

  WsOrganization? currentOrganization() {
    if (_selectedOrgId == null) return null;
    return _organizations
        .where((org) => org.orgId == _selectedOrgId)
        .firstOrNull;
  }

  void registerOrganization({
    required String email,
    required String password,
    required String orgName,
    required String ownerName,
    required String phone,
    required String address,
  }) {
    if (!trySignIn(email, password)) {
      _currentUserEmail = email.trim().toLowerCase();
    }

    final nextId = (_organizations.isEmpty
        ? 1
        : _organizations
                  .map((org) => org.orgId)
                  .reduce((a, b) => a > b ? a : b) +
              1);
    final org = WsOrganization(
      orgId: nextId,
      authUserId: _currentUserEmail ?? email.trim().toLowerCase(),
      orgName: orgName,
      ownerName: ownerName,
      phone: phone,
      address: address,
    );
    _organizations.add(org);
    _selectedOrgId = org.orgId;

    if (_areas.where((area) => area.orgId == org.orgId).isEmpty) {
      _areas.add(
        WsArea(
          areaId: nextId * 10,
          orgId: org.orgId,
          areaName: 'Main Area',
          ratePerBottle: 35,
        ),
      );
    }
  }

  List<WsArea> areasForCurrentOrg() {
    if (_selectedOrgId == null) return [];
    return _areas.where((area) => area.orgId == _selectedOrgId).toList();
  }

  void upsertCustomer(WsCustomer customer) {
    final normalized = WsCustomer(
      customerId: customer.customerId == 0
          ? _nextCustomerId()
          : customer.customerId,
      orgId: _selectedOrgId ?? customer.orgId,
      authUserId: customer.authUserId,
      areaId: customer.areaId,
      customerName: customer.customerName,
      address: customer.address,
      phone: customer.phone,
      rateOverride: customer.rateOverride,
      depositAmount: customer.depositAmount,
      bottleBalance: customer.bottleBalance,
      isActive: customer.isActive,
      createdDate: customer.createdDate,
      areaName: customer.areaName,
      areaRate: customer.areaRate,
      outstandingDue: customer.outstandingDue,
    );

    final index = _customers.indexWhere(
      (item) => item.customerId == normalized.customerId,
    );
    if (index >= 0) {
      _customers[index] = normalized;
    } else {
      _customers.add(normalized);
    }
  }

  List<WsCustomer> customersForCurrentOrg() {
    if (_selectedOrgId == null) return [];
    return _customers
        .where((customer) => customer.orgId == _selectedOrgId)
        .toList();
  }

  void deleteCustomer(int customerId) {
    _customers.removeWhere((customer) => customer.customerId == customerId);
  }

  int _nextCustomerId() {
    if (_customers.isEmpty) return 1;
    return _customers
            .map((customer) => customer.customerId)
            .reduce((a, b) => a > b ? a : b) +
        1;
  }

  void _seedDefaultData() {
    final defaultOrg = WsOrganization(
      orgId: 1,
      authUserId: 'admin@kentwater.pk',
      orgName: 'Kent Water Demo',
      ownerName: 'Demo Owner',
      phone: '03001234567',
      address: 'Karachi',
    );
    _organizations.add(defaultOrg);
    _areas.add(
      WsArea(
        areaId: 10,
        orgId: defaultOrg.orgId,
        areaName: 'Main Area',
        ratePerBottle: 35,
      ),
    );
    _customers.add(
      WsCustomer(
        customerId: 1,
        orgId: defaultOrg.orgId,
        areaId: 10,
        customerName: 'Demo Customer',
        phone: '03121234567',
        address: 'Model Town',
        depositAmount: 1000,
        bottleBalance: 5,
        createdDate: DateTime.now(),
        areaName: 'Main Area',
        areaRate: 35,
        outstandingDue: 0,
      ),
    );
    _selectedOrgId = defaultOrg.orgId;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) return iterator.current;
    return null;
  }
}
