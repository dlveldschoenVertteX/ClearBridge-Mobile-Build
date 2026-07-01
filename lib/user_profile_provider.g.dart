// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user_profile_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$userProfileHash() => r'adbbf329c56bffa84ae3149ddea5f274109981ee';

/// See also [userProfile].
@ProviderFor(userProfile)
final userProfileProvider =
    AutoDisposeStreamProvider<ApplicationData?>.internal(
      userProfile,
      name: r'userProfileProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$userProfileHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef UserProfileRef = AutoDisposeStreamProviderRef<ApplicationData?>;
String _$userProfileCompletedHash() =>
    r'2bf9238b8913398843a89f94f7141394e2866ddd';

/// See also [UserProfileCompleted].
@ProviderFor(UserProfileCompleted)
final userProfileCompletedProvider =
    AutoDisposeNotifierProvider<
      UserProfileCompleted,
      AsyncValue<bool>
    >.internal(
      UserProfileCompleted.new,
      name: r'userProfileCompletedProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$userProfileCompletedHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$UserProfileCompleted = AutoDisposeNotifier<AsyncValue<bool>>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
