// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

// The test_api package is not for general use... it's literally for our use.
// ignore: deprecated_member_use
import 'package:test_api/test_api.dart' as test_package;

import 'all_elements.dart';
import 'binding.dart';
import 'controller.dart';
import 'finders.dart';
import 'matchers.dart';
import 'restoration.dart';
import 'test_async_utils.dart';
import 'test_compat.dart';
import 'test_pointer.dart';
import 'test_text_input.dart';

// Keep users from needing multiple imports to test semantics.
export 'package:flutter/rendering.dart' show SemanticsHandle;

// We re-export the test package minus some features that we reimplement.
//
// Specifically:
//
//  - test, group, setUpAll, tearDownAll, setUp, tearDown, and expect would
//    conflict with our own implementations in test_compat.dart. This handles
//    setting up a declarer when one is not defined, which can happen when a
//    test is executed via `flutter run`.
//
//  - expect is reimplemented below, to catch incorrect async usage.
//
//  - isInstanceOf is reimplemented in matchers.dart because we don't want to
//    mark it as deprecated (ours is just a method, not a class).
//
// The test_api package has a deprecation warning to discourage direct use but
// that doesn't apply here.
// ignore: deprecated_member_use
export 'package:test_api/test_api.dart' hide
  test,
  group,
  setUpAll,
  tearDownAll,
  setUp,
  tearDown,
  expect,
  isInstanceOf;

/// Signature for callback to [testWidgets] and [benchmarkWidgets].
typedef WidgetTesterCallback = Future<void> Function(WidgetTester widgetTester);

/// Runs the [callback] inside the Flutter test environment.
///
/// Use this function for testing custom [StatelessWidget]s and
/// [StatefulWidget]s.
///
/// The callback can be asynchronous (using `async`/`await` or
/// using explicit [Future]s).
///
/// There are two kinds of timeouts that can be specified. The `timeout`
/// argument specifies the backstop timeout implemented by the `test` package.
/// If set, it should be relatively large (minutes). It defaults to ten minutes
/// for tests run by `flutter test`, and is unlimited for tests run by `flutter
/// run`; specifically, it defaults to
/// [TestWidgetsFlutterBinding.defaultTestTimeout].
///
/// The `initialTimeout` argument specifies the timeout implemented by the
/// `flutter_test` package itself. If set, it may be relatively small (seconds),
/// as it is automatically increased for some expensive operations, and can also
/// be manually increased by calling
/// [AutomatedTestWidgetsFlutterBinding.addTime]. The effective maximum value of
/// this timeout (even after calling `addTime`) is the one specified by the
/// `timeout` argument.
///
/// In general, timeouts are race conditions and cause flakes, so best practice
/// is to avoid the use of timeouts in tests.
///
/// If the `semanticsEnabled` parameter is set to `true`,
/// [WidgetTester.ensureSemantics] will have been called before the tester is
/// passed to the `callback`, and that handle will automatically be disposed
/// after the callback is finished. It defaults to true.
///
/// This function uses the [test] function in the test package to
/// register the given callback as a test. The callback, when run,
/// will be given a new instance of [WidgetTester]. The [find] object
/// provides convenient widget [Finder]s for use with the
/// [WidgetTester].
///
/// When the [variant] argument is set, [testWidgets] will run the test once for
/// each value of the [TestVariant.values]. If [variant] is not set, the test
/// will be run once using the base test environment.
///
/// If either [exclude] or [skip] is `true`, then the test will be skipped. The
/// difference is that [skip] is a temporary way to disable a problematic test
/// while a fix is being developed. It should have a comment after it with a
/// link to a tracking issue for the work on re-enabling the test.
///
/// [exclude] is used to indicate that the test is not designed to run under
/// the condition given and should always be skipped when it is `true`.
///
/// If the [tags] are passed, they declare user-defined tags that are implemented by
/// the `test` package.
///
/// See also:
///
///  * [AutomatedTestWidgetsFlutterBinding.addTime] to learn more about
///    timeout and how to manually increase timeouts.
///
/// ## Sample code
///
/// ```dart
/// testWidgets('MyWidget', (WidgetTester tester) async {
///   await tester.pumpWidget(MyWidget());
///   await tester.tap(find.text('Save'));
///   expect(find.text('Success'), findsOneWidget);
/// });
/// ```
///
/// ### Excluded test
/// ```dart
/// testWidgets('Some test that will never make sense for the web', (WidgetTester tester) async {
///   // test code
/// }, exclude: isBrowser);
/// ```
///
/// ### Skipped test
/// ```dart
/// testWidgets('Some flaky test', (WidgetTester tester) async {
///   // test code
/// }, skip: true); // https://github.com/flutter/flutter/issues/12345
/// ```
@isTest
void testWidgets(
  String description,
  WidgetTesterCallback callback, {
  bool? skip,
  bool? exclude,
  test_package.Timeout? timeout,
  Duration? initialTimeout,
  bool semanticsEnabled = true,
  TestVariant<Object?> variant = const DefaultTestVariant(),
  dynamic tags,
}) {
  assert(variant != null);
  assert(variant.values.isNotEmpty, 'There must be at least one value to test in the testing variant.');
  final TestWidgetsFlutterBinding binding = TestWidgetsFlutterBinding.ensureInitialized() as TestWidgetsFlutterBinding;
  final WidgetTester tester = WidgetTester._(binding);
  for (final dynamic value in variant.values) {
    final String variationDescription = variant.describeValue(value);
    final String combinedDescription = variationDescription.isNotEmpty ? '$description ($variationDescription)' : description;
    test(
      combinedDescription,
      () {
        tester._testDescription = combinedDescription;
        SemanticsHandle? semanticsHandle;
        if (semanticsEnabled == true) {
          semanticsHandle = tester.ensureSemantics();
        }
        tester._recordNumberOfSemanticsHandles();
        test_package.addTearDown(binding.postTest);
        return binding.runTest(
          () async {
            binding.reset(); // TODO(ianh): the binding should just do this itself in _runTest
            debugResetSemanticsIdCounter();
            Object? memento;
            try {
              memento = await variant.setUp(value);
              await callback(tester);
            } finally {
              await variant.tearDown(value, memento);
            }
            semanticsHandle?.dispose();
          },
          tester._endOfTestVerifications,
          description: combinedDescription,
          timeout: initialTimeout,
        );
      },
      skip: exclude == true || skip == true,
      timeout: timeout ?? binding.defaultTestTimeout,
      tags: tags,
    );
  }
}

/// An abstract base class for describing test environment variants.
///
/// These serve as elements of the `variants` argument to [testWidgets].
///
/// Use care when adding more testing variants: it multiplies the number of
/// tests which run. This can drastically increase the time it takes to run all
/// the tests.
abstract class TestVariant<T> {
  /// A const constructor so that subclasses can be const.
  const TestVariant();

  /// Returns an iterable of the variations that this test dimension represents.
  ///
  /// The variations returned should be unique so that the same variation isn't
  /// needlessly run twice.
  Iterable<T> get values;

  /// Returns the string that will be used to both add to the test description, and
  /// be printed when a test fails for this variation.
  String describeValue(T value);

  /// A function that will be called before each value is tested, with the
  /// value that will be tested.
  ///
  /// This function should preserve any state needed to restore the testing
  /// environment back to its base state when [tearDown] is called in the
  /// `Object` that is returned. The returned object will then be passed to
  /// [tearDown] as a `memento` when the test is complete.
  Future<Object?> setUp(T value);

  /// A function that is guaranteed to be called after a value is tested, even
  /// if it throws an exception.
  ///
  /// Calling this function must return the testing environment back to the base
  /// state it was in before [setUp] was called. The [memento] is the object
  /// returned from [setUp] when it was called.
  Future<void> tearDown(T value, covariant Object? memento);
}

/// The [TestVariant] that represents the "default" test that is run if no
/// `variants` iterable is specified for [testWidgets].
///
/// This variant can be added into a list of other test variants to provide
/// a "control" test where nothing is changed from the base test environment.
class DefaultTestVariant extends TestVariant<void> {
  /// A const constructor for a [DefaultTestVariant].
  const DefaultTestVariant();

  @override
  Iterable<void> get values => const <void>[null];

  @override
  String describeValue(void value) => '';

  @override
  Future<void> setUp(void value) async {}

  @override
  Future<void> tearDown(void value, void memento) async {}
}

/// A [TestVariant] that runs tests with [debugDefaultTargetPlatformOverride]
/// set to different values of [TargetPlatform].
class TargetPlatformVariant extends TestVariant<TargetPlatform> {
  /// Creates a [TargetPlatformVariant] that tests the given [values].
  const TargetPlatformVariant(this.values);

  /// Creates a [TargetPlatformVariant] that tests all values from
  /// the [TargetPlatform] enum.
  TargetPlatformVariant.all() : values = TargetPlatform.values.toSet();

  /// Creates a [TargetPlatformVariant] that includes platforms that are
  /// considered desktop platforms.
  TargetPlatformVariant.desktop() : values = <TargetPlatform>{
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  };

  /// Creates a [TargetPlatformVariant] that includes platforms that are
  /// considered mobile platforms.
  TargetPlatformVariant.mobile() : values = <TargetPlatform>{
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.fuchsia,
  };

  /// Creates a [TargetPlatformVariant] that tests only the given value of
  /// [TargetPlatform].
  TargetPlatformVariant.only(TargetPlatform platform) : values = <TargetPlatform>{platform};

  @override
  final Set<TargetPlatform> values;

  @override
  String describeValue(TargetPlatform value) => value.toString();

  @override
  Future<TargetPlatform?> setUp(TargetPlatform value) async {
    final TargetPlatform? previousTargetPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = value;
    return previousTargetPlatform;
  }

  @override
  Future<void> tearDown(TargetPlatform value, TargetPlatform? memento) async {
    debugDefaultTargetPlatformOverride = memento;
  }
}

/// A [TestVariant] that runs separate tests with each of the given values.
///
/// To use this variant, define it before the test, and then access
/// [currentValue] inside the test.
///
/// The values are typically enums, but they don't have to be. The `toString`
/// for the given value will be used to describe the variant. Values will have
/// their type name stripped from their `toString` output, so that enum values
/// will only print the value, not the type.
///
/// {@tool snippet}
/// This example shows how to set up the test to access the [currentValue]. In
/// this example, two tests will be run, one with `value1`, and one with
/// `value2`. The test with `value2` will fail. The names of the tests will be:
///
///   - `Test handling of TestScenario (value1)`
///   - `Test handling of TestScenario (value2)`
///
/// ```dart
/// enum TestScenario {
///   value1,
///   value2,
///   value3,
/// }
///
/// final ValueVariant<TestScenario> variants = ValueVariant<TestScenario>(
///   <TestScenario>{value1, value2},
/// );
///
/// testWidgets('Test handling of TestScenario', (WidgetTester tester) {
///   expect(variants.currentValue, equals(value1));
/// }, variant: variants);
/// ```
/// {@end-tool}
class ValueVariant<T> extends TestVariant<T> {
  /// Creates a [ValueVariant] that tests the given [values].
  ValueVariant(this.values);

  /// Returns the value currently under test.
  T? get currentValue => _currentValue;
  T? _currentValue;

  @override
  final Set<T> values;

  @override
  String describeValue(T value) => value.toString().replaceFirst('$T.', '');

  @override
  Future<T> setUp(T value) async => _currentValue = value;

  @override
  Future<void> tearDown(T value, T memento) async {}
}

/// The warning message to show when a benchmark is performed with assert on.
const String kDebugWarning = '''
┏╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍┓
┇ ⚠    THIS BENCHMARK IS BEING RUN IN DEBUG MODE     ⚠  ┇
┡╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍┦
│                                                       │
│  Numbers obtained from a benchmark while asserts are  │
│  enabled will not accurately reflect the performance  │
│  that will be experienced by end users using release  ╎
│  builds. Benchmarks should be run using this command  ╎
│  line:  "flutter run --profile test.dart" or          ┊
│  or "flutter drive --profile -t test.dart".           ┊
│                                                       ┊
└─────────────────────────────────────────────────╌┄┈  🐢
''';

/// Runs the [callback] inside the Flutter benchmark environment.
///
/// Use this function for benchmarking custom [StatelessWidget]s and
/// [StatefulWidget]s when you want to be able to use features from
/// [TestWidgetsFlutterBinding]. The callback, when run, will be given
/// a new instance of [WidgetTester]. The [find] object provides
/// convenient widget [Finder]s for use with the [WidgetTester].
///
/// The callback can be asynchronous (using `async`/`await` or using
/// explicit [Future]s). If it is, then [benchmarkWidgets] will return
/// a [Future] that completes when the callback's does. Otherwise, it
/// will return a Future that is always complete.
///
/// If the callback is asynchronous, make sure you `await` the call
/// to [benchmarkWidgets], otherwise it won't run!
///
/// If the `semanticsEnabled` parameter is set to `true`,
/// [WidgetTester.ensureSemantics] will have been called before the tester is
/// passed to the `callback`, and that handle will automatically be disposed
/// after the callback is finished.
///
/// Benchmarks must not be run in checked mode, because the performance is not
/// representative. To avoid this, this function will print a big message if it
/// is run in checked mode. Unit tests of this method pass `mayRunWithAsserts`,
/// but it should not be used for actual benchmarking.
///
/// Example:
///
///     main() async {
///       assert(false); // fail in checked mode
///       await benchmarkWidgets((WidgetTester tester) async {
///         await tester.pumpWidget(MyWidget());
///         final Stopwatch timer = Stopwatch()..start();
///         for (int index = 0; index < 10000; index += 1) {
///           await tester.tap(find.text('Tap me'));
///           await tester.pump();
///         }
///         timer.stop();
///         debugPrint('Time taken: ${timer.elapsedMilliseconds}ms');
///       });
///       exit(0);
///     }
Future<void> benchmarkWidgets(
  WidgetTesterCallback callback, {
  bool mayRunWithAsserts = false,
  bool semanticsEnabled = false,
}) {
  assert(() {
    if (mayRunWithAsserts)
      return true;
    print(kDebugWarning);
    return true;
  }());
  final TestWidgetsFlutterBinding binding = TestWidgetsFlutterBinding.ensureInitialized() as TestWidgetsFlutterBinding;
  assert(binding is! AutomatedTestWidgetsFlutterBinding);
  final WidgetTester tester = WidgetTester._(binding);
  SemanticsHandle? semanticsHandle;
  if (semanticsEnabled == true) {
    semanticsHandle = tester.ensureSemantics();
  }
  tester._recordNumberOfSemanticsHandles();
  return binding.runTest(
    () async {
      await callback(tester);
      semanticsHandle?.dispose();
    },
    tester._endOfTestVerifications,
  );
}

/// Assert that `actual` matches `matcher`.
///
/// See [test_package.expect] for details. This is a variant of that function
/// that additionally verifies that there are no asynchronous APIs
/// that have not yet resolved.
///
/// See also:
///
///  * [expectLater] for use with asynchronous matchers.
void expect(
  dynamic actual,
  dynamic matcher, {
  String? reason,
  dynamic skip, // true or a String
}) {
  TestAsyncUtils.guardSync();
  test_package.expect(actual, matcher, reason: reason, skip: skip);
}

/// Assert that `actual` matches `matcher`.
///
/// See [test_package.expect] for details. This variant will _not_ check that
/// there are no outstanding asynchronous API requests. As such, it can be
/// called from, e.g., callbacks that are run during build or layout, or in the
/// completion handlers of futures that execute in response to user input.
///
/// Generally, it is better to use [expect], which does include checks to ensure
/// that asynchronous APIs are not being called.
void expectSync(
  dynamic actual,
  dynamic matcher, {
  String? reason,
}) {
  test_package.expect(actual, matcher, reason: reason);
}

/// Just like [expect], but returns a [Future] that completes when the matcher
/// has finished matching.
///
/// See [test_package.expectLater] for details.
///
/// If the matcher fails asynchronously, that failure is piped to the returned
/// future where it can be handled by user code. If it is not handled by user
/// code, the test will fail.
Future<void> expectLater(
  dynamic actual,
  dynamic matcher, {
  String? reason,
  dynamic skip, // true or a String
}) {
  // We can't wrap the delegate in a guard, or we'll hit async barriers in
  // [TestWidgetsFlutterBinding] while we're waiting for the matcher to complete
  TestAsyncUtils.guardSync();
  return test_package.expectLater(actual, matcher, reason: reason, skip: skip)
           .then<void>((dynamic value) => null);
}

/// Class that programmatically interacts with widgets and the test environment.
///
/// For convenience, instances of this class (such as the one provided by
/// `testWidget`) can be used as the `vsync` for `AnimationController` objects.
class WidgetTester extends WidgetController implements HitTestDispatcher, TickerProvider {
  WidgetTester._(TestWidgetsFlutterBinding binding) : super(binding) {
    if (binding is LiveTestWidgetsFlutterBinding)
      binding.deviceEventDispatcher = this;
  }

  /// The description string of the test currently being run.
  String get testDescription => _testDescription;
  String _testDescription = '';

  /// The binding instance used by the testing framework.
  @override
  TestWidgetsFlutterBinding get binding => super.binding as TestWidgetsFlutterBinding;

  /// Renders the UI from the given [widget].
  ///
  /// Calls [runApp] with the given widget, then triggers a frame and flushes
  /// microtasks, by calling [pump] with the same `duration` (if any). The
  /// supplied [EnginePhase] is the final phase reached during the pump pass; if
  /// not supplied, the whole pass is executed.
  ///
  /// Subsequent calls to this is different from [pump] in that it forces a full
  /// rebuild of the tree, even if [widget] is the same as the previous call.
  /// [pump] will only rebuild the widgets that have changed.
  ///
  /// This method should not be used as the first parameter to an [expect] or
  /// [expectLater] call to test that a widget throws an exception. Instead, use
  /// [TestWidgetsFlutterBinding.takeException].
  ///
  /// {@tool snippet}
  /// ```dart
  /// testWidgets('MyWidget asserts invalid bounds', (WidgetTester tester) async {
  ///   await tester.pumpWidget(MyWidget(-1));
  ///   expect(tester.takeException(), isAssertionError); // or isNull, as appropriate.
  /// });
  /// ```
  /// {@end-tool}
  ///
  /// See also [LiveTestWidgetsFlutterBindingFramePolicy], which affects how
  /// this method works when the test is run with `flutter run`.
  Future<void> pumpWidget(
    Widget widget, [
    Duration? duration,
    EnginePhase phase = EnginePhase.sendSemanticsUpdate,
  ]) {
    return TestAsyncUtils.guard<void>(() {
      binding.attachRootWidget(widget);
      binding.scheduleFrame();
      return binding.pump(duration, phase);
    });
  }

  @override
  Future<List<Duration>> handlePointerEventRecord(Iterable<PointerEventRecord> records) {
    assert(records != null);
    assert(records.isNotEmpty);
    return TestAsyncUtils.guard<List<Duration>>(() async {
      final List<Duration> handleTimeStampDiff = <Duration>[];
      DateTime? startTime;
      for (final PointerEventRecord record in records) {
        final DateTime now = binding.clock.now();
        startTime ??= now;
        // So that the first event is promised to receive a zero timeDiff
        final Duration timeDiff = record.timeDelay - now.difference(startTime);
        if (timeDiff.isNegative) {
          // Flush all past events
          handleTimeStampDiff.add(-timeDiff);
          for (final PointerEvent event in record.events) {
            binding.handlePointerEventForSource(event, source: TestBindingEventSource.test);
          }
        } else {
          await binding.pump();
          await binding.delayed(timeDiff);
          handleTimeStampDiff.add(
            binding.clock.now().difference(startTime) - record.timeDelay,
          );
          for (final PointerEvent event in record.events) {
            binding.handlePointerEventForSource(event, source: TestBindingEventSource.test);
          }
        }
      }
      await binding.pump();
      // This makes sure that a gesture is completed, with no more pointers
      // active.
      return handleTimeStampDiff;
    });
  }

  /// Triggers a frame after `duration` amount of time.
  ///
  /// This makes the framework act as if the application had janked (missed
  /// frames) for `duration` amount of time, and then received a "Vsync" signal
  /// to paint the application.
  ///
  /// For a [FakeAsync] environment (typically in `flutter test`), this advances
  /// time and timeout counting; for a live environment this delays `duration`
  /// time.
  ///
  /// This is a convenience function that just calls
  /// [TestWidgetsFlutterBinding.pump].
  ///
  /// See also [LiveTestWidgetsFlutterBindingFramePolicy], which affects how
  /// this method works when the test is run with `flutter run`.
  @override
  Future<void> pump([
    Duration? duration,
    EnginePhase phase = EnginePhase.sendSemanticsUpdate,
  ]) {
    return TestAsyncUtils.guard<void>(() => binding.pump(duration, phase));
  }

  /// Triggers a frame after `duration` amount of time, return as soon as the frame is drawn.
  ///
  /// This enables driving an artificially high CPU load by rendering frames in
  /// a tight loop. It must be used with the frame policy set to
  /// [LiveTestWidgetsFlutterBindingFramePolicy.benchmark].
  ///
  /// Similarly to [pump], this doesn't actually wait for `duration`, just
  /// advances the clock.
  Future<void> pumpBenchmark(Duration duration) async {
    assert(() {
      final TestWidgetsFlutterBinding widgetsBinding = binding;
      return widgetsBinding is LiveTestWidgetsFlutterBinding &&
              widgetsBinding.framePolicy == LiveTestWidgetsFlutterBindingFramePolicy.benchmark;
    }());

    dynamic caughtException;
    void handleError(dynamic error, StackTrace stackTrace) => caughtException ??= error;

    await Future<void>.microtask(() { binding.handleBeginFrame(duration); }).catchError(handleError);
    await idle();
    await Future<void>.microtask(() { binding.handleDrawFrame(); }).catchError(handleError);
    await idle();

    if (caughtException != null) {
      throw caughtException as Object;
    }
  }

  @override
  Future<int> pumpAndSettle([
    Duration duration = const Duration(milliseconds: 100),
    EnginePhase phase = EnginePhase.sendSemanticsUpdate,
    Duration timeout = const Duration(minutes: 10),
  ]) {
    assert(duration != null);
    assert(duration > Duration.zero);
    assert(timeout != null);
    assert(timeout > Duration.zero);
    assert(() {
      final WidgetsBinding binding = this.binding;
      if (binding is LiveTestWidgetsFlutterBinding &&
          binding.framePolicy == LiveTestWidgetsFlutterBindingFramePolicy.benchmark) {
        throw 'When using LiveTestWidgetsFlutterBindingFramePolicy.benchmark, '
              'hasScheduledFrame is never set to true. This means that pumpAndSettle() '
              'cannot be used, because it has no way to know if the application has '
              'stopped registering new frames.';
      }
      return true;
    }());
    return TestAsyncUtils.guard<int>(() async {
      final DateTime endTime = binding.clock.fromNowBy(timeout);
      int count = 0;
      do {
        if (binding.clock.now().isAfter(endTime))
          throw FlutterError('pumpAndSettle timed out');
        await binding.pump(duration, phase);
        count += 1;
      } while (binding.hasScheduledFrame);
      return count;
    });
  }

  /// Repeatedly pump frames that render the `target` widget with a fixed time
  /// `interval` as many as `maxDuration` allows.
  ///
  /// The `maxDuration` argument is required. The `interval` argument defaults to
  /// 16.683 milliseconds (59.94 FPS).
  Future<void> pumpFrames(
    Widget target,
    Duration maxDuration, [
    Duration interval = const Duration(milliseconds: 16, microseconds: 683),
  ]) {
    assert(maxDuration != null);
    // The interval following the last frame doesn't have to be within the fullDuration.
    Duration elapsed = Duration.zero;
    return TestAsyncUtils.guard<void>(() async {
      binding.attachRootWidget(target);
      binding.scheduleFrame();
      while (elapsed < maxDuration) {
        await binding.pump(interval);
        elapsed += interval;
      }
    });
  }

  /// Simulates restoring the state of the widget tree after the application
  /// is restarted.
  ///
  /// The method grabs the current serialized restoration data from the
  /// [RestorationManager], takes down the widget tree to destroy all in-memory
  /// state, and then restores the widget tree from the serialized restoration
  /// data.
  Future<void> restartAndRestore() async {
    assert(
      binding.restorationManager.debugRootBucketAccessed,
      'The current widget tree did not inject the root bucket of the RestorationManager and '
      'therefore no restoration data has been collected to restore from. Did you forget to wrap '
      'your widget tree in a RootRestorationScope?',
    );
    final Widget widget = (binding.renderViewElement! as RenderObjectToWidgetElement<RenderObject>).widget.child!;
    final TestRestorationData restorationData = binding.restorationManager.restorationData;
    runApp(Container(key: UniqueKey()));
    await pump();
    binding.restorationManager.restoreFrom(restorationData);
    return pumpWidget(widget);
  }

  /// Retrieves the current restoration data from the [RestorationManager].
  ///
  /// The returned [TestRestorationData] describes the current state of the
  /// widget tree under test and can be provided to [restoreFrom] to restore
  /// the widget tree to the state described by this data.
  Future<TestRestorationData> getRestorationData() async {
    assert(
      binding.restorationManager.debugRootBucketAccessed,
      'The current widget tree did not inject the root bucket of the RestorationManager and '
      'therefore no restoration data has been collected. Did you forget to wrap your widget tree '
      'in a RootRestorationScope?',
    );
    return binding.restorationManager.restorationData;
  }

  /// Restores the widget tree under test to the state described by the
  /// provided [TestRestorationData].
  ///
  /// The data provided to this method is usually obtained from
  /// [getRestorationData].
  Future<void> restoreFrom(TestRestorationData data) {
    binding.restorationManager.restoreFrom(data);
    return pump();
  }

  /// Runs a [callback] that performs real asynchronous work.
  ///
  /// This is intended for callers who need to call asynchronous methods where
  /// the methods spawn isolates or OS threads and thus cannot be executed
  /// synchronously by calling [pump].
  ///
  /// If callers were to run these types of asynchronous tasks directly in
  /// their test methods, they run the possibility of encountering deadlocks.
  ///
  /// If [callback] completes successfully, this will return the future
  /// returned by [callback].
  ///
  /// If [callback] completes with an error, the error will be caught by the
  /// Flutter framework and made available via [takeException], and this method
  /// will return a future that completes with `null`.
  ///
  /// Re-entrant calls to this method are not allowed; callers of this method
  /// are required to wait for the returned future to complete before calling
  /// this method again. Attempts to do otherwise will result in a
  /// [TestFailure] error being thrown.
  ///
  /// If your widget test hangs and you are using [runAsync], chances are your
  /// code depends on the result of a task that did not complete. Fake async
  /// environment is unable to resolve a future that was created in [runAsync].
  /// If you observe such behavior or flakiness, you have a number of options:
  ///
  /// * Consider restructuring your code so you do not need [runAsync]. This is
  ///   the optimal solution as widget tests are designed to run in fake async
  ///   environment.
  ///
  /// * Expose a [Future] in your application code that signals the readiness of
  ///   your widget tree, then await that future inside [callback].
  Future<T?> runAsync<T>(
    Future<T> Function() callback, {
    Duration additionalTime = const Duration(milliseconds: 1000),
  }) => binding.runAsync<T?>(callback, additionalTime: additionalTime);

  /// Whether there are any transient callbacks scheduled.
  ///
  /// This essentially checks whether all animations have completed.
  ///
  /// See also:
  ///
  ///  * [pumpAndSettle], which essentially calls [pump] until there are no
  ///    scheduled frames.
  ///  * [SchedulerBinding.transientCallbackCount], which is the value on which
  ///    this is based.
  ///  * [SchedulerBinding.hasScheduledFrame], which is true whenever a frame is
  ///    pending. [SchedulerBinding.hasScheduledFrame] is made true when a
  ///    widget calls [State.setState], even if there are no transient callbacks
  ///    scheduled. This is what [pumpAndSettle] uses.
  bool get hasRunningAnimations => binding.transientCallbackCount > 0;

  @override
  HitTestResult hitTestOnBinding(Offset location) {
    assert(location != null);
    location = binding.localToGlobal(location);
    return super.hitTestOnBinding(location);
  }

  @override
  Future<void> sendEventToBinding(PointerEvent event) {
    return TestAsyncUtils.guard<void>(() async {
      binding.handlePointerEventForSource(event, source: TestBindingEventSource.test);
    });
  }

  /// Handler for device events caught by the binding in live test mode.
  @override
  void dispatchEvent(PointerEvent event, HitTestResult result) {
    if (event is PointerDownEvent) {
      final RenderObject innerTarget = result.path
        .map((HitTestEntry candidate) => candidate.target)
        .whereType<RenderObject>()
        .first;
      final Element? innerTargetElement = collectAllElementsFrom(
        binding.renderViewElement!,
        skipOffstage: true,
      ).cast<Element?>().lastWhere(
        (Element? element) => element!.renderObject == innerTarget,
        orElse: () => null,
      );
      if (innerTargetElement == null) {
        printToConsole('No widgets found at ${binding.globalToLocal(event.position)}.');
        return;
      }
      final List<Element> candidates = <Element>[];
      innerTargetElement.visitAncestorElements((Element element) {
        candidates.add(element);
        return true;
      });
      assert(candidates.isNotEmpty);
      String? descendantText;
      int numberOfWithTexts = 0;
      int numberOfTypes = 0;
      int totalNumber = 0;
      printToConsole('Some possible finders for the widgets at ${binding.globalToLocal(event.position)}:');
      for (final Element element in candidates) {
        if (totalNumber > 13) // an arbitrary number of finders that feels useful without being overwhelming
          break;
        totalNumber += 1; // optimistically assume we'll be able to describe it

        final Widget widget = element.widget;
        if (widget is Tooltip) {
          final Iterable<Element> matches = find.byTooltip(widget.message).evaluate();
          if (matches.length == 1) {
            printToConsole("  find.byTooltip('${widget.message}')");
            continue;
          }
        }

        if (widget is Text) {
          assert(descendantText == null);
          assert(widget.data != null || widget.textSpan != null);
          final String text = widget.data ?? widget.textSpan!.toPlainText();
          final Iterable<Element> matches = find.text(text).evaluate();
          descendantText = widget.data;
          if (matches.length == 1) {
            printToConsole("  find.text('$text')");
            continue;
          }
        }

        final Key? key = widget.key;
        if (key is ValueKey<dynamic>) {
          String? keyLabel;
          if (key is ValueKey<int> ||
              key is ValueKey<double> ||
              key is ValueKey<bool>) {
            keyLabel = 'const ${key.runtimeType}(${key.value})';
          } else if (key is ValueKey<String>) {
            keyLabel = "const Key('${key.value}')";
          }
          if (keyLabel != null) {
            final Iterable<Element> matches = find.byKey(key).evaluate();
            if (matches.length == 1) {
              printToConsole('  find.byKey($keyLabel)');
              continue;
            }
          }
        }

        if (!_isPrivate(widget.runtimeType)) {
          if (numberOfTypes < 5) {
            final Iterable<Element> matches = find.byType(widget.runtimeType).evaluate();
            if (matches.length == 1) {
              printToConsole('  find.byType(${widget.runtimeType})');
              numberOfTypes += 1;
              continue;
            }
          }

          if (descendantText != null && numberOfWithTexts < 5) {
            final Iterable<Element> matches = find.widgetWithText(widget.runtimeType, descendantText).evaluate();
            if (matches.length == 1) {
              printToConsole("  find.widgetWithText(${widget.runtimeType}, '$descendantText')");
              numberOfWithTexts += 1;
              continue;
            }
          }
        }

        if (!_isPrivate(element.runtimeType)) {
          final Iterable<Element> matches = find.byElementType(element.runtimeType).evaluate();
          if (matches.length == 1) {
            printToConsole('  find.byElementType(${element.runtimeType})');
            continue;
          }
        }

        totalNumber -= 1; // if we got here, we didn't actually find something to say about it
      }
      if (totalNumber == 0)
        printToConsole('  <could not come up with any unique finders>');
    }
  }

  bool _isPrivate(Type type) {
    // used above so that we don't suggest matchers for private types
    return '_'.matchAsPrefix(type.toString()) != null;
  }

  /// Returns the exception most recently caught by the Flutter framework.
  ///
  /// See [TestWidgetsFlutterBinding.takeException] for details.
  dynamic takeException() {
    return binding.takeException();
  }

  /// Acts as if the application went idle.
  ///
  /// Runs all remaining microtasks, including those scheduled as a result of
  /// running them, until there are no more microtasks scheduled. Then, runs any
  /// previously scheduled timers with zero time, and completes the returned future.
  ///
  /// May result in an infinite loop or run out of memory if microtasks continue
  /// to recursively schedule new microtasks. Will not run any timers scheduled
  /// after this method was invoked, even if they are zero-time timers.
  Future<void> idle() {
    return TestAsyncUtils.guard<void>(() => binding.idle());
  }

  Set<Ticker>? _tickers;

  @override
  Ticker createTicker(TickerCallback onTick) {
    _tickers ??= <_TestTicker>{};
    final _TestTicker result = _TestTicker(onTick, _removeTicker);
    _tickers!.add(result);
    return result;
  }

  void _removeTicker(_TestTicker ticker) {
    assert(_tickers != null);
    assert(_tickers!.contains(ticker));
    _tickers!.remove(ticker);
  }

  /// Throws an exception if any tickers created by the [WidgetTester] are still
  /// active when the method is called.
  ///
  /// An argument can be specified to provide a string that will be used in the
  /// error message. It should be an adverbial phrase describing the current
  /// situation, such as "at the end of the test".
  void verifyTickersWereDisposed([ String when = 'when none should have been' ]) {
    assert(when != null);
    if (_tickers != null) {
      for (final Ticker ticker in _tickers!) {
        if (ticker.isActive) {
          throw FlutterError.fromParts(<DiagnosticsNode>[
            ErrorSummary('A Ticker was active $when.'),
            ErrorDescription('All Tickers must be disposed.'),
            ErrorHint(
              'Tickers used by AnimationControllers '
              'should be disposed by calling dispose() on the AnimationController itself. '
              'Otherwise, the ticker will leak.'
            ),
            ticker.describeForError('The offending ticker was')
          ]);
        }
      }
    }
  }

  void _endOfTestVerifications() {
    verifyTickersWereDisposed('at the end of the test');
    _verifySemanticsHandlesWereDisposed();
  }

  void _verifySemanticsHandlesWereDisposed() {
    assert(_lastRecordedSemanticsHandles != null);
    if (binding.pipelineOwner.debugOutstandingSemanticsHandles > _lastRecordedSemanticsHandles!) {
      throw FlutterError.fromParts(<DiagnosticsNode>[
        ErrorSummary('A SemanticsHandle was active at the end of the test.'),
        ErrorDescription(
          'All SemanticsHandle instances must be disposed by calling dispose() on '
          'the SemanticsHandle.'
        ),
        ErrorHint(
          'If your test uses SemanticsTester, it is '
          'sufficient to call dispose() on SemanticsTester. Otherwise, the '
          'existing handle will leak into another test and alter its behavior.'
        )
      ]);
    }
    _lastRecordedSemanticsHandles = null;
  }

  int? _lastRecordedSemanticsHandles;

  void _recordNumberOfSemanticsHandles() {
    _lastRecordedSemanticsHandles = binding.pipelineOwner.debugOutstandingSemanticsHandles;
  }

  /// Returns the TestTextInput singleton.
  ///
  /// Typical app tests will not need to use this value. To add text to widgets
  /// like [TextField] or [TextFormField], call [enterText].
  ///
  /// Some of the properties and methods on this value are only valid if the
  /// binding's [TestWidgetsFlutterBinding.registerTestTextInput] flag is set to
  /// true as a test is starting (meaning that the keyboard is to be simulated
  /// by the test framework). If those members are accessed when using a binding
  /// that sets this flag to false, they will throw.
  TestTextInput get testTextInput => binding.testTextInput;

  /// Give the text input widget specified by [finder] the focus, as if the
  /// onscreen keyboard had appeared.
  ///
  /// Implies a call to [pump].
  ///
  /// The widget specified by [finder] must be an [EditableText] or have
  /// an [EditableText] descendant. For example `find.byType(TextField)`
  /// or `find.byType(TextFormField)`, or `find.byType(EditableText)`.
  ///
  /// Tests that just need to add text to widgets like [TextField]
  /// or [TextFormField] only need to call [enterText].
  Future<void> showKeyboard(Finder finder) async {
    return TestAsyncUtils.guard<void>(() async {
      final EditableTextState editable = state<EditableTextState>(
        find.descendant(
          of: finder,
          matching: find.byType(EditableText, skipOffstage: finder.skipOffstage),
          matchRoot: true,
        ),
      );
      // Setting focusedEditable causes the binding to call requestKeyboard()
      // on the EditableTextState, which itself eventually calls TextInput.attach
      // to establish the connection.
      binding.focusedEditable = editable;
      await pump();
    });
  }

  /// Give the text input widget specified by [finder] the focus and replace its
  /// content with [text], as if it had been provided by the onscreen keyboard.
  ///
  /// The widget specified by [finder] must be an [EditableText] or have
  /// an [EditableText] descendant. For example `find.byType(TextField)`
  /// or `find.byType(TextFormField)`, or `find.byType(EditableText)`.
  ///
  /// When the returned future completes, the text input widget's text will be
  /// exactly `text`, and the caret will be placed at the end of `text`.
  ///
  /// To just give [finder] the focus without entering any text,
  /// see [showKeyboard].
  ///
  /// To enter text into other widgets (e.g. a custom widget that maintains a
  /// TextInputConnection the way that a [EditableText] does), first ensure that
  /// that widget has an open connection (e.g. by using [tap] to to focus it),
  /// then call `testTextInput.enterText` directly (see
  /// [TestTextInput.enterText]).
  Future<void> enterText(Finder finder, String text) async {
    return TestAsyncUtils.guard<void>(() async {
      await showKeyboard(finder);
      testTextInput.enterText(text);
      await idle();
    });
  }

  /// Makes an effort to dismiss the current page with a Material [Scaffold] or
  /// a [CupertinoPageScaffold].
  ///
  /// Will throw an error if there is no back button in the page.
  Future<void> pageBack() async {
    return TestAsyncUtils.guard<void>(() async {
      Finder backButton = find.byTooltip('Back');
      if (backButton.evaluate().isEmpty) {
        backButton = find.byType(CupertinoNavigationBarBackButton);
      }

      expectSync(backButton, findsOneWidget, reason: 'One back button expected on screen');

      await tap(backButton);
    });
  }

  @override
  void printToConsole(String message) {
    binding.debugPrintOverride(message);
  }
}

typedef _TickerDisposeCallback = void Function(_TestTicker ticker);

class _TestTicker extends Ticker {
  _TestTicker(TickerCallback onTick, this._onDispose) : super(onTick);

  final _TickerDisposeCallback _onDispose;

  @override
  void dispose() {
    _onDispose(this);
    super.dispose();
  }
}
