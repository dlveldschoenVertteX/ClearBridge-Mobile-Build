import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'auth_repository.g.dart';

@riverpod
FirebaseAuth firebaseAuth(Ref ref) => FirebaseAuth.instance;

class AuthRepository {
  final FirebaseAuth _auth;

  AuthRepository(this._auth);

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  Future<void> verifyPhoneNumber({
    required String phoneNumber,
    required Function(PhoneAuthCredential) verificationCompleted,
    required Function(FirebaseAuthException) verificationFailed,
    required Function(String, int?) codeSent,
    required Function(String) codeAutoRetrievalTimeout,
  }) async {
    await _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      verificationCompleted: verificationCompleted,
      verificationFailed: verificationFailed,
      codeSent: codeSent,
      codeAutoRetrievalTimeout: codeAutoRetrievalTimeout,
    );
  }

  Future<UserCredential> signInWithCredential(
    PhoneAuthCredential credential,
  ) async {
    return await _auth.signInWithCredential(credential);
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }

  // Auth domain for action code links — matches the Firebase Hosting domain
  // and the App Links / Universal Links configuration.
  static const _authDomain = 'clearbridge-dc699.web.app';

  ActionCodeSettings _actionCodeSettings({String? continueUrl}) =>
      ActionCodeSettings(
        url: continueUrl ?? 'https://$_authDomain/auth/done',
        handleCodeInApp: true,
        androidPackageName: 'com.clearbridge.app',
        androidInstallApp: true,
        androidMinimumVersion: '24',
        iOSBundleId: 'com.clearbridge.app',
      );

  /// Send email verification to [user]'s email address.
  /// Requires [user.email] to be set (link an email first if phone-only auth).
  Future<void> sendEmailVerification(User user, {String? continueUrl}) async {
    await user.sendEmailVerification(_actionCodeSettings(continueUrl: continueUrl));
  }

  /// Send a password-reset email to [email].
  Future<void> sendPasswordResetEmail(String email, {String? continueUrl}) async {
    await _auth.sendPasswordResetEmail(
      email: email,
      actionCodeSettings: _actionCodeSettings(continueUrl: continueUrl),
    );
  }

  /// Apply an email action code (verifyEmail, recoverEmail).
  Future<void> applyActionCode(String oobCode) async {
    await _auth.applyActionCode(oobCode);
    await _auth.currentUser?.reload();
  }

  /// Validate a password-reset code and return the email address it belongs to.
  Future<String> verifyPasswordResetCode(String oobCode) async {
    return await _auth.verifyPasswordResetCode(oobCode);
  }

  /// Complete a password reset using the [oobCode] from the email link.
  Future<void> confirmPasswordReset(String oobCode, String newPassword) async {
    await _auth.confirmPasswordReset(code: oobCode, newPassword: newPassword);
  }

  /// Get metadata about an action code without consuming it.
  Future<ActionCodeInfo> checkActionCode(String oobCode) async {
    return await _auth.checkActionCode(oobCode);
  }
}

@riverpod
AuthRepository authRepository(Ref ref) {
  return AuthRepository(ref.watch(firebaseAuthProvider));
}
