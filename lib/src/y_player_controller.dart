import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:y_player/y_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as exp;

/// Enhanced YouTube player controller with stability fixes and performance optimizations.
///
/// This controller provides robust video playback with proper error handling,
/// smooth quality switching, and optimized buffering.
class YPlayerController {
  /// YouTube API client for fetching video information.
  final exp.YoutubeExplode _yt = exp.YoutubeExplode();

  /// Media player instance from media_kit.
  late final Player _player;

  /// Performance monitor for troubleshooting
  YPlayerPerformanceMonitor? performanceMonitor;

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

  /// ValueNotifier to track status changes efficiently
  final ValueNotifier<YPlayerStatus> statusNotifier;

  /// LRU cache for manifests (max 10 entries for stability)
  static final Map<String, exp.StreamManifest> _manifestCache = {};
  static final List<String> _manifestCacheOrder = [];

  /// Initialization state management
  bool _isInitializing = false;
  Completer<void>? _initCompleter;

  /// Error retry management
  int _retryCount = 0;
  static const int _maxRetries = 3;

  void _cacheManifest(String videoId, exp.StreamManifest manifest) {
    _manifestCache[videoId] = manifest;
    _manifestCacheOrder.remove(videoId);
    _manifestCacheOrder.add(videoId);
    if (_manifestCacheOrder.length > 10) {
      final oldest = _manifestCacheOrder.removeAt(0);
      _manifestCache.remove(oldest);
    }
  }

  /// Constructs a YPlayerController with optional callback functions.
  YPlayerController({this.onStateChanged, this.onProgressChanged})
      : statusNotifier = ValueNotifier<YPlayerStatus>(YPlayerStatus.initial) {
    _player = Player();
    performanceMonitor = YPlayerPerformanceMonitor();
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

  /// Performance optimization settings
  static const Duration _mainThreadReleaseDelay = Duration(milliseconds: 1);

  /// Release main thread during heavy operations to prevent frame drops
  Future<void> _releaseMainThread() async {
    await Future.delayed(_mainThreadReleaseDelay);
  }

  /// Configure quality transition timing (in milliseconds)
  /// Lower values = faster transitions but potentially more jarring
  /// Higher values = smoother transitions but longer interruption
  int qualityTransitionDelayMs = 50;

  /// Get list of available quality options (filtered for compatibility)
  List<QualityOption> getAvailableQualities() {
    if (_currentManifest == null) {
      debugPrint(
          'YPlayerController: No manifest available for quality options');
      return [];
    }

    // Always include automatic option
    final List<QualityOption> qualities = [
      QualityOption(height: 0, label: "Auto")
    ];

    // Standard safe video resolutions to prefer
    const preferredResolutions = {240, 360, 480, 720, 1080};

    // Track added heights to avoid duplicates
    final heights = <int>{};

    // Phase 1: Add preferred safe qualities
    for (var stream in _currentManifest!.videoOnly) {
      final height = stream.videoResolution.height;

      if (height > 0 &&
          height <= 1080 &&
          preferredResolutions.contains(height) &&
          heights.add(height)) {
        final codec = stream.videoCodec.toLowerCase();
        if (codec.contains('avc') ||
            codec.contains('h264') ||
            (codec.contains('vp9') && height <= 720)) {
          qualities.add(QualityOption(
            height: height,
            label: "${height}p",
          ));
          debugPrint(
              'YPlayerController: Added preferred quality: ${height}p ($codec)');
        }
      }
    }

    // Phase 2: If we have very few options, add more compatible streams
    if (qualities.length <= 2) {
      // Only Auto + 1 quality or less
      debugPrint(
          'YPlayerController: Few preferred qualities found, adding more options...');

      for (var stream in _currentManifest!.videoOnly) {
        final height = stream.videoResolution.height;

        if (height > 0 && height <= 1080 && heights.add(height)) {
          final codec = stream.videoCodec.toLowerCase();

          // Be more lenient with codec requirements
          if (codec.contains('avc') ||
              codec.contains('h264') ||
              codec.contains('vp9') ||
              codec.contains('av01')) {
            qualities.add(QualityOption(
              height: height,
              label: "${height}p",
            ));
            debugPrint(
                'YPlayerController: Added additional quality: ${height}p ($codec)');
          }
        }
      }
    }

    // Phase 3: Emergency fallback - if still very few options, add anything reasonable
    if (qualities.length <= 2) {
      debugPrint(
          'YPlayerController: Still few qualities, adding emergency fallbacks...');

      for (var stream in _currentManifest!.videoOnly) {
        final height = stream.videoResolution.height;

        if (height > 0 && height <= 1440 && heights.add(height)) {
          // Allow up to 1440p as emergency
          qualities.add(QualityOption(
            height: height,
            label: "${height}p",
          ));
          debugPrint('YPlayerController: Added emergency quality: ${height}p');
        }
      }
    }

    // Sort by height (highest first, but keep Auto at top)
    if (qualities.length > 1) {
      qualities.sublist(1).sort((a, b) => b.height.compareTo(a.height));
    }

    debugPrint(
        'YPlayerController: Final available qualities: ${qualities.map((q) => q.label).join(", ")}');
    return qualities;
  }

  /// Enhanced quality change with proper error handling  /// Enhanced quality change with better performance and error handling
  Future<void> setQuality(int height) async {
    if (_currentManifest == null || _currentVideoId == null) {
      debugPrint(
          'YPlayerController: Cannot change quality - no manifest available');
      return;
    }

    if (_status == YPlayerStatus.loading || _isInitializing) {
      debugPrint('YPlayerController: Cannot change quality while loading');
      return;
    }

    if (_currentQuality == height) {
      debugPrint('YPlayerController: Quality $height already active');
      return;
    }

    // Validate quality is safe and available before attempting switch
    final availableQualities = getAvailableQualities();
    final isValidQuality =
        height == 0 || availableQualities.any((q) => q.height == height);

    if (!isValidQuality) {
      debugPrint(
          'YPlayerController: Quality $height not available or unsafe, skipping');
      return;
    }

    final currentPosition = _player.state.position;
    final wasPlaying = _player.state.playing;
    final currentVolume = _player.state.volume;

    try {
      _setStatus(YPlayerStatus.loading);
      debugPrint(
          'YPlayerController: Starting quality change to ${height}p'); // Find appropriate stream using the same flexible logic as initialization
      exp.VideoStreamInfo? videoStreamInfo =
          _selectSafeVideoStream(_currentManifest!, height);

      if (videoStreamInfo == null) {
        debugPrint(
            'YPlayerController: No compatible stream found for ${height}p, trying emergency fallback');

        // Emergency fallback - just get any stream for the requested height
        if (height == 0) {
          final allStreams = _currentManifest!.videoOnly.toList();
          if (allStreams.isNotEmpty) {
            allStreams.sort((a, b) =>
                b.videoResolution.height.compareTo(a.videoResolution.height));
            videoStreamInfo = allStreams.first;
          }
        } else {
          final streams = _currentManifest!.videoOnly
              .where((s) => s.videoResolution.height == height);
          if (streams.isNotEmpty) {
            videoStreamInfo = streams.withHighestBitrate();
          } else {
            // If requested height not available, fall back to auto mode
            final allStreams = _currentManifest!.videoOnly.toList();
            if (allStreams.isNotEmpty) {
              allStreams.sort((a, b) =>
                  b.videoResolution.height.compareTo(a.videoResolution.height));
              videoStreamInfo = allStreams.first;
            }
          }
        }

        if (videoStreamInfo == null) {
          debugPrint(
              'YPlayerController: No streams available at all, aborting quality change');
          _setStatus(wasPlaying ? YPlayerStatus.playing : YPlayerStatus.paused);
          return;
        }
      }

      final audioStreamInfo = _currentManifest!.audioOnly.withHighestBitrate();

      // Check if this is actually a different stream
      final currentUrl = _player.state.playlist.medias.isNotEmpty
          ? _player.state.playlist.medias.first.uri.toString()
          : '';

      if (currentUrl == videoStreamInfo.url.toString()) {
        debugPrint('YPlayerController: Same URL, no change needed');
        _currentQuality = height;
        _setStatus(wasPlaying ? YPlayerStatus.playing : YPlayerStatus.paused);
        return;
      }

      debugPrint(
          'YPlayerController: Switching to ${videoStreamInfo.videoResolution.height}p (${videoStreamInfo.videoCodec})');

      // Async operations to minimize main thread blocking
      await _performQualitySwitch(
        videoStreamInfo,
        audioStreamInfo,
        currentPosition,
        wasPlaying,
        currentVolume,
      );

      _currentQuality = videoStreamInfo.videoResolution.height;
      debugPrint('YPlayerController: Quality change completed successfully');
    } catch (e) {
      debugPrint('YPlayerController: Error changing quality: $e');

      // Try to recover to a working state
      await _recoverFromQualityError(
          currentPosition, wasPlaying, currentVolume);
    }
  }

  /// Perform the actual quality switch with optimized timing
  Future<void> _performQualitySwitch(
    exp.VideoStreamInfo videoStreamInfo,
    exp.AudioStreamInfo audioStreamInfo,
    Duration position,
    bool wasPlaying,
    double volume,
  ) async {
    // Step 1: Quick audio fade to reduce jarring
    await _player.setVolume(volume * 0.1);

    // Step 2: Stop current playback
    await _player.stop();

    // Step 3: Minimal delay for cleanup (configurable)
    await Future.delayed(Duration(milliseconds: qualityTransitionDelayMs));

    // Step 4: Open new media
    await _player.open(
      Media(videoStreamInfo.url.toString(), start: position),
      play: false, // Don't auto-play to ensure proper setup
    );

    // Step 5: Set audio track asynchronously
    _setAudioTrackAsync(audioStreamInfo.url.toString());

    // Step 6: Start playback if it was playing
    if (wasPlaying) {
      await _player.play();
    }

    // Step 7: Restore volume smoothly
    await _smoothVolumeRestore(volume);

    _setStatus(wasPlaying ? YPlayerStatus.playing : YPlayerStatus.paused);
  }

  /// Set audio track asynchronously to avoid blocking
  void _setAudioTrackAsync(String audioUrl) {
    Future.delayed(const Duration(milliseconds: 50), () async {
      try {
        await _player.setAudioTrack(AudioTrack.uri(audioUrl));
      } catch (e) {
        debugPrint('YPlayerController: Audio track setting failed: $e');
        // Continue without audio track - video will still work
      }
    });
  }

  /// Recover from quality change errors
  Future<void> _recoverFromQualityError(
      Duration position, bool wasPlaying, double volume) async {
    try {
      debugPrint('YPlayerController: Attempting recovery...');

      // Try to restart with auto quality (safest option)
      final safeStream = _currentManifest!.videoOnly.where((s) {
        final h = s.videoResolution.height;
        return h <= 720 &&
            [240, 360, 480, 720].contains(h); // Very safe qualities
      }).withHighestBitrate();

      await _player.stop();
      await Future.delayed(const Duration(milliseconds: 100));

      await _player.open(
        Media(safeStream.url.toString(), start: position),
        play: wasPlaying,
      );

      await _player.setVolume(volume);
      _currentQuality = safeStream.videoResolution.height;
      _setStatus(wasPlaying ? YPlayerStatus.playing : YPlayerStatus.paused);

      debugPrint(
          'YPlayerController: Recovery successful at ${_currentQuality}p');
    } catch (e) {
      debugPrint('YPlayerController: Recovery failed: $e');
      _setStatus(YPlayerStatus.error);
    }
  }

  /// Smooth volume restoration to avoid audio popping
  Future<void> _smoothVolumeRestore(double targetVolume) async {
    const steps = 5;
    const stepDuration = Duration(milliseconds: 40);

    for (int i = 1; i <= steps; i++) {
      final volume = (targetVolume * i) / steps;
      await _player.setVolume(volume);
      if (i < steps) {
        await Future.delayed(stepDuration);
      }
    }
  }

  /// Enhanced initialization with proper error handling and retry logic
  Future<void> initialize(
    String youtubeUrl, {
    bool autoPlay = true,
    double? aspectRatio,
    bool allowFullScreen = true,
    bool allowMuting = true,
    bool chooseBestQuality = true,
  }) async {
    // Prevent concurrent initialization
    if (_isInitializing) {
      if (_initCompleter != null) {
        return _initCompleter!.future;
      }
      return;
    }

    // Avoid re-initialization if URL hasn't changed
    if (_lastInitializedUrl == youtubeUrl && isInitialized) {
      debugPrint('YPlayerController: Already initialized with this URL');
      return;
    }

    _isInitializing = true;
    _initCompleter = Completer<void>();
    _retryCount = 0;

    try {
      await _performInitialization(youtubeUrl,
          autoPlay: autoPlay, chooseBestQuality: chooseBestQuality);
      _initCompleter!.complete();
    } catch (e) {
      debugPrint('YPlayerController: Initialization failed: $e');
      _setStatus(YPlayerStatus.error);
      _initCompleter!.completeError(e);
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> _performInitialization(
    String youtubeUrl, {
    required bool autoPlay,
    required bool chooseBestQuality,
  }) async {
    _setStatus(YPlayerStatus.loading);

    try {
      debugPrint('YPlayerController: Fetching video info for $youtubeUrl');

      // Get video information with main thread release
      final video = await _yt.videos.get(youtubeUrl);
      await _releaseMainThread(); // Prevent frame drops

      final videoId = video.id.value;

      // Get or cache manifest
      exp.StreamManifest manifest;
      if (_manifestCache.containsKey(videoId)) {
        manifest = _manifestCache[videoId]!;
        _manifestCacheOrder.remove(videoId);
        _manifestCacheOrder.add(videoId);
        debugPrint('YPlayerController: Using cached manifest');
      } else {
        debugPrint('YPlayerController: Fetching new manifest');
        manifest = await _yt.videos.streamsClient.getManifest(video.id);
        await _releaseMainThread(); // Prevent frame drops during manifest processing
        _cacheManifest(videoId, manifest);
      }

      _currentManifest = manifest;
      _currentVideoId = videoId;

      // Choose initial quality with safe defaults
      if (chooseBestQuality) {
        _currentQuality = await _chooseBestQualitySafe(manifest);
      } else {
        _currentQuality = 720; // Safe default
      } // Get streams with multiple fallback levels
      exp.VideoStreamInfo? videoStreamInfo =
          _selectSafeVideoStream(manifest, _currentQuality);

      if (videoStreamInfo == null) {
        debugPrint(
            'YPlayerController: No streams match current quality, trying fallbacks...');

        // Fallback 1: Any stream <= 720p with safe codecs
        final safeStreams = manifest.videoOnly.where((s) {
          final h = s.videoResolution.height;
          final codec = s.videoCodec.toLowerCase();
          return h <= 720 &&
              (codec.contains('avc') ||
                  codec.contains('h264') ||
                  codec.contains('vp9'));
        });

        if (safeStreams.isNotEmpty) {
          videoStreamInfo = safeStreams.withHighestBitrate();
          debugPrint(
              'YPlayerController: Fallback 1 - Using ${videoStreamInfo.videoResolution.height}p');
        } else {
          // Fallback 2: Any stream <= 1080p regardless of codec
          final mediumStreams =
              manifest.videoOnly.where((s) => s.videoResolution.height <= 1080);

          if (mediumStreams.isNotEmpty) {
            videoStreamInfo = mediumStreams.withHighestBitrate();
            debugPrint(
                'YPlayerController: Fallback 2 - Using ${videoStreamInfo.videoResolution.height}p (any codec)');
          } else {
            // Fallback 3: Use the lowest resolution available (most compatible)
            final allStreams = manifest.videoOnly.toList();
            if (allStreams.isNotEmpty) {
              allStreams.sort((a, b) =>
                  a.videoResolution.height.compareTo(b.videoResolution.height));
              videoStreamInfo = allStreams.first;
              debugPrint(
                  'YPlayerController: Fallback 3 - Using lowest available: ${videoStreamInfo.videoResolution.height}p');
            } else {
              throw Exception('No video streams available in manifest');
            }
          }
        }

        _currentQuality = videoStreamInfo.videoResolution.height;
      }

      final audioStreamInfo = manifest.audioOnly.withHighestBitrate();

      debugPrint(
          'YPlayerController: Selected ${videoStreamInfo.videoResolution.height}p (${videoStreamInfo.videoCodec})');
      debugPrint('YPlayerController: Audio: ${audioStreamInfo.bitrate}');

      await _releaseMainThread(); // Release before heavy operations

      // Stop any existing playback
      if (isInitialized) {
        await _player.stop();
        await _releaseMainThread();
      }

      // Configure player with performance settings
      await _player.setVolume(100.0);
      await _player.setShuffle(false);
      await _player.setPlaylistMode(PlaylistMode.none);

      await _releaseMainThread(); // Release after configuration

      // Open media with optimized timing
      await _player.open(Media(videoStreamInfo.url.toString()), play: false);

      // Shorter wait for initial buffering to reduce frame drops
      await Future.delayed(const Duration(milliseconds: 150));
      await _releaseMainThread();

      // Set audio track asynchronously to avoid blocking
      _setAudioTrackAsync(audioStreamInfo.url.toString());

      // Minimal stability delay
      await Future.delayed(const Duration(milliseconds: 100));

      // Start playback if requested
      if (autoPlay) {
        await _player.play();
      }

      _lastInitializedUrl = youtubeUrl;
      _setStatus(autoPlay ? YPlayerStatus.playing : YPlayerStatus.paused);
      debugPrint('YPlayerController: Initialization completed successfully');
    } catch (e) {
      debugPrint('YPlayerController: Initialization error: $e');

      // Retry logic
      if (_retryCount < _maxRetries) {
        _retryCount++;
        debugPrint(
            'YPlayerController: Retrying initialization ($_retryCount/$_maxRetries)');
        await Future.delayed(Duration(seconds: _retryCount));
        return _performInitialization(youtubeUrl,
            autoPlay: autoPlay, chooseBestQuality: chooseBestQuality);
      }

      rethrow;
    }
  }

  /// Select a safe video stream based on quality preference with flexible fallbacks
  exp.VideoStreamInfo? _selectSafeVideoStream(
      exp.StreamManifest manifest, int preferredHeight) {
    // Phase 1: Try with strict safe criteria
    const preferredResolutions = {240, 360, 480, 720, 1080};
    const preferredCodecs = ['avc', 'h264'];

    if (preferredHeight == 0) {
      // Auto mode - select highest safe quality
      var safeStreams = manifest.videoOnly.where((s) {
        final h = s.videoResolution.height;
        final codec = s.videoCodec.toLowerCase();
        return h <= 1080 &&
            preferredResolutions.contains(h) &&
            preferredCodecs.any((safe) => codec.contains(safe));
      });

      if (safeStreams.isNotEmpty) {
        return safeStreams.withHighestBitrate();
      }

      // Fallback: Include VP9 up to 720p
      safeStreams = manifest.videoOnly.where((s) {
        final h = s.videoResolution.height;
        final codec = s.videoCodec.toLowerCase();
        return h <= 720 &&
            preferredResolutions.contains(h) &&
            (preferredCodecs.any((safe) => codec.contains(safe)) ||
                codec.contains('vp9'));
      });

      if (safeStreams.isNotEmpty) {
        return safeStreams.withHighestBitrate();
      }

      // Last resort: Any stream <= 1080p
      safeStreams =
          manifest.videoOnly.where((s) => s.videoResolution.height <= 1080);
      if (safeStreams.isNotEmpty) {
        return safeStreams.withHighestBitrate();
      }
    } else {
      // Specific quality requested - try exact match first
      var streams = manifest.videoOnly.where((s) {
        final h = s.videoResolution.height;
        final codec = s.videoCodec.toLowerCase();
        return h == preferredHeight &&
            preferredCodecs.any((safe) => codec.contains(safe));
      });

      if (streams.isNotEmpty) {
        return streams.withHighestBitrate();
      }

      // Fallback: Try with VP9 if resolution <= 720p
      if (preferredHeight <= 720) {
        streams = manifest.videoOnly.where((s) {
          final h = s.videoResolution.height;
          final codec = s.videoCodec.toLowerCase();
          return h == preferredHeight && codec.contains('vp9');
        });

        if (streams.isNotEmpty) {
          return streams.withHighestBitrate();
        }
      }

      // Last resort: Any stream with the requested height
      streams = manifest.videoOnly
          .where((s) => s.videoResolution.height == preferredHeight);
      if (streams.isNotEmpty) {
        return streams.withHighestBitrate();
      }
    }

    return null;
  }

  /// Choose best safe quality for initialization
  Future<int> _chooseBestQualitySafe(exp.StreamManifest manifest) async {
    const preferredQualities = [720, 480, 360, 240]; // Ordered by preference

    for (final quality in preferredQualities) {
      final stream = _selectSafeVideoStream(manifest, quality);
      if (stream != null) {
        debugPrint('YPlayerController: Selected safe quality: ${quality}p');
        return quality;
      }
    }

    // Fallback to lowest safe quality
    debugPrint('YPlayerController: Fallback to 240p');
    return 240;
  }

  /// Sets up listeners for various player events with improved stability.
  void _setupPlayerListeners() {
    _player.stream.playing.listen((playing) {
      if (!_isInitializing) {
        _setStatus(playing ? YPlayerStatus.playing : YPlayerStatus.paused);
      }
    });

    _player.stream.completed.listen((completed) {
      if (completed) {
        _setStatus(YPlayerStatus.stopped);
      }
    });

    _player.stream.position.listen((position) {
      // Only call progress callback if not in an error state
      if (_status != YPlayerStatus.error && _status != YPlayerStatus.loading) {
        onProgressChanged?.call(position, _player.state.duration);
      }
    });

    _player.stream.error.listen((error) {
      debugPrint('YPlayerController: Player error: $error');
      if (!_isInitializing) {
        _setStatus(YPlayerStatus.error);
      }
    });

    _player.stream.duration.listen((duration) {
      // Validate duration to prevent infinite length issues
      if (duration.inMilliseconds > 0 && duration.inHours < 24) {
        debugPrint('YPlayerController: Valid duration: $duration');
      } else if (duration.inHours >= 24) {
        debugPrint(
            'YPlayerController: Warning: Suspicious duration detected: $duration');
      }
    });
  }

  /// Updates the player status and triggers callbacks.
  void _setStatus(YPlayerStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      statusNotifier.value = newStatus;
      onStateChanged?.call(_status);
    }
  }

  /// Enhanced play method with error handling
  Future<void> play() async {
    try {
      if (!isInitialized) {
        debugPrint('YPlayerController: Cannot play - not initialized');
        return;
      }
      await _player.play();
    } catch (e) {
      debugPrint('YPlayerController: Play error: $e');
      _setStatus(YPlayerStatus.error);
    }
  }

  /// Enhanced speed control with validation
  Future<void> speed(double speed) async {
    try {
      if (!isInitialized) return;

      // Validate speed range
      final clampedSpeed = speed.clamp(0.25, 3.0);
      if (_player.state.rate != clampedSpeed) {
        await _player.setRate(clampedSpeed);
      }
    } catch (e) {
      debugPrint('YPlayerController: Speed change error: $e');
    }
  }

  /// Enhanced pause method
  Future<void> pause() async {
    try {
      if (!isInitialized) return;
      await _player.pause();
    } catch (e) {
      debugPrint('YPlayerController: Pause error: $e');
    }
  }

  /// Enhanced stop method
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('YPlayerController: Stop error: $e');
    }
  }

  /// Enhanced seek method with validation
  Future<void> seek(Duration position) async {
    try {
      if (!isInitialized) return;

      final duration = _player.state.duration;
      if (duration == Duration.zero) return;

      // Validate seek position
      final clampedPosition = Duration(
        microseconds: position.inMicroseconds.clamp(0, duration.inMicroseconds),
      );

      await _player.seek(clampedPosition);
    } catch (e) {
      debugPrint('YPlayerController: Seek error: $e');
    }
  }

  /// Gets the current playback position.
  Duration get position => _player.state.position;

  /// Gets the total duration of the video.
  Duration get duration => _player.state.duration;

  /// Enhanced dispose method with proper cleanup
  void dispose() {
    debugPrint('YPlayerController: Disposing resources');

    try {
      _player.dispose();
      _yt.close();
      statusNotifier.dispose();
    } catch (e) {
      debugPrint('YPlayerController: Dispose error: $e');
    }
  }
}
