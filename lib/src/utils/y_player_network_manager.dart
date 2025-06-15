import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Network optimization manager for adaptive streaming
/// Handles network speed detection and quality adaptation
class YPlayerNetworkManager {
  static const Duration _speedTestInterval = Duration(seconds: 30);
  static const int _speedTestDataSize = 1024 * 1024; // 1MB

  Timer? _networkMonitorTimer;
  double _currentSpeed = 0; // bytes per second
  double _averageSpeed = 0;
  NetworkQuality _networkQuality = NetworkQuality.unknown;

  final List<double> _speedMeasurements = [];
  final ValueNotifier<NetworkState> networkStateNotifier =
      ValueNotifier(NetworkState());

  void startNetworkMonitoring(String testUrl) {
    _networkMonitorTimer?.cancel();
    _networkMonitorTimer = Timer.periodic(
      _speedTestInterval,
      (timer) => _measureNetworkSpeed(testUrl),
    );

    // Initial measurement
    _measureNetworkSpeed(testUrl);
  }

  void stopNetworkMonitoring() {
    _networkMonitorTimer?.cancel();
  }

  Future<void> _measureNetworkSpeed(String testUrl) async {
    try {
      final speed = await _performSpeedTest(testUrl);
      if (speed > 0) {
        _updateNetworkMetrics(speed);
      }
    } catch (e) {
      if (kDebugMode) {
        print('Network speed test failed: $e');
      }
    }
  }

  Future<double> _performSpeedTest(String testUrl) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);

    try {
      final uri = Uri.parse(testUrl);
      final request = await client.getUrl(uri);

      // Request a specific range for testing
      request.headers.add('Range', 'bytes=0-${_speedTestDataSize - 1}');

      final stopwatch = Stopwatch()..start();
      final response = await request.close();

      int totalBytes = 0;
      await for (final chunk in response) {
        totalBytes += chunk.length;

        // Stop if we've downloaded enough data or taken too long
        if (totalBytes >= _speedTestDataSize ||
            stopwatch.elapsedMilliseconds > 10000) {
          break;
        }
      }

      stopwatch.stop();
      client.close();

      if (stopwatch.elapsedMilliseconds > 0) {
        return (totalBytes * 1000) /
            stopwatch.elapsedMilliseconds; // bytes per second
      }
    } catch (e) {
      client.close();
      rethrow;
    }

    return 0;
  }

  void _updateNetworkMetrics(double speed) {
    _currentSpeed = speed;
    _speedMeasurements.add(speed);

    // Keep only last 10 measurements
    if (_speedMeasurements.length > 10) {
      _speedMeasurements.removeAt(0);
    }

    // Calculate weighted average (recent measurements have more weight)
    double totalWeight = 0;
    double weightedSum = 0;

    for (int i = 0; i < _speedMeasurements.length; i++) {
      final weight = (i + 1) / _speedMeasurements.length;
      totalWeight += weight;
      weightedSum += _speedMeasurements[i] * weight;
    }

    _averageSpeed = weightedSum / totalWeight;
    _networkQuality = _calculateNetworkQuality(_averageSpeed);

    // Update network state
    networkStateNotifier.value = NetworkState(
      currentSpeed: _currentSpeed,
      averageSpeed: _averageSpeed,
      quality: _networkQuality,
      isStable: _isNetworkStable(),
    );
  }

  NetworkQuality _calculateNetworkQuality(double speed) {
    // Convert to Mbps for easier thresholds
    final speedMbps = speed * 8 / (1024 * 1024);

    if (speedMbps >= 25) return NetworkQuality.excellent;
    if (speedMbps >= 10) return NetworkQuality.good;
    if (speedMbps >= 5) return NetworkQuality.fair;
    if (speedMbps >= 1) return NetworkQuality.poor;
    return NetworkQuality.veryPoor;
  }

  bool _isNetworkStable() {
    if (_speedMeasurements.length < 3) return true;

    // Calculate coefficient of variation
    final mean = _averageSpeed;
    double variance = 0;

    for (final speed in _speedMeasurements) {
      variance += (speed - mean) * (speed - mean);
    }

    variance /= _speedMeasurements.length;
    final standardDeviation = sqrt(variance);
    final coefficientOfVariation = standardDeviation / mean;

    // Network is stable if CV < 0.3
    return coefficientOfVariation < 0.3;
  }

  int getRecommendedQuality() {
    switch (_networkQuality) {
      case NetworkQuality.excellent:
        return 1080;
      case NetworkQuality.good:
        return 720;
      case NetworkQuality.fair:
        return 480;
      case NetworkQuality.poor:
        return 360;
      case NetworkQuality.veryPoor:
        return 240;
      case NetworkQuality.unknown:
        return 480; // Safe default
    }
  }

  /// Public method to update network speed from external sources
  void updateNetworkSpeed(double bytesPerSecond) {
    _updateNetworkMetrics(bytesPerSecond);
  }

  /// Get current network state
  NetworkState get currentState => networkStateNotifier.value;

  void dispose() {
    _networkMonitorTimer?.cancel();
    networkStateNotifier.dispose();
  }
}

enum NetworkQuality {
  unknown,
  veryPoor,
  poor,
  fair,
  good,
  excellent,
}

class NetworkState {
  final double currentSpeed;
  final double averageSpeed;
  final NetworkQuality quality;
  final bool isStable;

  const NetworkState({
    this.currentSpeed = 0,
    this.averageSpeed = 0,
    this.quality = NetworkQuality.unknown,
    this.isStable = true,
  });

  double get speedMbps => (averageSpeed * 8) / (1024 * 1024);

  String get qualityDescription {
    switch (quality) {
      case NetworkQuality.excellent:
        return 'Excellent (25+ Mbps)';
      case NetworkQuality.good:
        return 'Good (10-25 Mbps)';
      case NetworkQuality.fair:
        return 'Fair (5-10 Mbps)';
      case NetworkQuality.poor:
        return 'Poor (1-5 Mbps)';
      case NetworkQuality.veryPoor:
        return 'Very Poor (<1 Mbps)';
      case NetworkQuality.unknown:
        return 'Unknown';
    }
  }
}
