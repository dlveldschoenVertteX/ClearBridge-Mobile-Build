import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'certificate_service.g.dart';

@riverpod
CertificateService certificateService(CertificateServiceRef ref) {
  return CertificateService();
}

class CertificateService {
  /// Downloads a PDF from the given [url] and saves it locally.
  /// Returns the local [File] object.
  Future<File> downloadCertificate(String url, String fileName) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw Exception('Failed to download PDF: ${response.statusCode}');
      }

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(response.bodyBytes);
      return file;
    } catch (e) {
      debugPrint('Error downloading certificate: $e');
      rethrow;
    }
  }

  /// Shares the certificate using the system share sheet.
  Future<void> shareCertificate(String localPath, {String? subject}) async {
    try {
      await Share.shareXFiles([
        XFile(localPath),
      ], subject: subject ?? 'ClearBridge Police Clearance');
    } catch (e) {
      debugPrint('Error sharing certificate: $e');
      rethrow;
    }
  }

  /// Opens the certificate using the system's default PDF viewer.
  Future<void> openCertificate(String localPath) async {
    try {
      final result = await OpenFilex.open(localPath);
      if (result.type != ResultType.done) {
        throw Exception(result.message);
      }
    } catch (e) {
      debugPrint('Error opening certificate: $e');
      rethrow;
    }
  }

  /// Checks if a certificate already exists locally.
  Future<File?> getLocalCertificate(String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    return await file.exists() ? file : null;
  }
}
