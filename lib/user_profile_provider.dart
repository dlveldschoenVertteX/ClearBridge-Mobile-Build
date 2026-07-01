import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'package:clearbridge/auth_repository.dart';
import 'package:clearbridge/application_data.dart';
import 'package:clearbridge/application_repository.dart';
import 'auth_provider.dart';

part 'user_profile_provider.g.dart';

@riverpod
class UserProfileCompleted extends _$UserProfileCompleted {
  Timer? _validationTimer;

  @override
  AsyncValue<bool> build() {
    final authState = ref.watch(authProvider);
    final user = authState.valueOrNull;

    if (user == null) {
      debugPrint('UserProfileCompleted: No user logged in');
      _validationTimer?.cancel();
      return const AsyncData(false);
    }

    debugPrint(
      'UserProfileCompleted: Checking profile completion for ${user.uid}',
    );

    // Set up periodic validation to check if user still exists in Firebase Auth
    _validationTimer?.cancel();
    if (!kIsWeb) {
      _validationTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
        _validateUserExists(user);
      });
    }

    // Clean up timer when provider is disposed
    ref.onDispose(() {
      _validationTimer?.cancel();
    });

    // Set up a listener to detect when user is deleted from Firebase Auth
    ref.listen(authProvider, (previous, next) {
      final prevUser = previous?.valueOrNull;
      final nextUser = next.valueOrNull;

      // If user was logged in but now is null, they were deleted/signed out
      if (prevUser != null && nextUser == null) {
        debugPrint('UserProfileCompleted: User was deleted/signed out');
        _validationTimer?.cancel();
      }
    });

    // Watch the user profile stream and handle various states
    final profileAsync = ref.watch(userProfileProvider);
    return profileAsync.when(
      data: (profile) {
        if (profile == null) {
          debugPrint(
            'UserProfileCompleted: Profile document missing for ${user.uid}, treating as incomplete',
          );
          // Don't sign out - this is a new user who needs to complete their profile
          return const AsyncData(false);
        }

        // Check if profile is completed based on required fields
        final isCompleted = _isProfileComplete(profile);
        debugPrint(
          'UserProfileCompleted: Profile completion for ${user.uid}: $isCompleted',
        );
        return AsyncData(isCompleted);
      },
      loading: () => const AsyncLoading(),
      error: (error, stackTrace) {
        debugPrint('UserProfileCompleted: Error for ${user.uid}: $error');

        // Check if this is a permission-denied error (user deleted)
        if (error is FirebaseException &&
            (error.code == 'permission-denied' ||
                error.code == 'unauthenticated')) {
          debugPrint(
            'UserProfileCompleted: Permission denied for ${user.uid}, signing out',
          );
          Future.microtask(() => _signOutUser());
        }

        return AsyncError(error, stackTrace);
      },
    );
  }

  /// Periodically validates if the user still exists in Firebase Auth
  Future<void> _validateUserExists(User user) async {
    try {
      // Force refresh the user's ID token to validate they still exist
      await user.getIdToken(true);
      debugPrint(
        'UserProfileCompleted: User ${user.uid} still exists in Firebase Auth',
      );
    } catch (e) {
      debugPrint(
        'UserProfileCompleted: User validation failed for ${user.uid}: $e',
      );
      if (e is FirebaseAuthException &&
          (e.code == 'user-not-found' ||
              e.code == 'user-disabled' ||
              e.code == 'invalid-token')) {
        debugPrint(
          'UserProfileCompleted: User ${user.uid} was deleted/disabled, signing out',
        );
        _signOutUser();
      }
    }
  }

  /// Checks if the user profile has all required fields
  bool _isProfileComplete(ApplicationData profile) {
    return profile.firstName.isNotEmpty &&
        profile.surname.isNotEmpty &&
        profile.phone.isNotEmpty &&
        profile.idNumber.isNotEmpty;
  }

  /// Signs out the current user
  void _signOutUser() {
    try {
      ref.read(authRepositoryProvider).signOut();
    } catch (e) {
      debugPrint('UserProfileCompleted: Error signing out: $e');
    }
  }
}

/// Streams whether the current user has completed the biometric capture consent
/// (POPIA v2.0 — stored at users/{uid}/consents.captureConsent).
/// Used by the router to gate /fingerprint and /capture/continuous.
final captureConsentProvider = StreamProvider<bool>((ref) {
  final user = ref.watch(authProvider).valueOrNull;
  if (user == null) return Stream.value(false);
  return FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .snapshots()
      .map((snap) {
        final consents = snap.data()?['consents'] as Map<String, dynamic>?;
        return consents?['captureConsent'] == true;
      });
});

@riverpod
Stream<ApplicationData?> userProfile(Ref ref) {
  final authState = ref.watch(authProvider);
  final user = authState.valueOrNull;

  if (user == null) {
    debugPrint('userProfileProvider: No user logged in');
    return Stream.value(null);
  }

  debugPrint('userProfileProvider: Fetching profile for ${user.uid}');
  final stream = ref
      .watch(applicationRepositoryProvider)
      .streamUserProfileApplication(user.uid);

  return stream
      .handleError((e) {
        debugPrint('userProfileProvider Error for ${user.uid}: $e');
        // Don't re-throw permission errors, let the provider handle them
        if (e is FirebaseException &&
            (e.code == 'permission-denied' || e.code == 'unauthenticated')) {
          return; // Let the stream complete without data
        }
        throw e; // Re-throw other errors
      })
      .map((profile) {
        debugPrint(
          'userProfileProvider: Profile for ${user.uid} is ${profile != null ? "found" : "null"}',
        );
        return profile;
      });
}
