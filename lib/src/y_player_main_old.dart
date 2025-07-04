import 'dart:async'; // Added for microtask

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:y_player/src/quality_selection_sheet.dart';
import 'package:y_player/src/speed_slider_sheet.dart';
import 'package:y_player/y_player.dart';

/// A customizable YouTube video player widget.
///
/// This widget provides a flexible way to embed and control YouTube videos
/// in a Flutter application, with options for customization and event handling.
class YPlayer extends StatefulWidget {
  /// The URL of the YouTube video to play.
  final String youtubeUrl;

  /// The aspect ratio of the video player. If null, defaults to 16:9.
  final double? aspectRatio;

  /// Whether the video should start playing automatically when loaded.
  final bool autoPlay;

  /// The primary color for the player's UI elements.
  final Color? color;

  /// A widget to display while the video is not yet loaded.
  final Widget? placeholder;

  /// A widget to display while the video is loading.
  final Widget? loadingWidget;

  /// A widget to display if there's an error loading the video.
  final Widget? errorWidget;

  /// A callback that is triggered when the player's state changes.
  final YPlayerStateCallback? onStateChanged;

  /// A callback that is triggered when the video's playback progress changes.
  final YPlayerProgressCallback? onProgressChanged;

  /// A callback that is triggered when the player controller is ready.
  final Function(YPlayerController controller)? onControllerReady;

  /// A callback that is triggered when the player enters full screen mode.
  final Function()? onEnterFullScreen;

  /// A callback that is triggered when the player exits full screen mode.
  final Function()? onExitFullScreen;

  /// The margin around the seek bar.
  final EdgeInsets? seekBarMargin;

  /// The margin around the seek bar in fullscreen mode.
  final EdgeInsets? fullscreenSeekBarMargin;

  /// The margin around the bottom button bar.
  final EdgeInsets? bottomButtonBarMargin;

  /// The margin around the bottom button bar in fullscreen mode.
  final EdgeInsets? fullscreenBottomButtonBarMargin;

  /// Whether to choose the best quality automatically.
  final bool chooseBestQuality;

  /// Constructs a YPlayer widget.
  ///
  /// The [youtubeUrl] parameter is required and should be a valid YouTube video URL.
  const YPlayer({
    super.key,
    required this.youtubeUrl,
    this.aspectRatio,
    this.autoPlay = true,
    this.placeholder,
    this.loadingWidget,
    this.errorWidget,
    this.onStateChanged,
    this.onProgressChanged,
    this.onControllerReady,
    this.color,
    this.onEnterFullScreen,
    this.onExitFullScreen,
    this.seekBarMargin,
    this.fullscreenSeekBarMargin,
    this.bottomButtonBarMargin,
    this.fullscreenBottomButtonBarMargin,
    this.chooseBestQuality = true,
  });

  @override
  YPlayerState createState() => YPlayerState();
}

/// The state for the YPlayer widget.
///
/// This class manages the lifecycle of the video player and handles
/// initialization, playback control, UI updates, and performance monitoring.
class YPlayerState extends State<YPlayer> 
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// The controller for managing the YouTube player.
  late YPlayerController _controller;

  /// The controller for the video display.
  late VideoController _videoController;

  /// Flag to indicate whether the controller is fully initialized and ready.
  bool _isControllerReady = false;
  late ValueChanged<double> onSpeedChanged;
  double currentSpeed = 1.0;

  // Cache built widgets to avoid unnecessary rebuilds
  Widget? _cachedLoadingWidget;
  Widget? _cachedErrorWidget;
  Widget? _cachedPlaceholder;
  // Performance monitoring
  final YPlayerPerformanceMonitor _performanceMonitor = YPlayerPerformanceMonitor();
  DateTime _lastFrameTime = DateTime.now();

  // Debouncing for performance
  Timer? _rebuildTimer;
  bool _needsRebuild = false;
  @override
  void initState() {
    super.initState();
    
    // Add lifecycle observer for background/foreground detection
    WidgetsBinding.instance.addObserver(this);
    
    // Initialize controller with enhanced features
    _controller = YPlayerController(
      onStateChanged: widget.onStateChanged,
      onProgressChanged: widget.onProgressChanged,
    );
    _videoController = VideoController(_controller.player);

    // Start performance monitoring
    _performanceMonitor.startMonitoring();

    // Use microtask to avoid blocking UI thread
    Future.microtask(_initializePlayer);

    // Cache widgets for better performance
    _cachedLoadingWidget =
        widget.loadingWidget ?? const CircularProgressIndicator.adaptive();
    _cachedErrorWidget =
        widget.errorWidget ?? const Text('Error loading video');
    _cachedPlaceholder = widget.placeholder ?? const SizedBox.shrink();
  }
  /// Initializes the video player with the provided YouTube URL and settings.
  void _initializePlayer() async {
    try {
      _setIsLoading(true);
      
      // Attempt to initialize the player with the given YouTube URL and settings
      await _controller.initialize(
        widget.youtubeUrl,
        autoPlay: widget.autoPlay,
        aspectRatio: widget.aspectRatio,
        chooseBestQuality: widget.chooseBestQuality,
      );
      
      if (mounted) {
        // Wait a bit to ensure everything is properly loaded
        await Future.delayed(const Duration(milliseconds: 100));
        
        // Check if initialization was actually successful
        if (_controller.isInitialized && _controller.status != YPlayerStatus.error) {
          setState(() {
            _isControllerReady = true;
          });
          
          // Notify that the controller is ready
          if (widget.onControllerReady != null) {
            widget.onControllerReady!(_controller);
          }
        } else {
          // Initialization failed
          setState(() {
            _isControllerReady = false;
          });
        }
      }
    } catch (e) {
      // Log any errors that occur during initialization
      debugPrint('YPlayer: Error initializing player: $e');
      if (mounted) {
        setState(() {
          _isControllerReady = false;
        });
      }
    } finally {
      if (mounted) {
        _setIsLoading(false);
      }
    }
  }

  void _setIsLoading(bool loading) {
    if (mounted) {
      setState(() {
        // Update loading state
      });
    }
  }
  @override
  void dispose() {
    // Cancel any pending rebuilds
    _rebuildTimer?.cancel();
    
    // Remove lifecycle observer
    WidgetsBinding.instance.removeObserver(this);
    
    // Stop performance monitoring
    _performanceMonitor.stopMonitoring();
    _performanceMonitor.dispose();
    
    // Ensure the controller is properly disposed when the widget is removed
    _controller.dispose();
    super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // Pause video when app goes to background to save resources
        if (_controller.status == YPlayerStatus.playing) {
          _controller.pause();
        }
        break;
      case AppLifecycleState.resumed:
        // Resume if video was playing before backgrounding
        break;
      case AppLifecycleState.inactive:
        // Handle brief interruptions
        break;
    }
  }

  /// Debounced rebuild to prevent excessive UI updates
  void _requestRebuild() {
    if (_rebuildTimer?.isActive == true) return;
    
    _needsRebuild = true;
    _rebuildTimer = Timer(const Duration(milliseconds: 16), () {
      if (_needsRebuild && mounted) {
        setState(() {
          _needsRebuild = false;
        });
      }
    });
  }

  /// Track frame performance
  void _recordFrameTime() {
    final now = DateTime.now();
    final frameDuration = now.difference(_lastFrameTime);
    _lastFrameTime = now;
    
    // Record frame for performance monitoring
    _performanceMonitor.recordFrame();
    
    // If frame took too long, optimize next frame
    if (frameDuration.inMilliseconds > 33) { // > 30fps
      _requestRebuild();
    }
  }
  @override
  Widget build(BuildContext context) {
    // Record frame performance
    _recordFrameTime();
    
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Calculate the player dimensions based on the available width and aspect ratio
          final aspectRatio = widget.aspectRatio ?? 16 / 9;
          final playerWidth = constraints.maxWidth;
          final playerHeight = playerWidth / aspectRatio;

          // Use ValueListenableBuilder to only rebuild when controller status changes
          return ValueListenableBuilder<YPlayerStatus>(
            valueListenable: _controller.statusNotifier,
            builder: (context, status, _) {
              return Container(
                width: playerWidth,
                height: playerHeight,
                color: Colors.transparent,
                child: _buildPlayerContent(playerWidth, playerHeight, status),
              );
            },
          );
        },
      ),
    );
  }

  void _showSpeedSlider(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints: const BoxConstraints(maxHeight: 250, maxWidth: 500),
      builder: (context) => SpeedSliderSheet(
        primaryColor: widget.color ?? const Color(0xFFFF0000),
        initialSpeed: currentSpeed,
        onSpeedChanged: (newSpeed) {
          if (currentSpeed != newSpeed) {
            setState(() {
              currentSpeed = newSpeed;
              _controller.speed(newSpeed);
            });
          }
        },
      ),
    );
  }

  Widget buildSpeedOption() {
    return const IconButton(
      icon: Icon(Icons.speed, color: Colors.white),
      onPressed: null, // Will be replaced below
    );
  }

  void _showQualitySelector(BuildContext context) {
    final qualityOptions = _controller.getAvailableQualities();

    if (qualityOptions.isEmpty) {
      // No quality options available
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No quality options available')),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints: const BoxConstraints(maxWidth: 500),
      builder: (context) => QualitySelectionSheet(
        selectedQuality: _controller.currentQuality,
        primaryColor: widget.color ?? const Color(0xFFFF0000),
        qualityOptions: qualityOptions,
        onQualitySelected: (quality) {
          _controller.setQuality(quality);
        },
      ),
    );
  }

  Widget buildQualityOption() {
    return const IconButton(
      icon: Icon(Icons.hd_outlined, color: Colors.white),
      onPressed: null, // Will be replaced below
    );
  }

  /// Builds the main content of the player based on its current state.
  Widget _buildPlayerContent(
      double width, double height, YPlayerStatus status) {
    if (_isControllerReady && _controller.isInitialized) {
      // Always set speed since controller does not expose currentSpeed
      _controller.speed(currentSpeed);
      // If the controller is ready and initialized, show the video player
      return MaterialVideoControlsTheme(
        normal: MaterialVideoControlsThemeData(
          seekBarBufferColor: Colors.grey,
          seekOnDoubleTap: true,
          seekBarPositionColor: widget.color ?? const Color(0xFFFF0000),
          seekBarThumbColor: widget.color ?? const Color(0xFFFF0000),
          seekBarMargin: widget.seekBarMargin ?? EdgeInsets.zero,
          bottomButtonBarMargin: widget.bottomButtonBarMargin ??
              const EdgeInsets.only(left: 16, right: 8),
          brightnessGesture: true,
          volumeGesture: true,
          bottomButtonBar: [
            const MaterialPositionIndicator(),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.hd_outlined, color: Colors.white),
              onPressed: () => _showQualitySelector(context),
            ),
            IconButton(
              icon: const Icon(Icons.speed, color: Colors.white),
              onPressed: () => _showSpeedSlider(context),
            ),
            const MaterialFullscreenButton()
          ],
        ),
        fullscreen: MaterialVideoControlsThemeData(
          volumeGesture: true,
          brightnessGesture: true,
          seekOnDoubleTap: true,
          seekBarMargin: widget.fullscreenSeekBarMargin ?? EdgeInsets.zero,
          bottomButtonBarMargin: widget.fullscreenBottomButtonBarMargin ??
              const EdgeInsets.only(left: 16, right: 8),
          seekBarBufferColor: Colors.grey,
          seekBarPositionColor: widget.color ?? const Color(0xFFFF0000),
          seekBarThumbColor: widget.color ?? const Color(0xFFFF0000),
          bottomButtonBar: [
            const MaterialPositionIndicator(),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.hd_outlined, color: Colors.white),
              onPressed: () => _showQualitySelector(context),
            ),
            IconButton(
              icon: const Icon(Icons.speed, color: Colors.white),
              onPressed: () => _showSpeedSlider(context),
            ),
            const MaterialFullscreenButton()
          ],
        ),        child: RepaintBoundary(
          child: Video(
            controller: _videoController,
            controls: MaterialVideoControls,
            width: width,
            height: height,
            filterQuality: FilterQuality.high,
            // Enhanced performance settings
            fit: BoxFit.contain,
            fill: Colors.black,
            onEnterFullscreen: () async {
              // Stop performance monitoring during fullscreen transition
              _performanceMonitor.stopMonitoring();
              
              if (widget.onEnterFullScreen != null) {
                return widget.onEnterFullScreen!();
              } else {
                return yPlayerDefaultEnterFullscreen();
              }
            },
            onExitFullscreen: () async {
              // Resume performance monitoring after fullscreen exit
              _performanceMonitor.startMonitoring();
              
              if (widget.onExitFullScreen != null) {
                return widget.onExitFullScreen!();
              } else {
                return yPlayerDefaultExitFullscreen();
              }
            },
          ),
        ),
      );
    } else if (status == YPlayerStatus.loading) {
      // If the video is still loading, show a loading indicator
      return Center(child: _cachedLoadingWidget);
    } else if (status == YPlayerStatus.error) {
      // If there was an error, show the error widget
      return Center(child: _cachedErrorWidget);
    } else {
      // For any other state, show the placeholder or an empty container
      return _cachedPlaceholder!;
    }
  }
}
