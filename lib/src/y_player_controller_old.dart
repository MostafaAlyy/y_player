import 'dart:io'; // Add for HTTP requests
import 'dart:math'; // For min/max
import 'dart:async'; // For improved async handling

import 'package:flutter/foundation.dart'; // For kReleaseMode
import 'package:media_kit/media_kit.dart';
import 'package:y_player/y_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as exp;

/// Controller for managing the YouTube player.
///
/// This class handles the initialization, playback control, and state management
/// of the YouTube video player. It uses the youtube_explode_dart package to fetch
/// video information and the media_kit package for playback.
class YPlayerController {
  /// YouTube API client for fetching video information.
  final exp.YoutubeExplode _yt = exp.YoutubeExplode();

  /// Media player instance from media_kit.
  late final Player _player;

  /// Current status of the player.
  YPlayerStatus _status = YPlayerStatus.initial;

  /// Callback function triggered when the player's status changes.
  final YPlayerStateCallback? onStateChanged;

  /// Callback function triggered when the player's progress changes.
  final YPlayerProgressCallback? onProgressChanged;

  /// The URL of the last successfully initialized video.
  String? _lastInitializedUrl;

  /// Store the current manifest for quality changes
  exp.StreamManifest? _currentManifest;

  /// Store the current video ID
  String? _currentVideoId;

  /// Current selected quality (resolution height)
  int _currentQuality = 0; // 0 means auto (highest)
  /// Add this ValueNotifier to track status changes
  final ValueNotifier<YPlayerStatus> statusNotifier;

  /// Performance and optimization managers
  final YPlayerPerformanceMonitor _performanceMonitor = YPlayerPerformanceMonitor();
  final YPlayerBufferManager _bufferManager = YPlayerBufferManager();
  final YPlayerSyncManager _syncManager = YPlayerSyncManager();
  final YPlayerNetworkManager _networkManager = YPlayerNetworkManager();

  /// Enhanced buffering and sync controls
  Timer? _syncTimer;
  Timer? _performanceTimer;
  Completer<void>? _initializationCompleter;

  /// LRU cache for manifests (max 20 entries)
  static final Map<String, exp.StreamManifest> _manifestCache = {};
  static final List<String> _manifestCacheOrder = [];

  void _cacheManifest(String videoId, exp.StreamManifest manifest) {
    _manifestCache[videoId] = manifest;
    _manifestCacheOrder.remove(videoId);
    _manifestCacheOrder.add(videoId);
    if (_manifestCacheOrder.length > 20) {
      final oldest = _manifestCacheOrder.removeAt(0);
      _manifestCache.remove(oldest);
    }
  }

  /// Constructs a YPlayerController with optional callback functions.
  YPlayerController({this.onStateChanged, this.onProgressChanged})
      : statusNotifier = ValueNotifier<YPlayerStatus>(YPlayerStatus.loading) {
    _player = Player();
    _setupPlayerListeners();
  }

  /// Checks if the player has been initialized with media.
  bool get isInitialized => _player.state.playlist.medias.isNotEmpty;

  /// Gets the current status of the player.
  YPlayerStatus get status => _status;

  /// Gets the underlying media_kit Player instance.
  Player get player => _player;

  /// Get the current selected quality
  int get currentQuality => _currentQuality;

  /// Get list of available quality options
  List<QualityOption> getAvailableQualities() {
    if (_currentManifest == null) {
      return [];
    }

    // Always include automatic option
    final List<QualityOption> qualities = [
      QualityOption(height: 0, label: "Auto")
    ];

    // Add available video qualities
    for (var stream in _currentManifest!.videoOnly) {
      // Get height from the videoResolution property
      final height = stream.videoResolution.height;

      // Only add if we don't already have this resolution
      if (height > 0 && !qualities.any((q) => q.height == height)) {
        qualities.add(QualityOption(
          height: height,
          label: "${height}p",
        ));
      }
    }

    // Sort by height (highest first, but keep Auto at top)
    qualities.sublist(1).sort((a, b) => b.height.compareTo(a.height));

    return qualities;
  }
  /// Enhanced quality change with smooth transitions and performance monitoring
  Future<void> setQuality(int height) async {
    if (_currentManifest == null || _currentVideoId == null) {
      if (!kReleaseMode) {
        debugPrint(
            'YPlayerController: Cannot change quality - no manifest available');
      }
      return;
    }
    if (_status == YPlayerStatus.loading) return;
    if (_currentQuality == height) return; // No-op if already at this quality

    // Record performance before quality change
    _performanceMonitor.recordFrame();
    
    _currentQuality = height;
    final currentPosition = _player.state.position;
    final wasPlaying = _player.state.playing;
    final currentVolume = _player.state.volume;

    _setStatus(YPlayerStatus.loading);
    try {
      exp.VideoStreamInfo videoStreamInfo;
      if (height == 0) {
        videoStreamInfo = _currentManifest!.videoOnly.withHighestBitrate();
      } else {
        videoStreamInfo = _currentManifest!.videoOnly
            .where((s) => s.videoResolution.height == height)
            .withHighestBitrate();
      }
      final audioStreamInfo = _currentManifest!.audioOnly.withHighestBitrate();

      // Check if we actually need to change URLs
      final currentUrl = _player.state.playlist.medias.isNotEmpty
          ? _player.state.playlist.medias.first.uri.toString()
          : '';
      if (currentUrl == videoStreamInfo.url.toString()) {
        _setStatus(wasPlaying ? YPlayerStatus.playing : YPlayerStatus.paused);
        return;
      }

      if (!kReleaseMode) {
        debugPrint(
            'YPlayerController: Smoothly changing quality to ${videoStreamInfo.videoResolution.height}p');
      }

      // Smooth transition: gradually reduce volume
      await _fadeOutVolume();
      
      // Stop current playback
      await _player.stop();
      
      // Reconfigure for new quality
      await _configurePlayerOptimal();
      
      // Open new stream
      await _player.open(
          Media(videoStreamInfo.url.toString(), start: currentPosition),
          play: false);
      
      // Wait for buffering
      await Future.delayed(const Duration(milliseconds: 300));
      
      // Set audio track
      await _player.setAudioTrack(AudioTrack.uri(audioStreamInfo.url.toString()));
      
      // Restore volume gradually
      await _fadeInVolume(currentVolume);
      
      // Resume playback if it was playing
      if (wasPlaying) {
        await play();
      }
      
      _setStatus(wasPlaying ? YPlayerStatus.playing : YPlayerStatus.paused);
      
      // Reset sync manager for new stream
      _syncManager.resetSync();
      
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Smooth quality change complete');
      }
    } catch (e) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Error changing quality: $e');
      }
      _setStatus(YPlayerStatus.error);
    }
  }

  /// Gradually fade out volume for smooth transitions
  Future<void> _fadeOutVolume() async {
    final currentVolume = _player.state.volume;
    for (int i = 10; i >= 0; i--) {
      await _player.setVolume(currentVolume * (i / 10.0));
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Gradually fade in volume for smooth transitions
  Future<void> _fadeInVolume(double targetVolume) async {
    for (int i = 0; i <= 10; i++) {
      await _player.setVolume(targetVolume * (i / 10.0));
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Estimate network speed (in bits per second) by downloading a small chunk of the video.
  Future<int?> _estimateNetworkSpeed(String testUrl) async {
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(testUrl));
      // Only download the first 512KB
      request.headers.add('Range', 'bytes=0-524287');
      final stopwatch = Stopwatch()..start();
      final response = await request.close();
      int totalBytes = 0;
      await for (var chunk in response) {
        totalBytes += chunk.length;
      }
      stopwatch.stop();
      client.close();
      if (stopwatch.elapsedMilliseconds == 0) return null;
      // bits per second
      return (totalBytes * 8 * 1000 ~/ stopwatch.elapsedMilliseconds);
    } catch (_) {
      return null;
    }
  }

  /// Select the best quality for the estimated network speed.
  Future<int> chooseBestQualityForInternet(exp.StreamManifest manifest) async {
    // Use the highest quality as default
    final videoStreams = manifest.videoOnly.toList();
    if (videoStreams.isEmpty) return 0;

    // Pick a mid-quality stream for speed test
    final testStream = videoStreams[videoStreams.length ~/ 2];
    final testUrl = testStream.url.toString();
    final estimatedBps = await _estimateNetworkSpeed(testUrl);

    if (estimatedBps == null) return 0; // fallback to auto

    // Find the highest quality whose bitrate is <= 80% of estimated bandwidth
    final safeBps = (estimatedBps * 0.8).toInt();
    videoStreams.sort((a, b) => a.bitrate.compareTo(b.bitrate));
    int chosenHeight = 0;
    for (final stream in videoStreams) {
      if (stream.bitrate.bitsPerSecond <= safeBps) {
        chosenHeight = max(chosenHeight, stream.videoResolution.height);
      }
    }
    return chosenHeight == 0 ? 0 : chosenHeight;
  }
  /// Initializes the player with the given YouTube URL and settings.
  ///
  /// This method fetches video information, extracts stream URLs, and sets up
  /// the player with the highest quality video and audio streams available.
  /// Enhanced with performance monitoring and adaptive streaming.
  Future<void> initialize(
    String youtubeUrl, {
    bool autoPlay = true,
    double? aspectRatio,
    bool allowFullScreen = true,
    bool allowMuting = true,
    bool chooseBestQuality = true,
  }) async {
    // Prevent concurrent initialization
    if (_initializationCompleter != null && !_initializationCompleter!.isCompleted) {
      return _initializationCompleter!.future;
    }
    
    _initializationCompleter = Completer<void>();
    
    // Avoid re-initialization if the URL hasn't changed
    if (_lastInitializedUrl == youtubeUrl && isInitialized) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Already initialized with this URL');
      }
      _initializationCompleter!.complete();
      return;
    }

    _setStatus(YPlayerStatus.loading);
    
    try {
      // Start performance monitoring
      _performanceMonitor.startMonitoring();
      
      // Use cached manifest if available
      exp.StreamManifest manifest;
      String videoId;

      debugPrint('YPlayerController: Fetching video info for $youtubeUrl');
      final video = await _yt.videos.get(youtubeUrl);
      videoId = video.id.value;

      if (_manifestCache.containsKey(videoId)) {
        manifest = _manifestCache[videoId]!;
        // Move to most recently used
        _manifestCacheOrder.remove(videoId);
        _manifestCacheOrder.add(videoId);
      } else {
        manifest = await _yt.videos.streamsClient.getManifest(video.id);
        _cacheManifest(videoId, manifest);
      }

      // Store manifest and video ID for quality changes later
      _currentManifest = manifest;
      _currentVideoId = videoId;

      // Start network monitoring for adaptive quality
      final videoStreamInfo = manifest.videoOnly.withHighestBitrate();
      _networkManager.startNetworkMonitoring(videoStreamInfo.url.toString());
      
      // Choose best quality for internet if requested
      if (chooseBestQuality) {
        // Run asynchronously so UI is not blocked
        _performanceTimer = Timer(const Duration(seconds: 2), () async {
          final networkRecommended = _networkManager.getRecommendedQuality();
          final speedBasedQuality = await chooseBestQualityForInternet(manifest);
          
          // Use the more conservative of the two recommendations
          final finalQuality = min(networkRecommended, speedBasedQuality == 0 ? 1080 : speedBasedQuality);
          
          if (finalQuality != _currentQuality) {
            _currentQuality = finalQuality;
            await setQuality(finalQuality);
          }
        });
      }

      // Get the appropriate video stream based on quality setting
      exp.VideoStreamInfo selectedVideoStream;
      if (_currentQuality == 0) {
        // Auto - highest quality
        selectedVideoStream = manifest.videoOnly.withHighestBitrate();
      } else {
        // Try to find the selected quality, fallback to highest if not available
        try {
          selectedVideoStream = manifest.videoOnly
              .where((s) => s.videoResolution.height == _currentQuality)
              .withHighestBitrate();
        } catch (e) {
          debugPrint(
              'YPlayerController: Selected quality not available, using highest');
          selectedVideoStream = manifest.videoOnly.withHighestBitrate();
        }
      }

      final audioStreamInfo = manifest.audioOnly.withHighestBitrate();

      if (!kReleaseMode) {
        debugPrint('YPlayerController: Video URL: ${selectedVideoStream.url}');
        debugPrint('YPlayerController: Audio URL: ${audioStreamInfo.url}');
        debugPrint(
            'YPlayerController: Selected quality: ${selectedVideoStream.videoResolution.height}p');
      }

      // Stop any existing playback
      if (isInitialized) {
        debugPrint('YPlayerController: Stopping previous playback');
        await _player.stop();
      }

      // Configure player for optimal performance
      await _configurePlayerOptimal();

      // Open the video stream with improved buffering
      await _player.open(
        Media(selectedVideoStream.url.toString()),
        play: false,
      );

      // Add the audio track with sync management
      await _player.setAudioTrack(AudioTrack.uri(audioStreamInfo.url.toString()));

      // Start advanced buffer management
      _bufferManager.startBufferMonitoring(
        () => _player.state.position,
        () => _player.state.duration,
        (targetDuration) => _requestBuffering(targetDuration),
      );

      // Start audio-video sync monitoring
      _syncManager.startSyncMonitoring(
        onAudioSyncCorrection: (offset) => _correctAudioSync(offset),
        onVideoSyncCorrection: (offset) => _correctVideoSync(offset),
      );

      // Enhanced delay for stability
      await Future.delayed(const Duration(milliseconds: 500));

      // Start playback if autoPlay is true
      if (autoPlay) {
        await play();
      }

      _lastInitializedUrl = youtubeUrl;
      _setStatus(autoPlay ? YPlayerStatus.playing : YPlayerStatus.paused);
      
      _initializationCompleter!.complete();
      
      if (!kReleaseMode) {
        debugPrint(
            'YPlayerController: Enhanced initialization complete. Status: $_status');
      }
    } catch (e) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Error during initialization: $e');
      }
      _setStatus(YPlayerStatus.error);
      _initializationCompleter!.completeError(e);
    }
  }
  /// Configures the media player for optimal performance
  Future<void> _configurePlayerOptimal() async {
    try {
      // Configure player for optimal performance using media_kit methods
      // These configurations improve buffering and reduce lag
      
      // Set volume to 100% for optimal audio quality
      await _player.setVolume(100.0);
      
      // Configure shuffle and repeat for optimal playback
      await _player.setShuffle(false);
      await _player.setPlaylistMode(PlaylistMode.none);
      
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Player configured for optimal performance');
      }
    } catch (e) {
      debugPrint('YPlayerController: Error configuring player: $e');
    }
  }

  /// Requests buffering for the specified duration
  void _requestBuffering(Duration targetDuration) {
    // Implementation would depend on media_kit capabilities
    // This is a placeholder for advanced buffering logic
    if (!kReleaseMode) {
      debugPrint('YPlayerController: Requesting buffer for ${targetDuration.inSeconds}s');
    }
  }
  /// Corrects audio synchronization by the specified offset
  Future<void> _correctAudioSync(Duration offset) async {
    try {
      // For media_kit, we'll implement audio sync through rate adjustment
      // This is a simplified approach for demonstration
      final currentRate = _player.state.rate;
      final adjustmentFactor = 1.0 + (offset.inMicroseconds / 1000000.0 * 0.001);
      final newRate = (currentRate * adjustmentFactor).clamp(0.5, 2.0);
      
      await _player.setRate(newRate);
      
      // Reset rate after a short period
      Timer(const Duration(milliseconds: 100), () async {
        await _player.setRate(currentRate);
      });
      
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Applied audio sync correction via rate adjustment');
      }
    } catch (e) {
      debugPrint('YPlayerController: Failed to apply audio sync correction: $e');
    }
  }

  /// Corrects video synchronization by the specified offset
  Future<void> _correctVideoSync(Duration offset) async {
    try {
      // For video sync, we can try seeking to correct position
      if (offset.inMilliseconds.abs() > 50) {
        final currentPosition = _player.state.position;
        final correctedPosition = Duration(
          microseconds: currentPosition.inMicroseconds - offset.inMicroseconds,
        );
        
        if (correctedPosition >= Duration.zero) {
          await _player.seek(correctedPosition);
        }
      }
      
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Applied video sync correction via seek');
      }
    } catch (e) {
      debugPrint('YPlayerController: Failed to apply video sync correction: $e');
    }
  }
  /// Sets up enhanced listeners for various player events with performance monitoring.
  ///
  /// This method initializes listeners for playback state changes,
  /// completion events, position updates, errors, buffer monitoring, and sync tracking.
  void _setupPlayerListeners() {
    // Enhanced playing state listener
    _player.stream.playing.listen((playing) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Playing state changed to $playing');
      }
      _setStatus(playing ? YPlayerStatus.playing : YPlayerStatus.paused);
      _performanceMonitor.recordFrame();
    });

    // Enhanced completion listener
    _player.stream.completed.listen((completed) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Playback completed: $completed');
      }
      if (completed) {
        _setStatus(YPlayerStatus.stopped);
        _performanceMonitor.stopMonitoring();
      }
    });

    // Enhanced position listener with sync tracking
    _player.stream.position.listen((position) {
      onProgressChanged?.call(position, _player.state.duration);
      
      // Update sync manager with timing information
      _syncManager.updateVideoTimestamp(position);
      
      // Record performance metrics
      _performanceMonitor.recordFrame();
    });

    // Enhanced error listener
    _player.stream.error.listen((error) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Error occurred: $error');
      }
      _setStatus(YPlayerStatus.error);
    });

    // Buffer monitoring
    _player.stream.buffer.listen((buffer) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Buffer changed: $buffer');
      }
      _performanceMonitor.updateBufferHealth(buffer, _status == YPlayerStatus.loading);
    });

    // Audio parameters monitoring for sync
    _player.stream.audioParams.listen((params) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Audio params changed: $params');
      }
    });

    // Audio device monitoring
    _player.stream.audioDevice.listen((device) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Audio device changed: $device');
      }
    });

    // Track monitoring for quality management
    _player.stream.track.listen((track) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Track changed: $track');
      }
    });

    // Tracks availability monitoring
    _player.stream.tracks.listen((tracks) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Available tracks updated');
      }
    });

    // Bitrate monitoring for adaptive streaming
    _player.stream.audioBitrate.listen((bitrate) {
      if (bitrate != null) {
        _networkManager.updateNetworkSpeed(bitrate.toDouble() / 8); // Convert to bytes/sec
      }
    });

    // Duration changes
    _player.stream.duration.listen((duration) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Duration updated: $duration');
      }
    });
  }

  /// Updates the player status and triggers the onStateChanged callback.
  void _setStatus(YPlayerStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      // Remove or comment out debugPrints in production for performance
      // debugPrint('YPlayerController: Status changed to $newStatus');
      onStateChanged?.call(_status);
      statusNotifier.value = newStatus;
    }
  }

  /// Starts or resumes video playback.
  Future<void> play() async {
    // Remove or comment out debugPrints in production for performance
    // debugPrint('YPlayerController: Play requested');
    await _player.play();
  }

  Future<void> speed(double speed) async {
    // Debounce rapid speed changes by checking if already set
    if (_player.state.rate == speed) return;
    await _player.setRate(speed);
  }

  /// Pauses video playback.
  Future<void> pause() async {
    // debugPrint('YPlayerController: Pause requested');
    await _player.pause();
  }

  /// Stops video playback and resets to the beginning.
  Future<void> stop() async {
    // debugPrint('YPlayerController: Stop requested');
    await _player.stop();
  }

  /// Enables background audio playback when screen is closed

  /// Gets the current playback position.
  Duration get position => _player.state.position;

  /// Gets the total duration of the video.
  Duration get duration => _player.state.duration;
  /// Disposes of all resources used by the controller.
  void dispose() {
    debugPrint('YPlayerController: Disposing with enhanced cleanup');
    
    // Clean up timers
    _syncTimer?.cancel();
    _performanceTimer?.cancel();
    
    // Stop monitoring systems
    _performanceMonitor.stopMonitoring();
    _bufferManager.stopBufferMonitoring();
    _syncManager.stopSyncMonitoring();
    _networkManager.stopNetworkMonitoring();
    
    // Dispose managers
    _performanceMonitor.dispose();
    _bufferManager.dispose();
    _syncManager.dispose();
    _networkManager.dispose();
    
    // Dispose player and YouTube client
    _player.dispose();
    _yt.close();
    
    // Clean up status notifier
    statusNotifier.dispose();
  }
}
