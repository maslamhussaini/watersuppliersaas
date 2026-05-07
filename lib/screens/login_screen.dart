import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/ws_theme.dart';
import 'register_screen.dart';

class WsLoginScreen extends StatefulWidget {
  const WsLoginScreen({super.key});
  @override State<WsLoginScreen> createState() => _WsLoginScreenState();
}

class _WsLoginScreenState extends State<WsLoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;

  Future<void> _login() async {
    setState(() => _loading = true);
    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WsColors.primary,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              flex: 4,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.1),
                      ),
                      child: const Icon(Icons.water_drop, size: 56, color: Colors.white),
                    ),
                    const SizedBox(height: 16),
                    const Text('WaterFlow', style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text('Water Supplier Management', style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ),
            Expanded(
              flex: 6,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Welcome back', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      const Text('Sign in to continue', style: const TextStyle(color: WsColors.text3, fontSize: 14)),
                      const SizedBox(height: 32),
                      const Text('Email', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: WsColors.text2)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(hintText: 'admin@kentwater.pk'),
                      ),
                      const SizedBox(height: 20),
                      const Text('Password', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: WsColors.text2)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _password,
                        obscureText: true,
                        decoration: const InputDecoration(hintText: '••••••••'),
                      ),
                      const SizedBox(height: 32),
                      OutlinedButton(
                        onPressed: _loading ? null : _login,
                        style: OutlinedButton.styleFrom(
                          backgroundColor: WsColors.primary,
                          foregroundColor: Colors.white,
                        ),
                        child: _loading 
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) 
                            : const Text('Admin Login', style: TextStyle(fontSize: 16)),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () {},
                        child: const Text('Customer Portal', style: TextStyle(fontSize: 16)),
                      ),
                      const SizedBox(height: 32),
                      Center(
                        child: GestureDetector(
                          onTap: () {
                            Navigator.push(context, MaterialPageRoute(builder: (_) => const WsRegisterScreen()));
                          },
                          child: RichText(
                            text: const TextSpan(
                              text: 'No account? ',
                              style: TextStyle(color: WsColors.text3, fontSize: 13),
                              children: [
                                TextSpan(
                                  text: 'Register here', 
                                  style: TextStyle(color: WsColors.primary, fontWeight: FontWeight.w600)
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}