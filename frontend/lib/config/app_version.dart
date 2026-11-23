/// Application release identity. Keep buildNumber increasing for Android and
/// Shorebird even when the public baseline version is reset to v1.0.0.
class AppVersion {
  AppVersion._();

  static const name = '1.0.0';
  static const buildNumber = 2019;
  static const full = '$name+$buildNumber';
}
