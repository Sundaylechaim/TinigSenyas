import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tinigsenyas/main.dart';
import 'package:tinigsenyas/providers/theme_provider.dart';
import 'package:tinigsenyas/services/connectivity_service.dart';
import 'package:tinigsenyas/services/settings_service.dart';

void main() {
  testWidgets('App opens the landing page with its main tools', (
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
        ],
        child: const TinigSenyasApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('TinigSenyas'), findsWidgets);
    expect(find.byKey(const Key('landing_brand_logo')), findsOneWidget);
    expect(find.byKey(const Key('landing_settings_button')), findsOneWidget);
    expect(find.text('Mas madaling magkaintindihan.'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Senyas sa teksto at boses'),
      200,
    );
    expect(find.text('Senyas sa teksto at boses'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Boses sa live caption'), 200);
    expect(find.text('Boses sa live caption'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Mag-type ng mensahe'), 200);
    expect(find.text('Mag-type ng mensahe'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    connectivity.dispose();
  });

  testWidgets('Dark mode switch starts light and changes with one click', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearAllTestValues);

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
        ],
        child: const TinigSenyasApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(
      Theme.of(tester.element(find.text('TinigSenyas').first)).brightness,
      Brightness.light,
    );
    await tester.tap(find.byTooltip('Dark mode'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(
      Theme.of(tester.element(find.text('TinigSenyas').first)).brightness,
      Brightness.dark,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    connectivity.dispose();
  });
}
