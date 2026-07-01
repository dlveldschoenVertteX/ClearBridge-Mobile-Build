import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:clearbridge/application_data.dart';
import 'package:clearbridge/application_repository.dart';
import 'package:clearbridge/auth_repository.dart';

part 'application_provider.g.dart';

// Application state model
class ApplicationState {
  final String? applicationId;
  final String? status;
  final Timestamp? deadlineAt;
  final String? certificateUrl;
  final String? tier;
  final String? paymentReference;
  final bool isLoading;
  final String? error;

  const ApplicationState({
    this.applicationId,
    this.status,
    this.deadlineAt,
    this.certificateUrl,
    this.tier,
    this.paymentReference,
    this.isLoading = false,
    this.error,
  });

  ApplicationState copyWith({
    String? applicationId,
    String? status,
    Timestamp? deadlineAt,
    String? certificateUrl,
    String? tier,
    String? paymentReference,
    bool? isLoading,
    String? error,
  }) {
    return ApplicationState(
      applicationId: applicationId ?? this.applicationId,
      status: status ?? this.status,
      deadlineAt: deadlineAt ?? this.deadlineAt,
      certificateUrl: certificateUrl ?? this.certificateUrl,
      tier: tier ?? this.tier,
      paymentReference: paymentReference ?? this.paymentReference,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
    );
  }
}

class ApplicationNotifier extends StateNotifier<ApplicationState> {
  final ApplicationRepository _applicationRepository;
  StreamSubscription<QuerySnapshot>? _subscription;

  ApplicationNotifier(this._applicationRepository)
    : super(const ApplicationState());

  // Start listening to user's active application
  void startListening(String userId) {
    state = state.copyWith(isLoading: true, error: null);

    // Cancel existing subscription
    _subscription?.cancel();

    // Query for user's most recent application
    _subscription = _applicationRepository.firestore
        .collection('applications')
        .where('userId', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        .limit(1)
        .snapshots()
        .listen(
          (snapshot) {
            if (snapshot.docs.isNotEmpty) {
              final doc = snapshot.docs.first;
              final data = doc.data();

              state = state.copyWith(
                applicationId: doc.id,
                status: data['status'] as String?,
                deadlineAt: data['deadlineAt'] as Timestamp?,
                certificateUrl: data['certificateUrl'] as String?,
                tier: data['tier'] as String?,
                paymentReference: data['paymentReference'] as String?,
                isLoading: false,
                error: null,
              );
            } else {
              // No application found
              state = state.copyWith(
                applicationId: null,
                status: null,
                deadlineAt: null,
                certificateUrl: null,
                isLoading: false,
                error: null,
              );
            }
          },
          onError: (error) {
            state = state.copyWith(
              isLoading: false,
              error: 'Failed to load application: $error',
            );
          },
        );
  }

  // Stop listening
  void stopListening() {
    _subscription?.cancel();
    state = const ApplicationState();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

// Provider for the application state
final applicationProvider =
    StateNotifierProvider<ApplicationNotifier, ApplicationState>((ref) {
      final applicationRepository = ref.watch(applicationRepositoryProvider);
      return ApplicationNotifier(applicationRepository);
    });

// Provider to get current application ID
final currentApplicationIdProvider = Provider<String?>((ref) {
  return ref.watch(applicationProvider).applicationId;
});

// Provider to get current application status
final currentApplicationStatusProvider = Provider<String?>((ref) {
  return ref.watch(applicationProvider).status;
});

// Provider to get current deadline
final currentDeadlineProvider = Provider<Timestamp?>((ref) {
  return ref.watch(applicationProvider).deadlineAt;
});

// Provider to get certificate URL
final certificateUrlProvider = Provider<String?>((ref) {
  return ref.watch(applicationProvider).certificateUrl;
});

// Provider to check if user has an active application (paid and processing)
final hasActiveApplicationProvider = Provider<bool>((ref) {
  final applicationState = ref.watch(applicationProvider);
  final status = applicationState.status;

  // Active means it exists, and it's either pending, paid, or processing
  return applicationState.applicationId != null &&
      status != null &&
      status != 'completed' &&
      status != 'failed' &&
      status != 'cancelled';
});

// Provider to get application data for countdown timer
final applicationDataForCountdownProvider = Provider<Map<String, dynamic>?>((
  ref,
) {
  final applicationState = ref.watch(applicationProvider);

  if (applicationState.applicationId == null ||
      applicationState.deadlineAt == null) {
    return null;
  }

  return {
    'applicationId': applicationState.applicationId,
    'status': applicationState.status,
    'deadlineAt': applicationState.deadlineAt,
    'certificateUrl': applicationState.certificateUrl,
  };
});

@riverpod
class ApplicationSubmit extends _$ApplicationSubmit {
  @override
  AsyncValue<void> build() {
    return const AsyncValue.data(null);
  }

  Future<void> submit({
    required String firstName,
    required String surname,
    required String phone,
    required String email,
    required String idNumber,
    required DateTime? dob,
    required String streetAddress,
    required String suburb,
    required String city,
    required String province,
    required String postalCode,
    required String currentLocation,
    String? referredBy,
  }) async {
    state = const AsyncValue.loading();

    try {
      final repository = ref.read(applicationRepositoryProvider);
      final userId = ref.read(firebaseAuthProvider).currentUser?.uid;

      if (userId == null) {
        throw Exception('User not authenticated');
      }

      final application = ApplicationData(
        userId: userId,
        firstName: firstName,
        surname: surname,
        phone: phone,
        email: email,
        idNumber: idNumber,
        dob: dob,
        streetAddress: streetAddress,
        suburb: suburb,
        city: city,
        province: province,
        postalCode: postalCode,
        currentLocation: currentLocation,
        createdAt: DateTime.now().toUtc(),
        status: 'pending',
      );

      final referralCode = userId.length >= 8
          ? userId.substring(0, 8).toUpperCase()
          : userId.toUpperCase();
      final cleanReferredBy = referredBy?.trim().toUpperCase();

      await repository.createUserProfile(
        application,
        referralCode: referralCode,
        referredBy: (cleanReferredBy?.isNotEmpty == true &&
                cleanReferredBy != referralCode)
            ? cleanReferredBy
            : null,
      );

      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }
}
