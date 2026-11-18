import 'dart:convert';

import 'package:flutter/services.dart';

class SignAnimationCatalog {
  const SignAnimationCatalog._();

  static const String manifestAsset = 'assets/sign_animations/manifest.json';

  static Future<Set<String>> load() async {
    final rawManifest = await rootBundle.loadString(manifestAsset);
    final decoded = jsonDecode(rawManifest);
    if (decoded is! List<dynamic>) {
      throw const FormatException('Invalid sign animation manifest.');
    }
    return decoded.whereType<String>().toSet();
  }

  static String slug(String label) => label
      .trim()
      .toLowerCase()
      .replaceAll('ñ', 'enye')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');

  static String? assetForLabel(Set<String> available, String label) {
    final slug = SignAnimationCatalog.slug(label);
    if (!available.contains(slug)) return null;
    return 'assets/sign_animations/$slug.gif';
  }
}
