import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/capture/models/multi_angle_capture.dart';

const _kQueueKey = 'cb_offline_capture_queue';
const _kMaxRetries = 5;

class PendingCapture {
  final String captureId;
  final String userId;
  final String framesDir;
  final Map<String, dynamic> metadata;
  final List<Map<String, dynamic>> frameMetadata;
  final List<int> angleTimingsMs;

  /// Per-frame flash flags: flashFlags[angleIdx][frameIdx] == true means
  /// the frame was captured with torch on. Mirrors MultiAngleCapture.isFlashFrame
  /// so the upload service can name ambient vs flash files correctly after retry.
  final List<List<bool>> flashFlags;

  final DateTime queuedAt;
  final int retryCount;

  const PendingCapture({
    required this.captureId,
    required this.userId,
    required this.framesDir,
    required this.metadata,
    required this.frameMetadata,
    required this.angleTimingsMs,
    required this.queuedAt,
    this.flashFlags = const [],
    this.retryCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'captureId': captureId,
        'userId': userId,
        'framesDir': framesDir,
        'metadata': metadata,
        'frameMetadata': frameMetadata,
        'angleTimingsMs': angleTimingsMs,
        'flashFlags': flashFlags,
        'queuedAt': queuedAt.toIso8601String(),
        'retryCount': retryCount,
      };

  factory PendingCapture.fromJson(Map<String, dynamic> j) => PendingCapture(
        captureId: j['captureId'] as String,
        userId: j['userId'] as String,
        framesDir: j['framesDir'] as String,
        metadata: Map<String, dynamic>.from(j['metadata'] as Map),
        frameMetadata: (j['frameMetadata'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
        angleTimingsMs: (j['angleTimingsMs'] as List).cast<int>(),
        flashFlags: j['flashFlags'] != null
            ? (j['flashFlags'] as List)
                .map((row) => (row as List).cast<bool>())
                .toList()
            : const [],
        queuedAt: DateTime.parse(j['queuedAt'] as String),
        retryCount: j['retryCount'] as int? ?? 0,
      );

  PendingCapture copyWith({int? retryCount}) => PendingCapture(
        captureId: captureId,
        userId: userId,
        framesDir: framesDir,
        metadata: metadata,
        frameMetadata: frameMetadata,
        angleTimingsMs: angleTimingsMs,
        flashFlags: flashFlags,
        queuedAt: queuedAt,
        retryCount: retryCount ?? this.retryCount,
      );
}

class OfflineCaptureQueue {
  const OfflineCaptureQueue();

  Future<String> _baseDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/offline_captures');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  Future<List<PendingCapture>> getPending() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kQueueKey) ?? [];
    return raw
        .map((s) =>
            PendingCapture.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  Future<void> enqueue(
    MultiAngleCapture capture,
    String userId,
    String captureId, {
    List<Map<String, dynamic>> frameMetadata = const [],
  }) async {
    final dir = Directory('${await _baseDir()}/$captureId');
    dir.createSync(recursive: true);

    for (int ai = 0; ai < CaptureAngles.keyList.length; ai++) {
      final frames = capture.capturedFrames[ai];
      for (int fi = 0; fi < frames.length; fi++) {
        await File('${dir.path}/frame_${ai}_$fi.jpg').writeAsBytes(frames[fi]);
      }
    }

    final entry = PendingCapture(
      captureId: captureId,
      userId: userId,
      framesDir: dir.path,
      metadata: capture.metadata,
      frameMetadata: frameMetadata,
      angleTimingsMs: capture.angleTimingsMs,
      flashFlags: capture.isFlashFrame,
      queuedAt: DateTime.now(),
    );

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kQueueKey) ?? [];
    raw.add(jsonEncode(entry.toJson()));
    await prefs.setStringList(_kQueueKey, raw);
    debugPrint('[OfflineQueue] Enqueued $captureId (${raw.length} pending)');
  }

  Future<void> dequeue(String captureId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kQueueKey) ?? [];
    raw.removeWhere((s) {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return m['captureId'] == captureId;
    });
    await prefs.setStringList(_kQueueKey, raw);

    final dir = Directory('${await _baseDir()}/$captureId');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    debugPrint('[OfflineQueue] Dequeued $captureId');
  }

  Future<void> incrementRetry(String captureId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kQueueKey) ?? [];
    final updated = raw.map((s) {
      final m = Map<String, dynamic>.from(jsonDecode(s) as Map<String, dynamic>);
      if (m['captureId'] == captureId) {
        m['retryCount'] = (m['retryCount'] as int? ?? 0) + 1;
      }
      return jsonEncode(m);
    }).toList();
    await prefs.setStringList(_kQueueKey, updated);
  }

  Future<MultiAngleCapture> loadFrames(PendingCapture pending) async {
    final frames = <List<Uint8List>>[];
    for (int ai = 0; ai < CaptureAngles.keyList.length; ai++) {
      final angleFrames = <Uint8List>[];
      var fi = 0;
      while (true) {
        final file = File('${pending.framesDir}/frame_${ai}_$fi.jpg');
        if (!file.existsSync()) break;
        angleFrames.add(await file.readAsBytes());
        fi++;
      }
      frames.add(angleFrames);
    }
    return MultiAngleCapture(
      capturedFrames: frames,
      isFlashFrame: pending.flashFlags,
      metadata: pending.metadata,
      angleTimingsMs: pending.angleTimingsMs,
    );
  }
}

final offlineCaptureQueueProvider = Provider<OfflineCaptureQueue>(
  (_) => const OfflineCaptureQueue(),
);

/// Maximum retry attempts before a pending capture is dropped.
const offlineMaxRetries = _kMaxRetries;
