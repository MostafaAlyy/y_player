import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:y_player/src/quality_selection_sheet.dart';
import 'package:y_player/src/speed_slider_sheet.dart';
import 'package:y_player/y_player.dart';

/// A customizable YouTube video player widget with enhanced stability.
///
/// This widget provides a reliable way to embed and control YouTube videos
/// in a Flutter application, with proper error handling and performance optimization.
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

/// The state for the YPlayer widget with enhanced stability and error handling.
class YPlayerState extends State<YPlayer> with SingleTickerProviderStateMixin {
  /// The controller for managing the YouTube player.
  late YPlayerController _controller;

  /// The controller for the video display.
  late VideoController _videoController;

  /// Flag to indicate whether the controller is fully initialized and ready.
  bool _isControllerReady = false;

  /// Current playback speed
  double currentSpeed = 1.0;

  /// Loading state tracker
  bool _isLoading = true;

  // Cache built widgets to avoid unnecessary rebuilds
  Widget? _cachedLoadingWidget;
  Widget? _cachedErrorWidget;
  Widget? _cachedPlaceholder;

  @override
  void initState() {
    super.initState();

    // Initialize controller with callbacks
    _controller = YPlayerController(
      onStateChanged: (status) {
        widget.onStateChanged?.call(status);
        _handleStatusChange(status);
      },
      onProgressChanged: widget.onProgressChanged,
    );

    _videoController = VideoController(_controller.player);

    // Cache widgets once
    _cachedLoadingWidget = widget.loadingWidget ??
        const Center(child: CircularProgressIndicator.adaptive());
    _cachedErrorWidget = widget.errorWidget ??
        const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.red),
              SizedBox(height: 8),
              Text('Error loading video', style: TextStyle(color: Colors.red)),
            ],
          ),
        );
    _cachedPlaceholder = widget.placeholder ?? const SizedBox.shrink();

    // Initialize player with delay to ensure widget is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializePlayer();
    });
  }

  void _handleStatusChange(YPlayerStatus status) {
    if (!mounted) return;

    setState(() {
      _isLoading = status == YPlayerStatus.loading;

      // Update controller ready state based on status
      if (status == YPlayerStatus.error) {
        _isControllerReady = false;
      } else if (status == YPlayerStatus.playing ||
          status == YPlayerStatus.paused) {
        _isControllerReady = true;
      }
    });
  }

  /// Initializes the video player with enhanced error handling.
  void _initializePlayer() async {
    if (!mounted) return;

    try {
      setState(() {
        _isLoading = true;
        _isControllerReady = false;
      });

      // Initialize with timeout
      await _controller
          .initialize(
        widget.youtubeUrl,
        autoPlay: widget.autoPlay,
        aspectRatio: widget.aspectRatio,
        chooseBestQuality: widget.chooseBestQuality,
      )
          .timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException(
              'Video initialization timed out', const Duration(seconds: 30));
        },
      );

      if (mounted) {
        // Verify initialization was successful
        if (_controller.isInitialized &&
            _controller.status != YPlayerStatus.error) {
          setState(() {
            _isControllerReady = true;
            _isLoading = false;
          });

          // Notify controller is ready
          widget.onControllerReady?.call(_controller);
        } else {
          setState(() {
            _isControllerReady = false;
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('YPlayer: Initialization error: $e');
      if (mounted) {
        setState(() {
          _isControllerReady = false;
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final aspectRatio = widget.aspectRatio ?? 16 / 9;
        final playerWidth = constraints.maxWidth;
        final playerHeight = playerWidth / aspectRatio;

        return ValueListenableBuilder<YPlayerStatus>(
          valueListenable: _controller.statusNotifier,
          builder: (context, status, _) {
            return Container(
              width: playerWidth,
              height: playerHeight,
              color: Colors.black,
              child: _buildPlayerContent(playerWidth, playerHeight, status),
            );
          },
        );
      },
    );
  }

  /// Builds the main content of the player based on its current state.
  Widget _buildPlayerContent(
      double width, double height, YPlayerStatus status) {
    // Show loading state
    if (_isLoading || status == YPlayerStatus.loading) {
      return _cachedLoadingWidget!;
    }

    // Show error state
    if (status == YPlayerStatus.error || !_controller.isInitialized) {
      return _cachedErrorWidget!;
    }

    // Show video player if ready
    if (_isControllerReady && _controller.isInitialized) {
      return MaterialVideoControlsTheme(
        normal: _buildControlsTheme(false),
        fullscreen: _buildControlsTheme(true),
        child: Video(
          controller: _videoController,
          controls: MaterialVideoControls,
          width: width,
          height: height,
          filterQuality: FilterQuality.medium, // Balanced quality/performance
          fit: BoxFit.contain,
          onEnterFullscreen: () async {
            if (widget.onEnterFullScreen != null) {
              return widget.onEnterFullScreen!();
            } else {
              return yPlayerDefaultEnterFullscreen();
            }
          },
          onExitFullscreen: () async {
            if (widget.onExitFullScreen != null) {
              return widget.onExitFullScreen!();
            } else {
              return yPlayerDefaultExitFullscreen();
            }
          },
        ),
      );
    }

    // Show placeholder for initial state
    return _cachedPlaceholder!;
  }

  MaterialVideoControlsThemeData _buildControlsTheme(bool isFullscreen) {
    return MaterialVideoControlsThemeData(
      seekBarBufferColor: Colors.grey,
      seekOnDoubleTap: true,
      seekBarPositionColor: widget.color ?? const Color(0xFFFF0000),
      seekBarThumbColor: widget.color ?? const Color(0xFFFF0000),
      seekBarMargin: isFullscreen
          ? (widget.fullscreenSeekBarMargin ?? EdgeInsets.zero)
          : (widget.seekBarMargin ?? EdgeInsets.zero),
      bottomButtonBarMargin: isFullscreen
          ? (widget.fullscreenBottomButtonBarMargin ??
              const EdgeInsets.only(left: 16, right: 8))
          : (widget.bottomButtonBarMargin ??
              const EdgeInsets.only(left: 16, right: 8)),
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
        const MaterialFullscreenButton(),
      ],
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
          if (currentSpeed != newSpeed && mounted) {
            setState(() {
              currentSpeed = newSpeed;
            });
            _controller.speed(newSpeed);
          }
        },
      ),
    );
  }

  void _showQualitySelector(BuildContext context) {
    final qualityOptions = _controller.getAvailableQualities();

    if (qualityOptions.isEmpty) {
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
}
