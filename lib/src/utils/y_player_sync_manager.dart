import 'dart:async';

import 'package:flutter/foundation.dart';

/// Advanced audio-video synchronization manager
/// Handles lip-sync issues and audio-video drift
class YPlayerSyncManager {
  static const Duration _maxSyncOffset = Duration(milliseconds: 200);
  static const Duration _targetSyncOffset = Duration(milliseconds: 40);

  Timer? _syncMonitorTimer;
  Duration _currentAudioOffset = Duration.zero;
  Duration _currentVideoOffset = Duration.zero;

  // Sync correction history
  final List<Duration> _syncHistory = [];
  Duration _averageSyncDrift = Duration.zero;

  final ValueNotifier<SyncState> syncStateNotifier = ValueNotifier(SyncState());

  // Callbacks for sync correction
  void Function(Duration)? _onAudioSyncCorrection;
  void Function(Duration)? _onVideoSyncCorrection;

  void startSyncMonitoring({
    required void Function(Duration) onAudioSyncCorrection,
    required void Function(Duration) onVideoSyncCorrection,
  }) {
    _onAudioSyncCorrection = onAudioSyncCorrection;
    _onVideoSyncCorrection = onVideoSyncCorrection;

    _syncMonitorTimer?.cancel();
    _syncMonitorTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      _monitorSync,
    );
  }

  void stopSyncMonitoring() {
    _syncMonitorTimer?.cancel();
  }

  void updateAudioTimestamp(Duration timestamp) {
    _currentAudioOffset = timestamp;
    _checkSync();
  }

  void updateVideoTimestamp(Duration timestamp) {
    _currentVideoOffset = timestamp;
    _checkSync();
  }

  void _monitorSync(Timer timer) {
    _checkSync();
  }

  void _checkSync() {
    final syncDrift = _currentVideoOffset - _currentAudioOffset;

    // Add to history
    _syncHistory.add(syncDrift);
    if (_syncHistory.length > 50) {
      _syncHistory.removeAt(0);
    }

    // Calculate average drift
    if (_syncHistory.isNotEmpty) {
      final totalDrift = _syncHistory.reduce(
        (a, b) => Duration(microseconds: a.inMicroseconds + b.inMicroseconds),
      );
      _averageSyncDrift = Duration(
        microseconds: totalDrift.inMicroseconds ~/ _syncHistory.length,
      );
    }

    // Apply correction if needed
    if (_averageSyncDrift.abs() > _targetSyncOffset) {
      _applySyncCorrection(_averageSyncDrift);
    }

    // Update sync state
    syncStateNotifier.value = SyncState(
      currentDrift: syncDrift,
      averageDrift: _averageSyncDrift,
      isInSync: _averageSyncDrift.abs() <= _targetSyncOffset,
      needsCorrection: _averageSyncDrift.abs() > _maxSyncOffset,
    );
  }

  void _applySyncCorrection(Duration drift) {
    if (drift.inMicroseconds > 0) {
      // Video is ahead, delay video or speed up audio
      _onVideoSyncCorrection?.call(Duration(
        microseconds: -drift.inMicroseconds ~/ 2,
      ));
    } else {
      // Audio is ahead, delay audio or speed up video
      _onAudioSyncCorrection?.call(Duration(
        microseconds: drift.inMicroseconds ~/ 2,
      ));
    }
  }

  void resetSync() {
    _syncHistory.clear();
    _averageSyncDrift = Duration.zero;
    _currentAudioOffset = Duration.zero;
    _currentVideoOffset = Duration.zero;
  }

  void dispose() {
    _syncMonitorTimer?.cancel();
    syncStateNotifier.dispose();
  }
}

class SyncState {
  final Duration currentDrift;
  final Duration averageDrift;
  final bool isInSync;
  final bool needsCorrection;

  const SyncState({
    this.currentDrift = Duration.zero,
    this.averageDrift = Duration.zero,
    this.isInSync = true,
    this.needsCorrection = false,
  });

  double get syncQualityPercentage {
    final driftMs = averageDrift.inMilliseconds.abs();
    if (driftMs <= 40) return 1.0;
    if (driftMs <= 100) return 0.8;
    if (driftMs <= 200) return 0.6;
    return 0.4;
  }
}
