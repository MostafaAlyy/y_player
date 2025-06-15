import 'package:flutter/material.dart';
import 'package:y_player/src/utils/y_player_performance_monitor.dart';
import 'package:y_player/src/utils/y_player_buffer_manager.dart';
import 'package:y_player/src/utils/y_player_sync_manager.dart';
import 'package:y_player/src/utils/y_player_network_manager.dart';

/// Optional performance dashboard for debugging and monitoring
/// Shows real-time performance metrics, buffer health, and sync status
class YPlayerPerformanceDashboard extends StatelessWidget {
  final YPlayerPerformanceMonitor performanceMonitor;
  final YPlayerBufferManager? bufferManager;
  final YPlayerSyncManager? syncManager;
  final YPlayerNetworkManager? networkManager;
  final bool isCompact;

  const YPlayerPerformanceDashboard({
    super.key,
    required this.performanceMonitor,
    this.bufferManager,
    this.syncManager,
    this.networkManager,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isCompact) {
      return _buildCompactDashboard(context);
    } else {
      return _buildFullDashboard(context);
    }
  }

  Widget _buildCompactDashboard(BuildContext context) {
    return ValueListenableBuilder<PerformanceMetrics>(
      valueListenable: performanceMonitor.metricsNotifier,
      builder: (context, metrics, _) {
        return Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildMetricChip('FPS', metrics.fps.toStringAsFixed(1),
                  metrics.fps > 55 ? Colors.green : Colors.orange),
              const SizedBox(width: 4),
              _buildMetricChip(
                  'Drops',
                  '${(metrics.frameDropRate * 100).toStringAsFixed(1)}%',
                  metrics.frameDropRate < 0.05 ? Colors.green : Colors.red),
              const SizedBox(width: 4),
              Icon(
                metrics.isPerformanceGood ? Icons.check_circle : Icons.warning,
                color: metrics.isPerformanceGood ? Colors.green : Colors.orange,
                size: 16,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFullDashboard(BuildContext context) {
    return Container(
      width: 300,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Performance Monitor',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Divider(color: Colors.white24),

          // Performance Metrics
          ValueListenableBuilder<PerformanceMetrics>(
            valueListenable: performanceMonitor.metricsNotifier,
            builder: (context, metrics, _) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildMetricRow(
                      'Frame Rate',
                      '${metrics.fps.toStringAsFixed(1)} FPS',
                      metrics.fps > 55 ? Colors.green : Colors.orange),
                  _buildMetricRow(
                      'Frame Drops',
                      '${(metrics.frameDropRate * 100).toStringAsFixed(1)}%',
                      metrics.frameDropRate < 0.05 ? Colors.green : Colors.red),
                  _buildMetricRow(
                      'Buffer Health',
                      '${metrics.bufferHealth.inSeconds}s',
                      metrics.bufferHealth.inSeconds > 5
                          ? Colors.green
                          : Colors.orange),
                  _buildMetricRow(
                      'A/V Sync',
                      '${metrics.audioVideoSync.inMilliseconds}ms',
                      !metrics.hasSyncIssues ? Colors.green : Colors.red),
                ],
              );
            },
          ),

          // Network Status
          if (networkManager != null) ...[
            const SizedBox(height: 8),
            const Text(
              'Network Status',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w500),
            ),
            ValueListenableBuilder<NetworkState>(
              valueListenable: networkManager!.networkStateNotifier,
              builder: (context, networkState, _) {
                return Column(
                  children: [
                    _buildMetricRow(
                        'Speed',
                        '${networkState.speedMbps.toStringAsFixed(1)} Mbps',
                        networkState.quality.index >= 3
                            ? Colors.green
                            : Colors.orange),
                    _buildMetricRow(
                        'Quality',
                        networkState.qualityDescription,
                        networkState.quality.index >= 3
                            ? Colors.green
                            : Colors.orange),
                    _buildMetricRow(
                        'Stability',
                        networkState.isStable ? 'Stable' : 'Unstable',
                        networkState.isStable ? Colors.green : Colors.red),
                  ],
                );
              },
            ),
          ],

          // Buffer Status
          if (bufferManager != null) ...[
            const SizedBox(height: 8),
            const Text(
              'Buffer Status',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w500),
            ),
            ValueListenableBuilder<BufferState>(
              valueListenable: bufferManager!.bufferStateNotifier,
              builder: (context, bufferState, _) {
                return Column(
                  children: [
                    _buildMetricRow(
                        'Current',
                        '${bufferState.currentLevel.inSeconds}s',
                        bufferState.isHealthy ? Colors.green : Colors.orange),
                    _buildMetricRow('Target',
                        '${bufferState.targetLevel.inSeconds}s', Colors.blue),
                    _buildMetricRow(
                        'Health',
                        '${(bufferState.bufferHealthPercentage * 100).toStringAsFixed(1)}%',
                        bufferState.isHealthy ? Colors.green : Colors.red),
                  ],
                );
              },
            ),
          ],

          // Sync Status
          if (syncManager != null) ...[
            const SizedBox(height: 8),
            const Text(
              'Sync Status',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w500),
            ),
            ValueListenableBuilder<SyncState>(
              valueListenable: syncManager!.syncStateNotifier,
              builder: (context, syncState, _) {
                return Column(
                  children: [
                    _buildMetricRow(
                        'Current Drift',
                        '${syncState.currentDrift.inMilliseconds}ms',
                        syncState.isInSync ? Colors.green : Colors.orange),
                    _buildMetricRow(
                        'Average Drift',
                        '${syncState.averageDrift.inMilliseconds}ms',
                        syncState.isInSync ? Colors.green : Colors.red),
                    _buildMetricRow(
                        'Sync Quality',
                        '${(syncState.syncQualityPercentage * 100).toStringAsFixed(1)}%',
                        syncState.syncQualityPercentage > 0.8
                            ? Colors.green
                            : Colors.orange),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMetricChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color, width: 0.5),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildMetricRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          Text(
            value,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
