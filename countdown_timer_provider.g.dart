// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'countdown_timer_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$countdownTimerHash() => r'f819a3f27cfb7040e6f90b4645067225fd610335';

/// See also [countdownTimer].
@ProviderFor(countdownTimer)
final countdownTimerProvider = StreamProvider<Duration>.internal(
  countdownTimer,
  name: r'countdownTimerProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$countdownTimerHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef CountdownTimerRef = StreamProviderRef<Duration>;
String _$formattedCountdownHash() =>
    r'8b61cd6fd34c2ec5c0544dd2333eea95b6b4367b';

/// See also [formattedCountdown].
@ProviderFor(formattedCountdown)
final formattedCountdownProvider = AutoDisposeProvider<String>.internal(
  formattedCountdown,
  name: r'formattedCountdownProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$formattedCountdownHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef FormattedCountdownRef = AutoDisposeProviderRef<String>;
String _$clearanceStatusHash() => r'f7fc5284d029083442c554cf13bf2792be628a77';

/// See also [clearanceStatus].
@ProviderFor(clearanceStatus)
final clearanceStatusProvider =
    AutoDisposeProvider<ClearanceStatusUpdate>.internal(
      clearanceStatus,
      name: r'clearanceStatusProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$clearanceStatusHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef ClearanceStatusRef = AutoDisposeProviderRef<ClearanceStatusUpdate>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
