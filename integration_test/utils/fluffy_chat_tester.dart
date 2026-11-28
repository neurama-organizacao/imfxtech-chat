// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/main.dart' as app;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Max time to wait for a single frame. The live binding's `pump()` only
/// completes when the engine draws a frame, so without this limit a test
/// hangs forever when the app is not drawing (e.g. not in foreground).
const _frameTimeout = Duration(seconds: 15);

/// Max time for `pumpAndSettle()` (the default is 10 minutes).
const _settleTimeout = Duration(seconds: 60);

extension type FluffyChatTester(WidgetTester tester) {
  static int _printCounter = 1;

  void _print(String message) {
    debugPrint(
      '[INTEGRATION TEST] ${DateTime.now().toIso8601String()} | Step ${_printCounter++} -  $message',
    );
  }

  Future<void> _pump(Duration duration) => tester
      .pump(duration)
      .timeout(
        _frameTimeout,
        onTimeout: () => throw Exception(
          '⏱️ No frame rendered within ${_frameTimeout.inSeconds}s (app not drawing / not in foreground?)',
        ),
      );

  Future<void> _settle() => tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    _settleTimeout,
  );

  Future<bool> isVisible(
    Object object, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final end = DateTime.now().add(timeout);
    while (object.toFinder().evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) {
        return false;
      }
      await _pump(const Duration(milliseconds: 500));
    }
    return true;
  }

  Future<void> waitFor(
    Object object, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _print('👀 Waiting for "$object" (${timeout.inSeconds}s)');
    final end = DateTime.now().add(timeout);
    while (object.toFinder().evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) {
        throw Exception('⏱️ Timed out waiting for "$object"!');
      }
      await _pump(const Duration(milliseconds: 500));
    }
  }

  Future<Finder> _ensureVisible(Object object, {int? index}) async {
    var finder = object.toFinder();
    if (finder.evaluate().isEmpty) await waitFor(object);

    if (finder.evaluate().length > 1) {
      if (index == null) {
        throw Exception(
          '⚠️ Found ${finder.evaluate().length} "$object" objects. Please specify an index!',
        );
      }
      if (finder.evaluate().length <= index) {
        throw Exception(
          '⚠️ Found ${finder.evaluate().length} "$object" objects. So index $index does not exist!',
        );
      }
      finder = finder.at(index);
    }
    return finder;
  }

  Future<void> tapOn(
    Object object, {
    int? index,
    bool pumpAndSettle = true,
  }) async {
    final finder = await _ensureVisible(object, index: index);

    _print('👆 Tapping on "$object"');
    await tester.tap(finder);
    if (pumpAndSettle) await _settle();
  }

  Future<void> goBack() => tapOn(find.byTooltip('Back'));

  Future<void> enterText(
    Object object,
    String text, {
    int? index,
    bool pumpAndSettle = true,
  }) async {
    final finder = await _ensureVisible(object, index: index);

    _print('⌨️ Enter "$text" into "$object"');
    await tester.enterText(finder, text);
    FocusManager.instance.primaryFocus?.unfocus();
    if (pumpAndSettle) await _settle();
  }

  Future<void> scrollUntilVisible(
    Object object, {
    int? index,
    Object? scrollable,
  }) async {
    _print('📜 Scrolling to "$object"');
    await tester.scrollUntilVisible(
      object.toFinder(),
      500.0,
      scrollable: scrollable?.toFinder() ?? find.byType(Scrollable).last,
    );
    await _settle();
  }
}

extension on Object {
  Finder toFinder() => switch (this) {
    final Finder finder => finder,
    final String string => find.text(string),
    final Key key => find.byKey(key),
    final IconData icon => find.byIcon(icon),
    final Type type => find.byType(type),
    final Widget widget => find.byWidget(widget),
    _ => throw Exception('Unsupported finder type: $runtimeType'),
  };
}

extension StartTest on WidgetTester {
  Future<FluffyChatTester> startFluffyChatTest() async {
    app.main(['integration_test']);

    final tester = FluffyChatTester(this);
    tester._print('🚀 app.main called');
    return tester;
  }
}
