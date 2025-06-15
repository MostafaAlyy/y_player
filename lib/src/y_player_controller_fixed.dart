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
    final heights = <int>{};
    for (var stream in _currentManifest!.videoOnly) {
      final height = stream.videoResolution.height;
      if (height > 0 && heights.add(height)) {
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

  /// Enhanced quality change with proper error handling
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

    if (_currentQuality == height) return;

    final currentPosition = _player.state.position;
    final wasPlaying = _player.state.playing;
    final currentVolume = _player.state.volume;

    try {
      _setStatus(YPlayerStatus.loading);
      _currentQuality = height;

      // Find the appropriate stream with better error handling
      exp.VideoStreamInfo videoStreamInfo;
      if (height == 0) {
        // Auto mode - select best compatible quality
        final compatibleStreams = _currentManifest!.videoOnly.where((stream) {
          final streamHeight = stream.videoResolution.height;
          return streamHeight <= 1080 &&
              [240, 360, 480, 720, 1080].contains(streamHeight);
        }).toList();

        if (compatibleStreams.isNotEmpty) {
          videoStreamInfo = compatibleStreams.reduce((a, b) =>
              a.videoResolution.height > b.videoResolution.height ? a : b);
        } else {
          videoStreamInfo = _currentManifest!.videoOnly.withHighestBitrate();
        }
      } else {
        try {
          final targetStreams = _currentManifest!.videoOnly
              .where((s) => s.videoResolution.height == height)
              .toList();

          if (targetStreams.isNotEmpty) {
            videoStreamInfo = targetStreams.withHighestBitrate();
          } else {
            throw Exception('Quality $height not available');
          }
        } catch (e) {
          debugPrint(
              'YPlayerController: Quality $height not available, using safe fallback');
          // Use a safe quality instead
          final safeQuality = height > 720 ? 720 : 480;
          final fallbackStreams = _currentManifest!.videoOnly
              .where((s) => s.videoResolution.height == safeQuality)
              .toList();

          if (fallbackStreams.isNotEmpty) {
            videoStreamInfo = fallbackStreams.withHighestBitrate();
            _currentQuality = safeQuality;
          } else {
            // Last resort
            final allStreams = _currentManifest!.videoOnly.toList()
              ..sort((a, b) =>
                  a.videoResolution.height.compareTo(b.videoResolution.height));
            videoStreamInfo = allStreams.first;
            _currentQuality = allStreams.first.videoResolution.height;
          }
        }
      }

      final audioStreamInfo = _currentManifest!.audioOnly.withHighestBitrate();

      // Check if URL is actually different
      final currentUrl = _player.state.playlist.medias.isNotEmpty
          ? _player.state.playlist.medias.first.uri.toString()
          : '';

      if (currentUrl == videoStreamInfo.url.toString()) {
        _setStatus(wasPlaying ? YPlayerStatus.playing : YPlayerStatus.paused);
        return;
      }

      debugPrint(
          'YPlayerController: Changing quality to ${videoStreamInfo.videoResolution.height}p');

      // Smooth volume transition
      await _player.setVolume(0);

      // Stop and clear current media
      await _player.stop();

      // Brief pause for stability
      await Future.delayed(const Duration(milliseconds: 100));

      // Open new media with start position
      await _player.open(
        Media(videoStreamInfo.url.toString(), start: currentPosition),
        play: false,
      );

      // Wait for media to be ready
      await Future.delayed(const Duration(milliseconds: 200));

      // Set audio track with error handling
      try {
        await _player
            .setAudioTrack(AudioTrack.uri(audioStreamInfo.url.toString()));
      } catch (audioError) {
        debugPrint(
            'YPlayerController: Audio track error during quality change: $audioError');
        // Continue without audio if necessary
      }

      // Restore volume
      await _player.setVolume(currentVolume);

      // Resume playback if it was playing
      if (wasPlaying) {
        await _player.play();
      }

      _setStatus(wasPlaying ? YPlayerStatus.playing : YPlayerStatus.paused);
      debugPrint('YPlayerController: Quality change completed successfully');
    } catch (e) {
      debugPrint('YPlayerController: Error changing quality: $e');
      _setStatus(YPlayerStatus.error);
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

      // Get video information
      final video = await _yt.videos.get(youtubeUrl);
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
        _cacheManifest(videoId, manifest);
      }

      _currentManifest = manifest;
      _currentVideoId = videoId;

      // Choose initial quality with better logic
      if (chooseBestQuality) {
        _currentQuality = await _chooseBestQuality(manifest);
      }

      // Get streams with codec compatibility validation
      exp.VideoStreamInfo videoStreamInfo;
      if (_currentQuality == 0) {
        // Auto mode - select highest compatible quality (max 1080p)
        final compatibleStreams = manifest.videoOnly.where((stream) {
          final height = stream.videoResolution.height;
          return height <= 1080 && [240, 360, 480, 720, 1080].contains(height);
        }).toList();

        if (compatibleStreams.isNotEmpty) {
          videoStreamInfo = compatibleStreams.reduce((a, b) =>
              a.videoResolution.height > b.videoResolution.height ? a : b);
        } else {
          // Fallback to lowest available quality
          final allStreams = manifest.videoOnly.toList()
            ..sort((a, b) =>
                a.videoResolution.height.compareTo(b.videoResolution.height));
          videoStreamInfo = allStreams.first;
        }
      } else {
        try {
          final targetStreams = manifest.videoOnly
              .where((s) => s.videoResolution.height == _currentQuality)
              .toList();

          if (targetStreams.isNotEmpty) {
            videoStreamInfo = targetStreams.withHighestBitrate();
          } else {
            throw Exception('Target quality not available');
          }
        } catch (e) {
          debugPrint(
              'YPlayerController: Target quality not available, using 720p fallback');
          final fallbackStreams = manifest.videoOnly
              .where((s) => s.videoResolution.height <= 720)
              .toList();

          if (fallbackStreams.isNotEmpty) {
            videoStreamInfo = fallbackStreams.reduce((a, b) =>
                a.videoResolution.height > b.videoResolution.height ? a : b);
            _currentQuality = videoStreamInfo.videoResolution.height;
          } else {
            // Last resort - use any available stream
            videoStreamInfo = manifest.videoOnly.withHighestBitrate();
            _currentQuality = 0;
          }
        }
      }

      final audioStreamInfo = manifest.audioOnly.withHighestBitrate();

      debugPrint(
          'YPlayerController: Video: ${videoStreamInfo.videoResolution.height}p');
      debugPrint('YPlayerController: Audio: ${audioStreamInfo.bitrate}');

      // Stop any existing playback
      if (isInitialized) {
        await _player.stop();
      }

      // Configure player for better compatibility
      await _player.setVolume(100.0);
      await _player.setShuffle(false);
      await _player.setPlaylistMode(PlaylistMode.none);

      // Create a playlist with both video and audio for better sync
      final videoMedia = Media(videoStreamInfo.url.toString());

      // Open media with enhanced error handling
      await _player.open(videoMedia, play: false);

      // Wait for the video stream to be ready
      await Future.delayed(const Duration(milliseconds: 500));

      // Only set audio track after video is ready
      try {
        await _player
            .setAudioTrack(AudioTrack.uri(audioStreamInfo.url.toString()));
        debugPrint('YPlayerController: Audio track set successfully');
      } catch (audioError) {
        debugPrint('YPlayerController: Audio track error: $audioError');
        // Continue without audio track - video might still work
      }

      // Additional buffer time for stability
      await Future.delayed(const Duration(milliseconds: 300));

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

  Future<int> _chooseBestQuality(exp.StreamManifest manifest) async {
    try {
      final videoStreams = manifest.videoOnly.toList();
      if (videoStreams.isEmpty) return 0;

      // Filter streams to safe, widely supported qualities
      final safeStreams = videoStreams.where((stream) {
        final height = stream.videoResolution.height;
        // Only use commonly supported resolutions to avoid codec issues
        return height <= 1080 && [240, 360, 480, 720, 1080].contains(height);
      }).toList();

      if (safeStreams.isEmpty) {
        // If no safe streams, try to find the lowest available quality
        final sortedStreams = videoStreams.toList()
          ..sort((a, b) =>
              a.videoResolution.height.compareTo(b.videoResolution.height));
        return sortedStreams.first.videoResolution.height;
      }

      // Choose best quality from safe streams based on network
      safeStreams.sort((a, b) => b.bitrate.compareTo(a.bitrate));

      // For mobile devices, prefer 720p or lower to avoid codec issues
      final preferredStream = safeStreams.firstWhere(
        (stream) => stream.videoResolution.height <= 720,
        orElse: () => safeStreams.last, // Fallback to lowest quality
      );

      return preferredStream.videoResolution.height;
    } catch (e) {
      debugPrint('YPlayerController: Error choosing quality: $e');
      return 480; // Safe fallback quality
    }
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
