import 'package:flutter/material.dart';
import 'package:y_player/y_player.dart';

void main() {
  // Enhanced initialization with performance optimizations
  YPlayerInitializer.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Enhanced Y Player Demo',
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late YPlayerController _controller;
  bool _showPerformanceDashboard = false;
  YPlayerPerformanceMonitor? _performanceMonitor;

  // Test URLs with different qualities for demonstration
  final List<String> _testUrls = [
    'https://www.youtube.com/watch?v=_qmk4dtMPgg',
    'https://www.youtube.com/watch?v=dQw4w9WgXcQ', // Classic
    'https://www.youtube.com/watch?v=9bZkp7q19f0', // PSY - GANGNAM STYLE
  ];

  int _currentUrlIndex = 0;
  String get _currentUrl => _testUrls[_currentUrlIndex];

  @override
  void initState() {
    super.initState();
    _controller = YPlayerController();
  }

  @override
  void dispose() {
    _performanceMonitor?.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _switchVideo() {
    setState(() {
      _currentUrlIndex = (_currentUrlIndex + 1) % _testUrls.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Enhanced YPlayer Example'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: Icon(_showPerformanceDashboard
                ? Icons.dashboard
                : Icons.dashboard_outlined),
            onPressed: () {
              setState(() {
                _showPerformanceDashboard = !_showPerformanceDashboard;
              });
            },
            tooltip: 'Toggle Performance Dashboard',
          ),
          IconButton(
            icon: const Icon(Icons.skip_next),
            onPressed: _switchVideo,
            tooltip: 'Switch Video',
          ),
        ],
      ),
      body: Column(
        children: [
          // Enhanced Y Player with all features enabled
          YPlayer(
            youtubeUrl: _currentUrl,
            autoPlay: true,
            chooseBestQuality: true, // Auto-adaptive quality
            color: Colors.red,
            aspectRatio: 16 / 9,
            onControllerReady: (controller) {
              _controller = controller;
              // Initialize performance monitor after controller is ready
              if (mounted) {
                setState(() {
                  _performanceMonitor = controller.performanceMonitor;
                });
              }
            },
            onStateChanged: (status) {
              debugPrint('Player Status: $status');
            },
            onProgressChanged: (position, duration) {
              // Update progress indicators if needed
            },
            loadingWidget: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading enhanced video player...'),
                ],
              ),
            ),
            errorWidget: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, size: 48, color: Colors.red),
                  SizedBox(height: 16),
                  Text('Error loading video. Please try again.'),
                ],
              ),
            ),
          ), // Performance Dashboard (Optional)
          if (_showPerformanceDashboard && _performanceMonitor != null) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: YPlayerPerformanceDashboard(
                performanceMonitor: _performanceMonitor!,
                isCompact: false,
              ),
            ),
          ],

          // Video Information and Controls
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Enhanced Features:',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  _buildFeatureList(),

                  const SizedBox(height: 16),

                  // Player Status Information
                  ValueListenableBuilder<YPlayerStatus>(
                    valueListenable: _controller.statusNotifier,
                    builder: (context, status, _) {
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Player Status: ${status.name}'),
                              Text(
                                  'Current Quality: ${_controller.currentQuality == 0 ? "Auto" : "${_controller.currentQuality}p"}'),
                              Text(
                                  'Available Qualities: ${_controller.getAvailableQualities().map((q) => q.label).join(", ")}'),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _switchVideo,
        tooltip: 'Switch to next video',
        child: const Icon(Icons.skip_next),
      ),
    );
  }

  Widget _buildFeatureList() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FeatureItem(
          icon: Icons.speed,
          title: 'Adaptive Streaming',
          description: 'Automatically adjusts quality based on network speed',
        ),
        _FeatureItem(
          icon: Icons.sync,
          title: 'Audio-Video Sync',
          description: 'Advanced synchronization to prevent lip-sync issues',
        ),
        _FeatureItem(
          icon: Icons.memory,
          title: 'Performance Monitoring',
          description: 'Real-time FPS tracking and performance optimization',
        ),
        _FeatureItem(
          icon: Icons.storage,
          title: 'Smart Buffering',
          description:
              'Predictive buffering to minimize playback interruptions',
        ),
        _FeatureItem(
          icon: Icons.network_check,
          title: 'Network Optimization',
          description: 'Continuous network speed monitoring and adaptation',
        ),
        _FeatureItem(
          icon: Icons.high_quality,
          title: 'Quality Selection',
          description:
              'Manual and automatic quality selection with smooth transitions',
        ),
      ],
    );
  }
}

class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _FeatureItem({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Colors.blue),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
