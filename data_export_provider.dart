import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:path_provider/path_provider.dart';

part 'data_export_provider.g.dart';

@riverpod
DataExportService dataExportService(Ref ref) {
  return DataExportService();
}

class DataExportService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  DataExportService({FirebaseFirestore? firestore, FirebaseAuth? auth})
    : _firestore = firestore ?? FirebaseFirestore.instance,
      _auth = auth ?? FirebaseAuth.instance;

  /// Export all user data as JSON
  Future<Map<String, dynamic>> exportUserData() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User not authenticated');
    }

    final userId = user.uid;
    final exportData = <String, dynamic>{
      'exportDate': DateTime.now().toUtc().toIso8601String(),
      'userId': userId,
      'exportedBy': user.email ?? user.phoneNumber ?? 'unknown',
    };

    try {
      // 1. Export user profile
      final userDoc = await _firestore.collection('users').doc(userId).get();
      Map<String, dynamic>? userData;
      if (userDoc.exists) {
        userData = userDoc.data()!;
        // Remove sensitive fields from export
        userData.remove('fcmToken');
        exportData['profile'] = userData;
      }

      // 2. Export clearances (capped at 100 most recent to prevent OOM)
      final clearancesSnapshot = await _firestore
          .collection('clearances')
          .where('userId', isEqualTo: userId)
          .orderBy('createdAt', descending: true)
          .limit(100)
          .get();

      exportData['clearances'] = clearancesSnapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          'reference': data['reference'],
          'tier': data['tier'],
          'status': data['status'],
          'price': data['price'],
          'createdAt': _formatTimestamp(data['createdAt']),
          'paidAt': _formatTimestamp(data['paidAt']),
          'completedAt': _formatTimestamp(data['completedAt']),
          'certificateUrl': data['certificateUrl'],
          'clearanceResult': data['clearanceResult'],
        };
      }).toList();

      // 3. Export pending payments (capped at 100 most recent)
      final paymentsSnapshot = await _firestore
          .collection('pending_payments')
          .where('userId', isEqualTo: userId)
          .orderBy('createdAt', descending: true)
          .limit(100)
          .get();

      exportData['paymentHistory'] = paymentsSnapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'reference': data['reference'],
          'amount': data['amount'],
          'status': data['status'],
          'tier': data['tier'],
          'createdAt': _formatTimestamp(data['createdAt']),
          'completedAt': _formatTimestamp(data['completedAt']),
        };
      }).toList();

      // 4. Export consent records
      if (userData != null) {
        exportData['consentRecords'] = {
          'popiaConsent': userData['popiaConsent'],
          'popiaConsentDate': _formatTimestamp(userData['popiaConsentDate']),
        };
      }

      // 5. Add privacy notice
      exportData['privacyNotice'] = {
        'dataRetentionPolicy':
            'Data retained until account deletion. See Privacy Policy for details.',
        'deletionInstructions':
            'To delete your data, use "Delete My Account" in Profile settings or email privacy@clearbridgeapp.co.za',
        'contactEmail': 'privacy@clearbridgeapp.co.za',
      };

      debugPrint(
        'DataExportService: Successfully exported data for user $userId',
      );
      return exportData;
    } catch (e) {
      debugPrint('DataExportService: Error exporting data: $e');
      throw Exception('Failed to export user data: $e');
    }
  }

  /// Export and share user data as JSON file
  /// Returns the file path for sharing
  Future<String> exportAndShareData() async {
    try {
      final exportData = await exportUserData();
      final jsonString = const JsonEncoder.withIndent('  ').convert(exportData);

      // Create temporary file
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
      final fileName = 'clearbridge_data_export_$timestamp.json';
      final file = File('${tempDir.path}/$fileName');

      await file.writeAsString(jsonString);

      debugPrint('DataExportService: Data exported to ${file.path}');
      return file.path;
    } catch (e) {
      debugPrint('DataExportService: Error sharing data: $e');
      throw Exception('Failed to share data: $e');
    }
  }

  /// Export and download user data as JSON file
  Future<String> exportAndSaveData() async {
    try {
      final exportData = await exportUserData();
      final jsonString = const JsonEncoder.withIndent('  ').convert(exportData);

      // Get appropriate directory based on platform
      Directory? saveDir;
      if (Platform.isAndroid) {
        saveDir = Directory('/storage/emulated/0/Download');
        if (!saveDir.existsSync()) {
          saveDir = await getExternalStorageDirectory();
        }
      } else {
        saveDir = await getApplicationDocumentsDirectory();
      }

      final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
      final fileName = 'clearbridge_data_export_$timestamp.json';
      final file = File('${saveDir?.path}/$fileName');

      await file.writeAsString(jsonString);

      debugPrint('DataExportService: Data saved to ${file.path}');
      return file.path;
    } catch (e) {
      debugPrint('DataExportService: Error saving data: $e');
      throw Exception('Failed to save data: $e');
    }
  }

  String? _formatTimestamp(dynamic timestamp) {
    if (timestamp == null) return null;
    if (timestamp is Timestamp) {
      return timestamp.toDate().toUtc().toIso8601String();
    }
    if (timestamp is DateTime) {
      return timestamp.toUtc().toIso8601String();
    }
    return timestamp.toString();
  }
}
