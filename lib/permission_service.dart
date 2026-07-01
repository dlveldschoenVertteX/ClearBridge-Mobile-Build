import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:clearbridge/error_dialog.dart';

part 'permission_service.g.dart';

@riverpod
class PermissionService extends _$PermissionService {
  @override
  void build() {}

  /// Checks and requests camera permission.
  /// Returns true if granted, false otherwise.
  Future<bool> checkCameraPermission(BuildContext context) async {
    final status = await Permission.camera.status;

    if (status.isGranted) {
      return true;
    }

    if (status.isPermanentlyDenied) {
      if (context.mounted) {
        await _showSettingsDialog(context);
      }
      return false;
    }

    // Request permission
    final result = await Permission.camera.request();

    if (result.isGranted) {
      return true;
    }

    if (result.isPermanentlyDenied) {
      if (context.mounted) {
        await _showSettingsDialog(context);
      }
      return false;
    }

    if (context.mounted) {
      await _showExplanationDialog(context);
    }

    return false;
  }

  Future<void> _showExplanationDialog(BuildContext context) async {
    return ErrorDialog.show(
      context: context,
      title: 'Camera Permission Required',
      message:
          'This app needs camera access to capture your selfie, ID, and fingerprints. Please grant permission to continue.',
      buttonText: 'RETRY',
      onPressed: () async {
        await Permission.camera.request();
      },
    );
  }

  Future<void> _showSettingsDialog(BuildContext context) async {
    return ErrorDialog.show(
      context: context,
      title: 'Camera Permission Denied',
      message:
          'Camera permission is permanently denied. Please enable it in the app settings to continue using the capture features.',
      buttonText: 'OPEN SETTINGS',
      onPressed: () async {
        await openAppSettings();
      },
    );
  }
}
