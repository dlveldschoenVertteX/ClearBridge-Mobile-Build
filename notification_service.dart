import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';

/// Top-level background message handler.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('Handling a background message: ${message.messageId}');
}

class NotificationService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  static String? _fcmToken;
  static GoRouter? _router;

  /// High importance channel for Android.
  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'high_importance_channel', // id
    'High Importance Notifications', // title
    description: 'This channel is used for important notifications.',
    importance: Importance.max,
  );

  /// Initializes FCM and local notifications.
  static Future<void> init() async {
    try {
      // 1. Request Permission
      NotificationSettings settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        debugPrint('User granted permission');
      }

      // 2. Initialize Local Notifications
      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const DarwinInitializationSettings iosSettings =
          DarwinInitializationSettings();

      const InitializationSettings initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _localNotifications.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          if (response.payload != null) {
            // Payload for local notifications can be complex if we want
            // For now, it's the route string.
            // Better to pass both if needed, but usually foreground alerts
            // come from FCM which we handle in onMessage.
            _handlePayload(response.payload!, null);
          }
        },
      );

      // 3. Create Android Notification Channel
      await _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(_channel);

      // 4. Register Background Handler
      FirebaseMessaging.onBackgroundMessage(
        _firebaseMessagingBackgroundHandler,
      );

      // 5. Get FCM Token & Save to Firestore
      _fcmToken = await _messaging.getToken();
      if (_fcmToken != null) {
        debugPrint('FCM Token: $_fcmToken');
        await saveFcmToken(_fcmToken!);
      }

      // 6. Token Refresh Listener
      _messaging.onTokenRefresh.listen((newToken) {
        _fcmToken = newToken;
        saveFcmToken(newToken);
      });

      // 7. Handle Foreground Messages
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('Got a message whilst in the foreground!');
        _showLocalNotification(message);
      });

      // 8. Handle Background Clicks
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('App opened from notification while in background!');
        _handleNotificationClick(message);
      });

      // 9. Handle Terminated State Clicks
      RemoteMessage? initialMessage = await _messaging.getInitialMessage();
      if (initialMessage != null) {
        debugPrint('App opened from notification while terminated!');
        _handleNotificationClick(initialMessage);
      }

      // 10. Stay in sync with Auth State (Save token on Login)
      FirebaseAuth.instance.authStateChanges().listen((user) {
        if (user != null && _fcmToken != null) {
          debugPrint('Auth state changed: user detected. Saving FCM token...');
          saveFcmToken(_fcmToken!);
        }
      });
    } catch (e) {
      debugPrint('Error initializing FCM: $e');
    }
  }

  /// Sets the router instance for navigation.
  static void setRouter(GoRouter router) {
    _router = router;
  }

  /// Displays a local notification when the app is in the foreground.
  static void _showLocalNotification(RemoteMessage message) {
    RemoteNotification? notification = message.notification;
    AndroidNotification? android = message.notification?.android;

    if (notification != null && android != null) {
      _localNotifications.show(
        id: notification.hashCode,
        title: notification.title,
        body: notification.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
            icon: android.smallIcon,
          ),
        ),
        payload: message.data['route'],
      );
    }
  }

  /// Handles clicks by navigating to the specified route.
  static void _handleNotificationClick(RemoteMessage message) {
    final route = message.data['route']?.toString();
    final clearanceId = message.data['clearanceId']?.toString();

    if (route != null) {
      _handlePayload(route, clearanceId);
    }
  }

  /// Performs the actual navigation.
  static void _handlePayload(String route, String? clearanceId) {
    if (_router != null) {
      String path;

      // Map simple route names to actual app paths
      switch (route) {
        case 'dashboard':
          path = '/dashboard';
          break;
        case 'history':
          path = '/history';
          break;
        case 'clearanceDetails':
          if (clearanceId != null && clearanceId.isNotEmpty) {
            path = '/clearance-details/$clearanceId';
          } else {
            path = '/dashboard';
          }
          break;
        default:
          // Fallback to the raw route if it looks like a path
          path = route.startsWith('/') ? route : '/dashboard';
      }

      debugPrint('Deep Linking: Mapping $route ($clearanceId) -> $path');
      _router!.go(path); // Using go() for clean navigation from top-level
    } else {
      debugPrint('Router not initialized. Navigation skipped.');
    }
  }

  /// Saves the FCM token to Firestore.
  static Future<void> saveFcmToken(String token) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'fcmToken': token,
          'lastTokenUpdate': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        debugPrint('FCM Token successfully saved to Firestore');
      }
    } catch (e) {
      debugPrint('Error saving FCM token: $e');
    }
  }

  static String? get fcmToken => _fcmToken;
}
