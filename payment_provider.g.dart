// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'payment_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$paymentServiceHash() => r'4c509f9080f549011d7acfc0968ca0574935b082';

/// See also [paymentService].
@ProviderFor(paymentService)
final paymentServiceProvider = AutoDisposeProvider<PaymentService>.internal(
  paymentService,
  name: r'paymentServiceProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$paymentServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef PaymentServiceRef = AutoDisposeProviderRef<PaymentService>;
String _$selectedTierHash() => r'e41b06c409391223e8593522e8afa350db704acb';

/// See also [SelectedTier].
@ProviderFor(SelectedTier)
final selectedTierProvider =
    AutoDisposeNotifierProvider<SelectedTier, String>.internal(
      SelectedTier.new,
      name: r'selectedTierProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$selectedTierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$SelectedTier = AutoDisposeNotifier<String>;
String _$paymentNotifierHash() => r'7436f702b74fd51738e2e5fa20675e42754369bd';

/// See also [PaymentNotifier].
@ProviderFor(PaymentNotifier)
final paymentNotifierProvider =
    AutoDisposeNotifierProvider<PaymentNotifier, PaymentState>.internal(
      PaymentNotifier.new,
      name: r'paymentNotifierProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$paymentNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$PaymentNotifier = AutoDisposeNotifier<PaymentState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
