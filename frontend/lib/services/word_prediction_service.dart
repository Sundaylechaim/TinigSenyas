import 'dart:math';

/// Service responsible for assembling sequentially fingerspelled FSL letters (A-Z)
/// into words and sentences, predicting words using a Filipino/Tagalog lexicon,
/// and providing fuzzy autocorrection (Levenshtein distance).
class WordPredictionService {
  /// Comprehensive Tagalog/Filipino and FSL transactional vocabulary
  static const List<String> defaultDictionary = [
    // Common Greetings & Polite Expressions
    'Kamusta', 'Kamusta ka', 'Salamat', 'Walang anuman', 'Magandang Umaga',
    'Magandang Hapon', 'Magandang Gabi', 'Magkita tayo bukas', 'Paalam',
    'Mabuti', 'Mabuhay', 'Ingat', 'Pasensya', 'Pakiusap',

    // Core Affirmatives & Negatives
    'Oo', 'Hindi', 'Alam', 'Hindi alam', 'Naiintindihan', 'Hindi maintindihan',
    'Nauunawaan', 'Tama', 'Mali', 'Siguro', 'Baka',

    // Family & People
    'Ama', 'Ina', 'Tatay', 'Nanay', 'Anak', 'Anak na Lalaki', 'Anak na Babae',
    'Lolo', 'Lola', 'Tito', 'Tita', 'Pinsan', 'Magulang', 'Kapatid',
    'Lalaki', 'Babae', 'Kaibigan', 'Tao', 'Bata',

    // Health, Accessibility & Senses
    'Bingi', 'Mahirap makarinig', 'Bulag', 'Bingi at bulag', 'Pipi',
    'Nasa wheelchair', 'May kapansanan', 'Sakit', 'Maysakit', 'Lagnat',
    'Ubo', 'Sipon', 'Sakit ng ulo', 'Gamot', 'Doktor', 'Ospital',

    // Time & Days
    'Ngayon', 'Bukas', 'Kahapon', 'Araw', 'Gabi', 'Umaga', 'Hapon',
    'Lunes', 'Martes', 'Miyerkules', 'Huwebes', 'Biyernes', 'Sabado', 'Linggo',
    'Enero', 'Pebrero', 'Marso', 'Abril', 'Mayo', 'Hunyo',
    'Hulyo', 'Agosto', 'Setyembre', 'Oktubre', 'Nobyembre', 'Disyembre',

    // Colors
    'Pula', 'Bughaw', 'Asul', 'Berde', 'Dilaw', 'Puti', 'Itim',
    'Kayumanggi', 'Lila', 'Rosas', 'Kulay Rosas', 'Kahel', 'Abo',

    // Numbers & Quantities
    'Isa', 'Dalawa', 'Tatlo', 'Apat', 'Lima', 'Anim', 'Pito', 'Walo', 'Siyam', 'Sampu',
    'Marami', 'Konti', 'Lahat', 'Wala',

    // Food & Dining
    'Tubig', 'Kape', 'Gatas', 'Tsaa', 'Juice', 'Kanin', 'Tinapay', 'Isda',
    'Karne', 'Manok', 'Itlog', 'Prutas', 'Gulay', 'Asukal', 'Kain', 'Inom',

    // Common Verbs & Adjectives
    'Gusto', 'Ayaw', 'Kailangan', 'Tulong', 'Punta', 'Alis', 'Uwi', 'Bili',
    'Mabagal', 'Mabilis', 'Madilim', 'Maliwanag', 'Mainit', 'Malamig',
    'Masaya', 'Malungkot', 'Maganda', 'Pogi', 'Mahal', 'Mura'
  ];

  final List<String> _dictionary;

  WordPredictionService({List<String>? customDictionary})
      : _dictionary = customDictionary ?? defaultDictionary;

  /// Returns auto-complete and predictive candidate words for the current letter prefix.
  List<String> getPredictions(String prefix, {int maxResults = 4}) {
    final clean = prefix.trim().toLowerCase();
    if (clean.isEmpty) return [];

    final exactMatches = <String>[];
    final prefixMatches = <String>[];
    final fuzzyMatches = <String>[];

    for (final word in _dictionary) {
      final wLower = word.toLowerCase();
      if (wLower == clean) {
        exactMatches.add(word);
      } else if (wLower.startsWith(clean)) {
        prefixMatches.add(word);
      } else if (clean.length >= 3 && _levenshteinDistance(clean, wLower.substring(0, min(clean.length, wLower.length))) <= 1) {
        fuzzyMatches.add(word);
      }
    }

    // Sort prefix matches by length (shorter / most direct first)
    prefixMatches.sort((a, b) => a.length.compareTo(b.length));

    final combined = <String>{
      ...exactMatches,
      ...prefixMatches,
      ...fuzzyMatches,
    }.toList();

    return combined.take(maxResults).toList();
  }

  /// Calculates Levenshtein Distance for fuzzy correction of fingerspelling typos.
  int _levenshteinDistance(String s1, String s2) {
    if (s1 == s2) return 0;
    if (s1.isEmpty) return s2.length;
    if (s2.isEmpty) return s1.length;

    List<int> v0 = List<int>.generate(s2.length + 1, (i) => i);
    List<int> v1 = List<int>.filled(s2.length + 1, 0);

    for (int i = 0; i < s1.length; i++) {
      v1[0] = i + 1;
      for (int j = 0; j < s2.length; j++) {
        int cost = (s1[i] == s2[j]) ? 0 : 1;
        v1[j + 1] = min(v1[j] + 1, min(v0[j + 1] + 1, v0[j] + cost));
      }
      for (int j = 0; j <= s2.length; j++) {
        v0[j] = v1[j];
      }
    }
    return v1[s2.length];
  }
}

