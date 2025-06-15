import 'dart:async';

import 'package:flutter/foundation.dart';

/// Performance monitoring utility for Y Player
/// Tracks frame drops, buffer health, and audio-video sync
class YPlayerPerformanceMonitor {
  static final YPlayerPerformanceMonitor _instance =
      YPlayerPerformanceMonitor._internal();
  factory YPlayerPerformanceMonitor() => _instance;
  YPlayerPerformanceMonitor._internal();

  Timer? _performanceTimer;
  DateTime _lastFrameTime = DateTime.now();
  int _frameDropCount = 0;
  int _totalFrames = 0;
  double _averageFrameTime = 16.67; // Target 60fps

  // Buffer health tracking
  Duration _bufferHealth = Duration.zero;
  bool _isBuffering = false;
  // Audio-video sync tracking
  final List<Duration> _syncSamples = [];

  final ValueNotifier<PerformanceMetrics> metricsNotifier =
      ValueNotifier(PerformanceMetrics());

  void startMonitoring() {
    _performanceTimer?.cancel();
    _performanceTimer =
        Timer.periodic(const Duration(seconds: 1), _updateMetrics);
  }

  void stopMonitoring() {
    _performanceTimer?.cancel();
  }

  void recordFrame() {
    final now = DateTime.now();
    final frameTime = now.difference(_lastFrameTime).inMicroseconds / 1000.0;

    _totalFrames++;
    if (frameTime > 33.34) {
      // More than 2 frames at 60fps
      _frameDropCount++;
    }

    _averageFrameTime = (_averageFrameTime * 0.9) + (frameTime * 0.1);
    _lastFrameTime = now;
  }

  void updateBufferHealth(Duration bufferDuration, bool isBuffering) {
    _bufferHealth = bufferDuration;
    _isBuffering = isBuffering;
  }

  void recordAudioVideoSync(Duration offset) {
    _syncSamples.add(offset);
    if (_syncSamples.length > 60) {
      _syncSamples.removeAt(0);
    }
  }

  void _updateMetrics(Timer timer) {
    final fps = _totalFrames > 0 ? 1000.0 / _averageFrameTime : 0.0;
    final dropRate = _totalFrames > 0 ? _frameDropCount / _totalFrames : 0.0;

    // Calculate average sync offset
    final avgSync = _syncSamples.isNotEmpty
        ? _syncSamples.reduce((a, b) =>
            Duration(microseconds: a.inMicroseconds + b.inMicroseconds))
        : Duration.zero;

    final metrics = PerformanceMetrics(
      fps: fps,
      frameDropRate: dropRate,
      bufferHealth: _bufferHealth,
      isBuffering: _isBuffering,
      audioVideoSync: _syncSamples.isNotEmpty
          ? Duration(
              microseconds: avgSync.inMicroseconds ~/ _syncSamples.length)
          : Duration.zero,
    );

    metricsNotifier.value = metrics;

    // Reset counters for next interval
    _frameDropCount = 0;
    _totalFrames = 0;
  }

  void dispose() {
    _performanceTimer?.cancel();
    metricsNotifier.dispose();
  }
}

class PerformanceMetrics {
  final double fps;
  final double frameDropRate;
  final Duration bufferHealth;
  final bool isBuffering;
  final Duration audioVideoSync;

  const PerformanceMetrics({
    this.fps = 0.0,
    this.frameDropRate = 0.0,
    this.bufferHealth = Duration.zero,
    this.isBuffering = false,
    this.audioVideoSync = Duration.zero,
  });

  bool get isPerformanceGood =>
      fps > 55 && frameDropRate < 0.05 && bufferHealth.inSeconds > 5;

  bool get hasSyncIssues => audioVideoSync.inMilliseconds.abs() > 100;
}
