// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'clearance_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$latestClearanceHash() => r'3a3bbf9385620ba3b118011b0da89283e7b08313';

/// See also [latestClearance].
@ProviderFor(latestClearance)
final latestClearanceProvider =
    AutoDisposeStreamProvider<ClearanceModel?>.internal(
      latestClearance,
      name: r'latestClearanceProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$latestClearanceHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef LatestClearanceRef = AutoDisposeStreamProviderRef<ClearanceModel?>;
String _$activeClearanceHash() => r'2a71a90a51159e23f70d516368360e2933f1fd4f';

/// See also [activeClearance].
@ProviderFor(activeClearance)
final activeClearanceProvider =
    AutoDisposeProvider<AsyncValue<ClearanceModel?>>.internal(
      activeClearance,
      name: r'activeClearanceProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$activeClearanceHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef ActiveClearanceRef =
    AutoDisposeProviderRef<AsyncValue<ClearanceModel?>>;
String _$userClearancesHash() => r'f281ef03938de21ad3d2d42359a3e354f6562014';

/// See also [userClearances].
@ProviderFor(userClearances)
final userClearancesProvider =
    AutoDisposeStreamProvider<List<ClearanceModel>>.internal(
      userClearances,
      name: r'userClearancesProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$userClearancesHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef UserClearancesRef = AutoDisposeStreamProviderRef<List<ClearanceModel>>;
String _$selectedClearanceIdHash() =>
    r'f6203e32541a5395e3588b511796f628f7ac6deb';

/// See also [SelectedClearanceId].
@ProviderFor(SelectedClearanceId)
final selectedClearanceIdProvider =
    NotifierProvider<SelectedClearanceId, String?>.internal(
      SelectedClearanceId.new,
      name: r'selectedClearanceIdProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$selectedClearanceIdHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$SelectedClearanceId = Notifier<String?>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
