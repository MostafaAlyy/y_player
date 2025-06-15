import 'dart:async';

import 'package:flutter/foundation.dart';

/// Advanced buffer management for smooth playback
/// Implements predictive buffering and adaptive streaming
class YPlayerBufferManager {
  static const Duration _targetBufferDuration = Duration(seconds: 30);
  static const Duration _minBufferDuration = Duration(seconds: 5);
  static const Duration _maxBufferDuration = Duration(seconds: 60);

  Timer? _bufferMonitorTimer;
  Duration _currentBufferLevel = Duration.zero;
  double _networkSpeed = 0; // bytes per second
  bool _isBuffering = false;

  final ValueNotifier<BufferState> bufferStateNotifier =
      ValueNotifier(BufferState());

  // Predictive buffering
  final List<double> _speedHistory = [];
  double _predictedSpeed = 0;

  void startBufferMonitoring(
    Duration Function() getCurrentPosition,
    Duration Function() getTotalDuration,
    void Function(Duration) requestBuffer,
  ) {
    _bufferMonitorTimer?.cancel();
    _bufferMonitorTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (timer) =>
          _monitorBuffer(getCurrentPosition, getTotalDuration, requestBuffer),
    );
  }

  void stopBufferMonitoring() {
    _bufferMonitorTimer?.cancel();
  }

  void updateNetworkSpeed(double bytesPerSecond) {
    _networkSpeed = bytesPerSecond;
    _speedHistory.add(bytesPerSecond);

    // Keep only last 10 measurements
    if (_speedHistory.length > 10) {
      _speedHistory.removeAt(0);
    }

    // Calculate predicted speed using weighted average
    if (_speedHistory.isNotEmpty) {
      double totalWeight = 0;
      double weightedSum = 0;

      for (int i = 0; i < _speedHistory.length; i++) {
        final weight =
            (i + 1) / _speedHistory.length; // More recent = higher weight
        totalWeight += weight;
        weightedSum += _speedHistory[i] * weight;
      }

      _predictedSpeed = weightedSum / totalWeight;
    }
  }

  void _monitorBuffer(
    Duration Function() getCurrentPosition,
    Duration Function() getTotalDuration,
    void Function(Duration) requestBuffer,
  ) {
    final currentPos = getCurrentPosition();
    final totalDuration = getTotalDuration();

    if (totalDuration == Duration.zero) return;

    // Calculate how much is buffered ahead
    _currentBufferLevel = _calculateBufferAhead(currentPos, totalDuration);

    // Determine if we need to buffer more
    final targetBuffer = _calculateTargetBufferDuration();

    if (_currentBufferLevel < targetBuffer && !_isBuffering) {
      _startBuffering(requestBuffer, targetBuffer);
    } else if (_currentBufferLevel > _maxBufferDuration && _isBuffering) {
      _stopBuffering();
    }

    // Update buffer state
    bufferStateNotifier.value = BufferState(
      currentLevel: _currentBufferLevel,
      targetLevel: targetBuffer,
      isBuffering: _isBuffering,
      networkSpeed: _networkSpeed,
      predictedSpeed: _predictedSpeed,
    );
  }

  Duration _calculateBufferAhead(Duration currentPos, Duration totalDuration) {
    // This is a simplified calculation
    // In a real implementation, you'd track actual buffered ranges
    final remaining = totalDuration - currentPos;
    return remaining > _targetBufferDuration
        ? _targetBufferDuration
        : remaining;
  }

  Duration _calculateTargetBufferDuration() {
    // Adaptive target based on network conditions
    if (_predictedSpeed > 1000000) {
      // > 1 MB/s
      return _targetBufferDuration;
    } else if (_predictedSpeed > 500000) {
      // > 500 KB/s
      return const Duration(seconds: 20);
    } else {
      return _minBufferDuration;
    }
  }

  void _startBuffering(
      void Function(Duration) requestBuffer, Duration targetBuffer) {
    _isBuffering = true;
    requestBuffer(targetBuffer);
  }

  void _stopBuffering() {
    _isBuffering = false;
  }

  void dispose() {
    _bufferMonitorTimer?.cancel();
    bufferStateNotifier.dispose();
  }
}

class BufferState {
  final Duration currentLevel;
  final Duration targetLevel;
  final bool isBuffering;
  final double networkSpeed;
  final double predictedSpeed;

  const BufferState({
    this.currentLevel = Duration.zero,
    this.targetLevel = Duration.zero,
    this.isBuffering = false,
    this.networkSpeed = 0,
    this.predictedSpeed = 0,
  });

  double get bufferHealthPercentage {
    if (targetLevel == Duration.zero) return 0;
    return (currentLevel.inMilliseconds / targetLevel.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  bool get isHealthy => bufferHealthPercentage > 0.5;
}
