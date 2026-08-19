import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/supabase_env.dart';

/// Magic-link sign-in. Offline continue keeps Phase 1 walking working
/// before the schema is applied.
class LoginScreen extends StatefulWidget {
  final VoidCallback onOffline;
  const LoginScreen({super.key, required this.onOffline});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  bool _busy = false;
  String? _msg;
  bool _sent = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _msg = 'Enter a real email.');
      return;
    }
    if (!SupabaseEnv.configured) {
      setState(() => _msg =
          'This APK was built without SUPABASE_ANON_KEY. Continue offline.');
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      await Supabase.instance.client.auth.signInWithOtp(
        email: email,
        emailRedirectTo: SupabaseEnv.redirect,
      );
      if (!mounted) return;
      setState(() {
        _sent = true;
        _msg = 'Check $email — tap the link on this phone.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _msg = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Icon(Icons.hexagon_outlined,
                  size: 64, color: Color(0xFF3B82F6)),
              const SizedBox(height: 16),
              const Text('Terrastep',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text('Phase 2 — sign in so hexes sync to the cloud.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF8FA3C4))),
              const SizedBox(height: 28),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                enabled: !_sent,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'you@example.com',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              if (_busy)
                const Center(child: CircularProgressIndicator())
              else
                FilledButton(
                  onPressed: _sent ? null : _send,
                  child: Text(_sent ? 'Link sent' : 'Send magic link'),
                ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: widget.onOffline,
                child: const Text('Continue offline (local hexes only)'),
              ),
              if (_msg != null) ...[
                const SizedBox(height: 16),
                Text(_msg!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: _sent
                            ? const Color(0xFF86EFAC)
                            : const Color(0xFFFCA5A5))),
              ],
              const Spacer(),
              Text('project ${SupabaseEnv.ref}',
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
            ],
          ),
        ),
      ),
    );
  }
}
