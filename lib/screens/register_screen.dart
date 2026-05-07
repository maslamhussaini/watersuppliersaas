import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/ws_theme.dart';

class WsRegisterScreen extends StatefulWidget {
  const WsRegisterScreen({super.key});
  @override State<WsRegisterScreen> createState() => _WsRegisterScreenState();
}

class _WsRegisterScreenState extends State<WsRegisterScreen> {
  final _fullName = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  
  final _orgName = TextEditingController();
  final _orgAddress = TextEditingController();
  final _orgPhone = TextEditingController();

  bool _loading = false;

  Future<void> _register() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.auth.signUp(
        email: _email.text.trim(),
        password: _password.text,
        emailRedirectTo: 'https://watersuppliersaas.vercel.app/',
      );
      
      if (res.user != null) {
        final orgData = await Supabase.instance.client.from('ws_tblorganization').insert({
          'authuserid': res.user!.id,
          'orgname': _orgName.text.trim(),
          'ownername': _fullName.text.trim(),
          'phone': _orgPhone.text.trim().isEmpty ? _phone.text.trim() : _orgPhone.text.trim(),
          'address': _orgAddress.text.trim(),
        }).select().single();
        
        await Supabase.instance.client.from('ws_tblinternalusers').insert({
          'orgid': orgData['orgid'],
          'authuserid': res.user!.id,
          'fullname': _fullName.text.trim(),
          'role': 'admin',
          'phone': _phone.text.trim(),
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Registration successful!')));
          Navigator.pop(context); // Go back to login
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildTextField(String label, String hint, TextEditingController controller, {bool obscure = false, TextInputType? keyboardType}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: WsColors.text2)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          decoration: InputDecoration(hintText: hint),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildCardTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: WsColors.text1),
      ),
    );
  }

  @override Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8), // Grey background from image
      appBar: AppBar(
        title: const Text('Create Account', style: TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: WsColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Your Details Card
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 4)),
                  ],
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildCardTitle('Your Details'),
                    _buildTextField('Full Name', 'Tanveer Ahmed', _fullName),
                    _buildTextField('Phone', '0312-2029171', _phone, keyboardType: TextInputType.phone),
                    _buildTextField('Email', 'tanveer@kentwater.pk', _email, keyboardType: TextInputType.emailAddress),
                    _buildTextField('Password', 'Min 8 characters', _password, obscure: true),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              
              // Organization Card
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 4)),
                  ],
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildCardTitle('Organization'),
                    _buildTextField('Company Name', 'Kent Water — House of Purity', _orgName),
                    _buildTextField('Address', 'Karachi, Sindh', _orgAddress),
                    _buildTextField('Contact Number', '0300 1234567', _orgPhone, keyboardType: TextInputType.phone),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              
              // Submit Button
              ElevatedButton(
                onPressed: _loading ? null : _register,
                style: ElevatedButton.styleFrom(
                  backgroundColor: WsColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _loading 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Complete Registration', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
