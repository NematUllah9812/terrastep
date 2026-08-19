/// Single source of truth for the overlay dump header.
///
/// Bump this **together with** `pubspec.yaml` `version:` on every APK.
/// Testers confirm they installed the right build by the first line of
/// the overlay copy. If the two drift, field reports become unusable.
const String kAppVersion = '0.1.6+7';
