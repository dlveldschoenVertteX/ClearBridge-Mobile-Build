import 'package:firebase_auth/firebase_auth.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:clearbridge/auth_repository.dart';

part 'auth_controller_provider.g.dart';

@riverpod
class AuthController extends _$AuthController {
  @override
  AsyncValue<void> build() {
    return const AsyncData(null);
  }

  Future<void> verifyPhoneNumber({
    required String phoneNumber,
    required Function(String verificationId) onCodeSent,
    required Function(String error) onError,
  }) async {
    state = const AsyncLoading();
    final authRepository = ref.read(authRepositoryProvider);

    try {
      await authRepository.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        verificationCompleted: (PhoneAuthCredential credential) async {
          try {
            await authRepository.signInWithCredential(credential);
            state = const AsyncData(null);
          } catch (e) {
            state = AsyncError(e, StackTrace.current);
            onError(e.toString());
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          state = AsyncError(e, StackTrace.current);
          onError(e.message ?? 'Verification failed');
        },
        codeSent: (String verificationId, int? resendToken) {
          state = const AsyncData(null);
          onCodeSent(verificationId);
        },
        codeAutoRetrievalTimeout: (String verificationId) {},
      );
    } catch (e, st) {
      state = AsyncError(e, st);
      onError(e.toString());
    }
  }

  Future<void> verifyOtp({
    required String verificationId,
    required String smsCode,
    required Function() onSuccess,
    required Function(String error) onError,
  }) async {
    state = const AsyncLoading();
    final authRepository = ref.read(authRepositoryProvider);
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode,
      );
      await authRepository.signInWithCredential(credential);
      state = const AsyncData(null);
      onSuccess();
    } on FirebaseAuthException catch (e) {
      state = AsyncError(e, StackTrace.current);
      onError(e.message ?? 'Failed to verify OTP');
    } catch (e, st) {
      state = AsyncError(e, st);
      onError(e.toString());
    }
  }

  Future<void> logout() async {
    final authRepository = ref.read(authRepositoryProvider);
    await authRepository.signOut();
  }
}
