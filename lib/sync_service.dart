import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:clearbridge/fingerprint_frame_upload_service.dart';
import 'connectivity_service.dart';
import 'offline_capture_queue.dart';

enum SyncState { idle, syncing }

class SyncService extends Notifier<SyncState> {
  bool _syncing = false;

  @override
  SyncState build() {
    ref.listen<bool>(connectivityServiceProvider, (previous, isOnline) {
      if (isOnline && previous == false) {
        // Device just came back online — flush any queued captures.
        _processQueue();
      }
    });
    return SyncState.idle;
  }

  Future<void> _processQueue() async {
    if (_syncing) return;
    _syncing = true;
    state = SyncState.syncing;

    try {
      final queue = ref.read(offlineCaptureQueueProvider);
      final uploadService = ref.read(fingerprintFrameUploadServiceProvider);
      final pending = await queue.getPending();

      if (pending.isEmpty) return;
      debugPrint('[SyncService] Uploading ${pending.length} queued capture(s)');

      for (final p in pending) {
        if (p.retryCount >= offlineMaxRetries) {
          debugPrint('[SyncService] Dropping ${p.captureId} after $offlineMaxRetries retries');
          await queue.dequeue(p.captureId);
          continue;
        }
        try {
          final capture = await queue.loadFrames(p);
          await uploadService.uploadAndProcess(
            capture,
            userId: p.userId,
            captureId: p.captureId,
            frameMetadata: p.frameMetadata,
          );
          await queue.dequeue(p.captureId);
          debugPrint('[SyncService] Uploaded ${p.captureId}');
        } catch (e) {
          debugPrint('[SyncService] Upload failed for ${p.captureId}: $e');
          await queue.incrementRetry(p.captureId);
        }
      }
    } catch (e) {
      debugPrint('[SyncService] Queue processing error: $e');
    } finally {
      _syncing = false;
      state = SyncState.idle;
    }
  }
}

final syncServiceProvider = NotifierProvider<SyncService, SyncState>(
  SyncService.new,
);
