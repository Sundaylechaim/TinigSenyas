/// Selects an available on-device Filipino/Tagalog speech locale.
///
/// Android's `speech_to_text` locale list represents locales supported by the
/// on-device recognizer, so an empty result must not silently fall back to an
/// online/default-language recognizer.
String? selectOfflineFilipinoLocale(Iterable<String> localeIds) {
  final available = localeIds
      .map((locale) => locale.trim())
      .where((locale) => locale.isNotEmpty)
      .toList(growable: false);
  String normalize(String locale) => locale.replaceAll('_', '-').toLowerCase();

  for (final preferred in const ['fil-ph', 'tl-ph', 'fil', 'tl']) {
    for (final locale in available) {
      if (normalize(locale) == preferred) return locale;
    }
  }

  for (final locale in available) {
    final normalized = normalize(locale);
    if (normalized.startsWith('fil-') ||
        normalized.startsWith('tl-') ||
        normalized.startsWith('tgl-')) {
      return locale;
    }
  }
  return null;
}
