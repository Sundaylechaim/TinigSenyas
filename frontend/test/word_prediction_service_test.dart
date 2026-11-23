import 'package:flutter_test/flutter_test.dart';
import 'package:tinigsenyas/services/word_prediction_service.dart';

void main() {
  test('server vocabulary augments built-in spelling suggestions once', () {
    final service = WordPredictionService(customDictionary: ['Kumusta']);
    service.addVocabulary(['Salamat', ' salamat ', 'Tulong']);

    expect(service.getPredictions('sala'), ['Salamat']);
    expect(service.getPredictions('tul'), ['Tulong']);
    expect(service.getPredictions('kum'), ['Kumusta']);
  });
}
