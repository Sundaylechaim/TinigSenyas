import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinigsenyas/services/sign_animation_catalog.dart';
import 'package:tinigsenyas/widgets/gesture_motion_replay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled catalog resolves offline phrase clips', () async {
    final available = await SignAnimationCatalog.load();

    expect(available.length, 103);
    expect(
      SignAnimationCatalog.assetForLabel(available, 'Kamusta ka'),
      'assets/sign_animations/kamusta_ka.gif',
    );
    expect(SignAnimationCatalog.assetForLabel(available, 'unknown'), isNull);
  });

  testWidgets('gesture motion replay animates tracked landmark frames', (
    WidgetTester tester,
  ) async {
    final frames = List<List<List<Offset>>>.generate(
      10,
      (frameIndex) => [
        List<Offset>.generate(
          21,
          (pointIndex) => Offset(
            0.25 + pointIndex * 0.01,
            0.3 + frameIndex * 0.01 + pointIndex * 0.005,
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 100,
              child: GestureMotionReplay(frames: frames),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byType(GestureMotionReplay), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
