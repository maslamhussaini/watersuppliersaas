import 'package:supabase_flutter/supabase_flutter.dart';
import '../main.dart';
import '../models/ws_models.dart';

class AuthService {
  static Future<WsUserRole> resolveRole(String authUserId) async {
    final internal = await supabase
        .from('ws_tblInternalUsers')
        .select('Role')
        .eq('AuthUserID', authUserId)
        .maybeSingle();

    if (internal != null) {
      return internal['Role'] == 'admin' ? WsUserRole.admin : WsUserRole.staff;
    }

    final customer = await supabase
        .from('ws_tblCustomers')
        .select('CustomerID')
        .eq('AuthUserID', authUserId)
        .maybeSingle();

    if (customer != null) return WsUserRole.customer;

    return WsUserRole.staff;
  }

  static Future<void> signIn(String email, String password) async {
    await supabase.auth.signInWithPassword(email: email, password: password);
  }

  static Future<void> signUp(String email, String password) async {
    await supabase.auth.signUp(email: email, password: password);
  }

  static Future<void> signOut() async {
    await supabase.auth.signOut();
  }

  static User? get currentUser => supabase.auth.currentUser;
}
