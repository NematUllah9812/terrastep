/// Publishable project identity. Safe to commit (see SECURITY.md §2).
///
/// The anon JWT is **not** stored here — CI rejects raw JWTs, and the
/// key is still extractable from any APK. Pass it at build time:
///
/// ```
/// flutter build apk --dart-define=SUPABASE_ANON_KEY=eyJ...
/// ```
class SupabaseEnv {
  static const url = 'https://iaoqwxcyjkpvpqwoszih.supabase.co';
  static const ref = 'iaoqwxcyjkpvpqwoszih';
  static const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const redirect = 'io.terrastep.app://login-callback/';

  static bool get configured => anonKey.isNotEmpty;
}
