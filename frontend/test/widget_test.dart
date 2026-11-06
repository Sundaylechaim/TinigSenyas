import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tinigsenyas/main.dart';
import 'package:tinigsenyas/providers/theme_provider.dart';
import 'package:tinigsenyas/services/connectivity_service.dart';
import 'package:tinigsenyas/services/settings_service.dart';

void main() {
  testWidgets('App loads home screen', (WidgetTester tester) async {
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
    await tester.pumpAndSettle();

    // From landing page, navigate to dashboard to test the home screen
    final appbarDashboardBtn = find.byKey(const Key('appbar_dashboard_button'));
    if (appbarDashboardBtn.evaluate().isNotEmpty) {
      await tester.tap(appbarDashboardBtn);
      await tester.pumpAndSettle();
    }

    expect(find.text('TinigSenyas'), findsWidgets);
    expect(find.text('Sign to Text & Voice'), findsOneWidget);
    expect(find.text('Speech to Text & Signs'), findsOneWidget);

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
    await tester.pumpAndSettle();

    final appbarDashboardBtn = find.byKey(const Key('appbar_dashboard_button'));
    if (appbarDashboardBtn.evaluate().isNotEmpty) {
      await tester.tap(appbarDashboardBtn);
      await tester.pumpAndSettle();
    }

    expect(
      Theme.of(tester.element(find.text('TinigSenyas').first)).brightness,
      Brightness.light,
    );
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();

    final darkModeSwitch = tester.widget<SwitchListTile>(
      find.byType(SwitchListTile).first,
    );
    expect(darkModeSwitch.value, isFalse);

    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
      isTrue,
    );
    expect(
      Theme.of(tester.element(find.text('Dark Mode'))).brightness,
      Brightness.dark,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    connectivity.dispose();
  });
}
