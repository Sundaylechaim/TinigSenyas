import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tinigsenyas/main.dart';
import 'package:tinigsenyas/providers/theme_provider.dart';
import 'package:tinigsenyas/screens/text_to_sign_screen.dart';
import 'package:tinigsenyas/services/connectivity_service.dart';
import 'package:tinigsenyas/services/settings_service.dart';
import 'package:tinigsenyas/services/tts_service.dart';

class _TestTtsService extends TtsService {
  _TestTtsService(super.settings);

  @override
  Future<List<Map<String, String>>> getAvailableVoices() async => const [];
}

void main() {
  testWidgets('TextToSignScreen previews recognized and unavailable words', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: TextToSignScreen(initialText: 'Kamusta ka')),
    );
    await tester.pump();
    for (
      var i = 0;
      i < 200 && find.text('Preview available FSL signs').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }

    await tester.scrollUntilVisible(
      find.text('Sign sequence'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('1/1 supported'), findsOneWidget);
    expect(find.text('Kamusta ka'), findsAtLeastNWidgets(2));
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Kamusta unknownword');
    await tester.ensureVisible(find.text('Preview available FSL signs'));
    await tester.tap(find.text('Preview available FSL signs'));
    // Unfocus happens inside _preparePreview(); pump frames instead of
    // pumpAndSettle so any pending network image / cursor frame cannot hang.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.scrollUntilVisible(
      find.text('1/2 supported'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('1/2 supported'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Unavailable words are not translated in the animation.'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text('Unavailable words are not translated in the animation.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('MainNavigationScreen exposes six tabs including Settings', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.init();
    final connectivity = ConnectivityService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(settings),
          ),
          Provider<ConnectivityService>.value(value: connectivity),
          Provider<TtsService>.value(value: _TestTtsService(settings)),
        ],
        child: const MaterialApp(home: MainNavigationScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final navBar = find.byType(NavigationBar);
    expect(
      find.descendant(of: navBar, matching: find.text('Home')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: navBar, matching: find.text('Sign')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: navBar, matching: find.text('Type')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: navBar, matching: find.text('Voice')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: navBar, matching: find.text('History')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: navBar, matching: find.text('Settings')),
      findsOneWidget,
    );

    await tester.tap(find.descendant(of: navBar, matching: find.text('Type')));
    await tester.pump();

    expect(find.text('Type & Speak · FSL Signs'), findsOneWidget);

    await tester.tap(
      find.descendant(of: navBar, matching: find.text('Settings')),
    );
    await tester.pump();
    expect(tester.widget<NavigationBar>(navBar).selectedIndex, 5);
    expect(find.text('Settings'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    connectivity.dispose();
  });
}
