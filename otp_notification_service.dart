import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/notification_service.dart';

/// Handles the beta notification-based OTP flow.
///
/// Beta builds call [generateOtp] to request a code delivered via FCM
/// push notification, then [verifyOtp] to validate it and receive a
/// Firebase custom auth token for [FirebaseAuth.signInWithCustomToken].
///
/// Production builds use Firebase Phone Auth (SMS) and never call this class.
class OtpNotificationService {
  static final _functions = FirebaseFunctions.instance;

  /// Requests a 6-digit OTP sent to [phoneNumber] via FCM notification.
  /// Throws [FirebaseFunctionsException] or [Exception] on failure.
  static Future<void> generateOtp(String phoneNumber) async {
    final fcmToken = await NotificationService.ensureToken() ?? '';
    if (fcmToken.isEmpty) {
      throw Exception(
        'Notifications are not enabled. Please enable notifications in your device settings and try again.',
      );
    }
    final result = await _functions.httpsCallable('generateOTP').call<dynamic>({
      'phoneNumber': phoneNumber,
      'fcmToken': fcmToken,
    });
    final data = result.data as Map;
    if (data['success'] != true) {
      throw Exception(data['message'] ?? 'Failed to send code.');
    }
  }

  /// Verifies [code] for [phoneNumber]. Returns a Firebase custom auth token
  /// on success. Throws on invalid/expired code.
  static Future<String> verifyOtp(String phoneNumber, String code) async {
    final result = await _functions.httpsCallable('verifyOTP').call<dynamic>({
      'phoneNumber': phoneNumber,
      'code': code,
    });
    final data = result.data as Map;
    if (data['valid'] == true) {
      return data['customToken'] as String;
    }
    throw Exception(data['message'] ?? 'Invalid code.');
  }
}
