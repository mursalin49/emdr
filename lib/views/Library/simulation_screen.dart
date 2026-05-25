import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:jonssony/models/app_theme.dart';
import 'package:jonssony/painters/object_painter.dart';
import 'package:jonssony/services/voice_service.dart';
import 'package:jonssony/data/bls_built_in_sounds.dart';
import 'package:jonssony/data/bls_local_visuals.dart';
import 'package:jonssony/data/bls_tone_profiles.dart';
import 'package:jonssony/utils/transparent_media.dart';
import 'package:jonssony/widgets/asset_animated_visual.dart';
import 'package:jonssony/widgets/canvas_sprite_visual.dart';
import 'package:jonssony/widgets/transparent_session_visual.dart';
import 'bls_pdf_visuals.dart';
import 'clam_space_ex.dart';
import 'simulation_settings.dart';

class SimulationScreen extends StatefulWidget {
  final SimulationSettings settings;
  const SimulationScreen({super.key, required this.settings});

  @override
  State<SimulationScreen> createState() => _SimulationScreenState();
}

class _SimulationScreenState extends State<SimulationScreen>
    with TickerProviderStateMixin {
  static const Color _inkText = Color(0xFF151515);
  late AnimationController _controller;
  late Animation<double> _animation;
  late AnimationController _wingController;
  late Animation<double> _wingAnimation;
  late AnimationController _effectController;
  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioPlayer _leftPulsePlayer = AudioPlayer();
  final AudioPlayer _rightPulsePlayer = AudioPlayer();
  final VoiceService _voice = VoiceService();
  final Map<String, Uint8List> _toneCache = {};
  final ValueNotifier<bool> _videoPlayingNotifier = ValueNotifier(false);
  Widget? _stableVideoVisual;
  Widget? _sessionMovingVisual;

  Timer? _setTimer;
  Timer? _sessionTimer;
  late Duration _setDuration;
  late Duration _remainingSetTime;
  late int _selectedDurationMinutes;
  Duration _processingElapsed = Duration.zero;
  int _moveCount = 0;
  bool _visitedRightThisSet = false;
  bool _isPaused = false; // Track pause state
  bool _isReversing = false; // Track animation direction
  late AnimationController _turnController;
  Animation<double>? _activeTurn;
  double _displayFacingAngle = 0;
  bool _motionStarted = false;
  bool _setComplete = false;
  bool _showIntroGuidance = false;
  bool _showClosingGuidance = false;
  bool _showCompletionQuestions = false;
  bool _hasAudioSource = false;
  bool? _firstCompletionAnswer;
  bool _showSudsRating = false;
  int _sudsRating = 5;

  static const Map<String, BlsToneProfile> _htmlToneProfiles = kBlsToneProfiles;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
    ]);
    _setDuration = _resolveSetDuration();
    _remainingSetTime = _setDuration;
    _selectedDurationMinutes = widget.settings.maxDurationMinutes == 90
        ? 90
        : 60;
    _showIntroGuidance = widget.settings.showCompletionQuestions;
    _controller = AnimationController(
      duration: Duration(milliseconds: (widget.settings.speed * 1000).toInt()),
      vsync: this,
    );

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _handleEndpointReached(isRight: true);
        if (_setComplete) return;
        _isReversing = true;
        _beginFacingTurn(faceLeft: true);
        _controller.reverse();
      } else if (status == AnimationStatus.dismissed) {
        _handleEndpointReached(isRight: false);
        if (_setComplete) return;
        _isReversing = false;
        _beginFacingTurn(faceLeft: false);
        _controller.forward();
      }
    });

    _animation = Tween<double>(
      begin: -1.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    _turnController = AnimationController(
      duration: const Duration(milliseconds: 420),
      vsync: this,
    )..addListener(_onTurnTick);

    _wingController = AnimationController(
      duration: const Duration(milliseconds: 360),
      vsync: this,
    );
    _wingAnimation = CurvedAnimation(
      parent: _wingController,
      curve: Curves.easeInOut,
    );
    _effectController = AnimationController(
      duration: const Duration(hours: 1),
      vsync: this,
    );
    if (_needsEffectAnimation) {
      _effectController.repeat();
    }
    if (_usesAssetAnimatedVisual || _usesVideoVisual) {
      _videoPlayingNotifier.value = true;
      if (_usesAssetAnimatedVisual) {
        final visualSource = resolveLocalVisualAsset(_resolvedVisualObject);
        final visual = resolveLocalVisual(visualSource);
        if (visual?.usesSpriteFrames == true) {
          _stableVideoVisual = CanvasSpriteVisual(
            key: ValueKey(visual!.id),
            frameAssets: visual.spriteFrameAssets,
            size: _objectSize,
            playing: true,
            fps: visual.fps,
          );
        } else {
          _stableVideoVisual = AssetAnimatedVisualLayer(
            assetPath: visualSource,
            size: _objectSize,
            playingListenable: _videoPlayingNotifier,
            stripWhiteBackground: !shouldUseSpriteVisual(visualSource),
          );
        }
      } else {
        _stableVideoVisual = TransparentSessionVisualLayer(
          candidates: _sessionVisualCandidates,
          size: _objectSize,
          playingListenable: _videoPlayingNotifier,
          fallback: _buildVideoFallback(_objectSize),
        );
      }
    }
    _sessionMovingVisual = RepaintBoundary(
      child: TickerMode(
        enabled: true,
        child: _stableVideoVisual ?? _buildVisualObject(size: _objectSize),
      ),
    );
    unawaited(_configurePulsePlayers());
    _precacheEndpointSounds();
    _startSessionTimer();

    if (widget.settings.showCompletionQuestions) {
      final roadmap = widget.settings.roadmapSummary?.trim();
      final intro = [
        'The bilateral stimulation will start now.',
        if (roadmap != null && roadmap.isNotEmpty)
          'Your roadmap summary is: $roadmap.',
        'When you have the image and feeling in mind, press start.',
        'When you start, let your mind wander. Your thoughts may go forward or backwards in time. Simply notice what comes up.',
      ].join(' ');
      unawaited(_voice.speak(intro));
    } else {
      _startMotion();
    }
  }

  Future<void> _configurePulsePlayers() async {
    await _leftPulsePlayer.setPlayerMode(PlayerMode.lowLatency);
    await _rightPulsePlayer.setPlayerMode(PlayerMode.lowLatency);
    await _leftPulsePlayer.setVolume(1);
    await _rightPulsePlayer.setVolume(1);
    await _leftPulsePlayer.setBalance(-1);
    await _rightPulsePlayer.setBalance(1);
  }

  void _precacheEndpointSounds() {
    final profile = _resolvedToneProfile;
    if (profile == null) return;
    _toneBytes(profile: profile, isRight: false);
    _toneBytes(profile: profile, isRight: true);
  }

  String get _resolvedSoundKey {
    final rawKey = widget.settings.soundKey.trim();
    if (rawKey.isEmpty || rawKey == 'none') return rawKey;

    final normalized = BlsBuiltInSounds.normalizeKey(rawKey);
    if (_htmlToneProfiles.containsKey(normalized)) return normalized;
    if (_htmlToneProfiles.containsKey(rawKey)) return rawKey;
    if (BlsBuiltInSounds.isBuiltInKey(rawKey)) return normalized;

    return normalized;
  }

  String get _resolvedAudioAsset {
    final asset = widget.settings.audioAsset.trim();
    if (asset.isNotEmpty) return asset;

    final rawKey = widget.settings.soundKey.trim();
    if (_isNetworkUrl(rawKey)) return rawKey;
    return asset;
  }

  BlsToneProfile? get _resolvedToneProfile =>
      resolveBlsToneProfile(_resolvedSoundKey);

  List<SessionVisualCandidate> get _sessionVisualCandidates {
    final configured = widget.settings.visualPlaybackUrl?.trim();
    final source = configured?.isNotEmpty == true
        ? configured!
        : widget.settings.visualObject.trim();
    return buildSessionVisualCandidates(
      source: source,
      transparentUrl: widget.settings.visualTransparentUrl,
      label: widget.settings.visualLabel,
      mediaType: widget.settings.visualMediaType,
    );
  }

  String get _videoPlaybackUrl {
    final candidates = _sessionVisualCandidates;
    if (candidates.isNotEmpty) return candidates.first.url;
    final configured = widget.settings.visualPlaybackUrl?.trim();
    final source = configured?.isNotEmpty == true
        ? configured!
        : widget.settings.visualObject.trim();
    return resolveSimulationVisualUrl(
      source,
      label: widget.settings.visualLabel,
      mediaType: widget.settings.visualMediaType,
    );
  }

  bool get _usesAssetAnimatedVisual {
    final source = _resolvedVisualObject;
    if (isBlsLocalVisualAsset(source) || resolveLocalVisual(source) != null) {
      return true;
    }
    return source.startsWith('assets/') && isAnimatedAssetVisual(source);
  }

  bool get _usesVideoVisual {
    if (_usesAssetAnimatedVisual) return false;
    if (widget.settings.visualMediaType.toLowerCase() == 'video') {
      return _sessionVisualCandidates.isNotEmpty;
    }
    return _isVideoVisual(_videoPlaybackUrl);
  }

  bool get _needsEffectAnimation =>
      bilateralObjectFromSource(_resolvedVisualObject) != null;

  void _startMotion() {
    if (!mounted || _setComplete || _isPaused) return;
    _motionStarted = true;
    _controller.forward();
    if (_needsEffectAnimation && !_effectController.isAnimating) {
      _effectController.repeat();
    }
    _videoPlayingNotifier.value = true;
    if (_shouldFlapWings) {
      _wingController.repeat(reverse: true);
    }
    if (_usesContinuousSessionAudio) {
      unawaited(_setupAudio());
    } else if (_usesEndpointAudio) {
      unawaited(_playEndpointAudio(isRight: false));
    }
    _startSetTimer();
  }

  Future<void> _handleIntroStart() async {
    await _voice.stop();
    if (!mounted) return;

    setState(() {
      _showIntroGuidance = false;
      _setComplete = false;
      _isPaused = false;
      _motionStarted = false;
      _moveCount = 0;
      _visitedRightThisSet = false;
      _remainingSetTime = _setDuration;
      _isReversing = false;
      _displayFacingAngle = 0;
    });

    _turnController.stop();
    _turnController.reset();
    _controller.reset();
    _effectController
      ..reset()
      ..repeat();
    _startMotion();
  }

  bool get _usesContinuousSessionAudio {
    if (_resolvedSoundKey == 'none') return false;
    return _resolvedAudioAsset.isNotEmpty;
  }

  bool get _usesEndpointAudio {
    if (_resolvedSoundKey == 'none') return false;
    return _resolvedToneProfile != null;
  }

  Duration get _sessionLimit => _selectedDurationMinutes > 0
      ? Duration(minutes: _selectedDurationMinutes)
      : Duration.zero;

  Duration get _sessionRemaining {
    final limit = _sessionLimit;
    if (limit == Duration.zero) return Duration.zero;
    final remaining = limit - _processingElapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Duration _resolveSetDuration() {
    if (widget.settings.totalSets > 0) {
      final totalSets = widget.settings.totalSets;
      // Each set = full left→right→left cycle (two half-beats).
      final milliseconds =
          (widget.settings.speed * 1000 * 2 * totalSets).round();
      return Duration(milliseconds: milliseconds < 1000 ? 1000 : milliseconds);
    }

    return const Duration(seconds: 45);
  }

  void _startSessionTimer() {
    _sessionTimer?.cancel();
    if (_sessionLimit == Duration.zero) return;

    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _setComplete || _showClosingGuidance) return;
      if (!_motionStarted || _isPaused) return;

      setState(() {
        _processingElapsed += const Duration(seconds: 1);
      });

      if (_processingElapsed >= _sessionLimit) {
        unawaited(_completeByTimeLimit());
      }
    });
  }

  Future<void> _completeByTimeLimit() async {
    if (!mounted || _showClosingGuidance) return;
    _setTimer?.cancel();
    _motionStarted = false;
    _setComplete = true;
    _controller.stop();
    _wingController.stop();
    _effectController.stop();
    _videoPlayingNotifier.value = false;
    await _audioPlayer.pause();
    await _leftPulsePlayer.stop();
    await _rightPulsePlayer.stop();
    await _voice.stop();
    if (!mounted) return;
    setState(() {
      _isPaused = true;
      _showCompletionQuestions = false;
      _showClosingGuidance = true;
      _remainingSetTime = Duration.zero;
    });
    unawaited(
      _voice.speak(
        'You have reached the session time you chose. Return to your calm place now. Bring up your pincode and spend a minute finding that calm feeling in your body.',
      ),
    );
  }

  void _startSetTimer() {
    _setTimer?.cancel();
    if (_setComplete || _isPaused) return;

    if (widget.settings.totalSets > 0) {
      return;
    }

    _setTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_remainingSetTime.inSeconds <= 1) {
        unawaited(_completeSet());
        return;
      }
      setState(() {
        _remainingSetTime -= const Duration(seconds: 1);
      });
    });
  }

  void _handleEndpointReached({required bool isRight}) {
    if (!mounted || !_motionStarted || _setComplete || _isPaused) return;

    if (_usesEndpointAudio) {
      unawaited(_playEndpointAudio(isRight: isRight));
    }

    if (widget.settings.totalSets <= 0) return;

    if (isRight) {
      _visitedRightThisSet = true;
      return;
    }

    if (!_visitedRightThisSet) return;
    _visitedRightThisSet = false;
    _registerCompletedSet();
  }

  void _registerCompletedSet() {
    final totalSets = widget.settings.totalSets;
    if (!mounted || _setComplete || _isPaused) return;
    if (_moveCount >= totalSets) {
      unawaited(_completeSet());
      return;
    }

    setState(() {
      _moveCount++;
      if (widget.settings.totalSets > 0) {
        final stepMs =
            (widget.settings.speed * 1000 * 2).round().clamp(1, 20000);
        final remainingMs = _setDuration.inMilliseconds - (stepMs * _moveCount);
        _remainingSetTime = Duration(
          milliseconds: remainingMs < 0 ? 0 : remainingMs,
        );
      }
    });

    if (_moveCount >= totalSets) {
      unawaited(_completeSet());
    }
  }

  Future<void> _completeSet() async {
    if (!mounted || _setComplete) return;
    _setTimer?.cancel();
    _motionStarted = false;
    _controller.stop();
    _wingController.stop();
    _effectController.stop();
    _videoPlayingNotifier.value = false;
    await _audioPlayer.pause();
    await _leftPulsePlayer.stop();
    await _rightPulsePlayer.stop();
    if (!mounted) return;
    if (widget.settings.showCompletionQuestions) {
      setState(() {
        _showCompletionQuestions = true;
        _isPaused = true;
        _remainingSetTime = Duration.zero;
      });
      unawaited(
        _voice.speak(
          'Take a gentle breath. Notice what you experienced. Is it changing and still connected to your original image?',
        ),
      );
      return;
    }

    setState(() {
      _setComplete = true;
      _isPaused = true;
      _remainingSetTime = Duration.zero;
    });
  }

  Future<void> _setupAudio() async {
    try {
      final source = _resolvedAudioAsset;
      if (source.isEmpty) return;

      if (_isNetworkUrl(source)) {
        await _audioPlayer.setSource(UrlSource(source));
      } else if (widget.settings.requireNetworkAudio) {
        debugPrint('Skipping non-API bilateral audio source.');
        return;
      } else {
        var assetPath = source;
        if (assetPath.startsWith('assets/')) {
          assetPath = assetPath.substring(7);
        }
        await _audioPlayer.setSource(AssetSource(assetPath));
      }
      _hasAudioSource = true;
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);

      _controller.addListener(() {
        if (mounted && !_isPaused) _audioPlayer.setBalance(_animation.value);
      });
      await _audioPlayer.resume();
    } catch (e) {
      debugPrint("Audio Error: $e");
    }
  }

  Future<void> _playEndpointAudio({required bool isRight}) async {
    final profile = _resolvedToneProfile;
    if (profile != null) {
      final bytes = _toneBytes(profile: profile, isRight: isRight);
      final player = isRight ? _rightPulsePlayer : _leftPulsePlayer;

      try {
        await player.stop();
        await player.setVolume(1);
        await player.play(BytesSource(bytes, mimeType: 'audio/wav'));
      } catch (e) {
        debugPrint('Tone Error: $e');
      }
      return;
    }

    await _playFilePulse(isRight: isRight);
  }

  Future<void> _playFilePulse({required bool isRight}) async {
    final source = _resolvedAudioAsset;
    if (source.isEmpty) return;

    final player = isRight ? _rightPulsePlayer : _leftPulsePlayer;
    try {
      await player.stop();
      await player.setVolume(1);
      await player.setBalance(isRight ? 1 : -1);
      if (_isNetworkUrl(source)) {
        await player.play(UrlSource(source));
      } else if (!widget.settings.requireNetworkAudio) {
        var assetPath = source;
        if (assetPath.startsWith('assets/')) {
          assetPath = assetPath.substring(7);
        }
        await player.play(AssetSource(assetPath));
      }
    } catch (e) {
      debugPrint('Endpoint audio error: $e');
    }
  }

  Uint8List _toneBytes({
    required BlsToneProfile profile,
    required bool isRight,
  }) {
    final key = '${_resolvedSoundKey}-${isRight ? 'right' : 'left'}';
    return _toneCache.putIfAbsent(
      key,
      () => buildBlsToneWav(profile: profile, isRight: isRight),
    );
  }

  Future<void> _stopSessionAudio() async {
    try {
      await _audioPlayer.stop();
      await _leftPulsePlayer.stop();
      await _rightPulsePlayer.stop();
      await _voice.stop();
    } catch (_) {
      // Best-effort cleanup when leaving the session screen.
    }
  }

  bool _isNetworkUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  String _mediaPath(String value) {
    final trimmed = value.trim();
    final uri = Uri.tryParse(trimmed);
    return (uri?.path.isNotEmpty == true ? uri!.path : trimmed).toLowerCase();
  }

  bool _isImageVisual(String value) {
    final source = _mediaPath(value);
    return source.endsWith('.png') ||
        source.endsWith('.jpg') ||
        source.endsWith('.jpeg') ||
        source.endsWith('.webp') ||
        source.endsWith('.gif');
  }

  bool _isAnimatedImageVisual(String value) {
    return _mediaPath(value).endsWith('.gif');
  }

  bool _isVideoVisual(String value) {
    if (_isImageVisual(value)) return false;
    final source = _mediaPath(value);
    return widget.settings.visualMediaType.toLowerCase() == 'video' ||
        source.endsWith('.mp4') ||
        source.endsWith('.mov') ||
        source.endsWith('.webm') ||
        source.contains('video');
  }

  Future<void> _restartSet() async {
    _setTimer?.cancel();
    await _audioPlayer.pause();
    await _leftPulsePlayer.stop();
    await _rightPulsePlayer.stop();
    if (!mounted) return;

    setState(() {
      _showCompletionQuestions = false;
      _showClosingGuidance = false;
      _firstCompletionAnswer = null;
      _showSudsRating = false;
      _sudsRating = 5;
      _setComplete = false;
      _isPaused = false;
      _motionStarted = false;
      _remainingSetTime = _setDuration;
      _moveCount = 0;
      _isReversing = false;
      _displayFacingAngle = 0;
    });

    _turnController.stop();
    _turnController.reset();
    _controller.reset();
    _effectController
      ..reset()
      ..repeat();
    _videoPlayingNotifier.value = true;
    _startMotion();
  }

  Future<void> _handleFirstCompletionAnswer(bool answer) async {
    setState(() {
      _firstCompletionAnswer = answer;
    });
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    if (answer) {
      unawaited(
        _voice.speak(
          'Ok, good. Go with that, or go with where you left off.',
          onDone: () {
            Future.delayed(const Duration(milliseconds: 900), () {
              if (mounted) unawaited(_restartSet());
            });
          },
        ),
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      _showSudsRating = true;
    });
    unawaited(
      _voice.speak(
        'Ok. Without any tapping or eye movement, notice what you see and feel. Rate your negative emotion.',
      ),
    );
  }

  Future<void> _handleSudsContinue() async {
    if (_sudsRating <= 1) {
      await _voice.stop();
      if (!mounted) return;
      Navigator.pop(context, true);
      return;
    }

    if (_sessionLimit != Duration.zero && _sessionRemaining == Duration.zero) {
      await _completeByTimeLimit();
      return;
    }

    unawaited(
      _voice.speak(
        'Ok, let us continue with what you noticed about your original image.',
      ),
    );
    await _restartSet();
  }

  void _togglePause() {
    if (_showCompletionQuestions) return;

    if (_setComplete) {
      Navigator.pop(context);
      return;
    }

    setState(() {
      _isPaused = !_isPaused;
      if (_isPaused) {
        _setTimer?.cancel();
        _controller.stop();
        _turnController.stop();
        _effectController.stop();
        _videoPlayingNotifier.value = false;
        if (_shouldFlapWings) {
          _wingController.stop();
        }
        _audioPlayer.pause();
        _leftPulsePlayer.stop();
        _rightPulsePlayer.stop();
        unawaited(_voice.stop());
      } else {
        if (_isReversing) {
          _controller.reverse();
        } else {
          _controller.forward();
        }
        _effectController.repeat();
        _videoPlayingNotifier.value = true;
        if (_shouldFlapWings) {
          _wingController.repeat(reverse: true);
        }
        if (_hasAudioSource) {
          _audioPlayer.resume();
        }
        _startSetTimer();
      }
    });
  }

  bool get _isSpriteVisual => shouldUseSpriteVisual(_resolvedVisualObject);

  void _onTurnTick() {
    final turn = _activeTurn;
    if (turn == null || !mounted) return;
    setState(() => _displayFacingAngle = turn.value);
  }

  void _beginFacingTurn({required bool faceLeft}) {
    final end = faceLeft ? math.pi : 0.0;
    final begin = _displayFacingAngle;
    if ((begin - end).abs() < 0.01) return;

    _activeTurn = Tween<double>(begin: begin, end: end).animate(
      CurvedAnimation(parent: _turnController, curve: Curves.easeInOutCubic),
    );
    _turnController
      ..stop()
      ..reset()
      ..forward();
  }

  Matrix4 _facingTransformMatrix() {
    final matrix = Matrix4.identity()..setEntry(3, 2, 0.0018);
    switch (widget.settings.direction) {
      case AnimationDirection.vertical:
        matrix.rotateX(_displayFacingAngle);
        break;
      case AnimationDirection.horizontal:
      case AnimationDirection.diagonal:
      case AnimationDirection.diagonalReverse:
        matrix.rotateY(_displayFacingAngle);
        break;
    }
    return matrix;
  }

  Widget _wrapFacingTurn(Widget child) {
    return Transform(
      alignment: Alignment.center,
      transform: _facingTransformMatrix(),
      child: child,
    );
  }

  bool get _facesLeft => _displayFacingAngle > (math.pi / 2);

  Offset _objectPosition(double value, Size screenSize) {
    final t = (value + 1) / 2;
    final maxX = math.max(0.0, screenSize.width - _objectSize);
    final maxY = math.max(0.0, screenSize.height - _objectSize);

    switch (widget.settings.direction) {
      case AnimationDirection.horizontal:
        return Offset(
          t * maxX,
          maxY / 2 + _horizontalVerticalOffset(maxY),
        );
      case AnimationDirection.vertical:
        return Offset(maxX / 2, t * maxY);
      case AnimationDirection.diagonal:
        return Offset(t * maxX, t * maxY);
      case AnimationDirection.diagonalReverse:
        return Offset(t * maxX, (1 - t) * maxY);
    }
  }

  double _horizontalVerticalOffset(double maxY) {
    if (_isSpriteVisual) return 0;
    return _horizontalObjectAlignmentY * maxY / 2;
  }

  double get _horizontalObjectAlignmentY {
    if (_isSpriteVisual) return 0;
    return _objectBaseAlignmentY.clamp(-0.32, 0.32);
  }

  double get _objectBaseAlignmentY {
    final visualObject = _resolvedVisualObject;
    final advancedObject = bilateralObjectFromSource(visualObject);
    if (advancedObject != null) {
      switch (advancedObject.category) {
        case 'Cosmic':
        case 'Light & Energy':
          return -0.58;
        case 'Sacred Geometry':
          return -0.5;
        default:
          return -0.42;
      }
    }

    if (!isBlsObjectSource(visualObject)) return -0.4;

    switch (blsSourceId(visualObject)) {
      case 'moon':
        return -0.7;
      case 'sun':
      case 'star':
      case 'orb':
      case 'crystal':
      case 'pearl':
        return -0.64;
      case 'bird':
        return -0.56;
      case 'feather':
        return -0.48;
      case 'butterfly':
      case 'dragonfly':
        return -0.4;
      case 'leaf':
      case 'lotus':
        return -0.36;
      default:
        return -0.4;
    }
  }

  bool get _hasObjectReflection {
    final advancedObject = bilateralObjectFromSource(_resolvedVisualObject);
    if (advancedObject != null) {
      return bilateralObjectHasReflection(advancedObject);
    }

    return blsObjectHasReflection(widget.settings.visualObject.trim());
  }

  @override
  void dispose() {
    unawaited(_stopSessionAudio());
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _controller.dispose();
    _turnController.dispose();
    _wingController.dispose();
    _effectController.dispose();
    _setTimer?.cancel();
    _sessionTimer?.cancel();
    _audioPlayer.dispose();
    _leftPulsePlayer.dispose();
    _rightPulsePlayer.dispose();
    _videoPlayingNotifier.dispose();
    _voice.dispose();
    super.dispose();
  }

  Widget _buildBackground() {
    final source = resolveBlsEnvironmentSource(widget.settings.environmentImage);

    Widget foreground;
    if (isBlsSceneSource(source)) {
      foreground = BlsSceneCanvas(source: source);
    } else if (source.startsWith('http')) {
      foreground = CachedNetworkImage(
        imageUrl: source,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        placeholder: (context, url) => _buildFallbackBackground(),
        errorWidget: (context, url, error) => _buildFallbackBackground(),
      );
    } else {
      foreground = Image.asset(
        source,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) =>
            _buildFallbackBackground(),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildFallbackBackground(),
        foreground,
      ],
    );
  }

  Widget _buildFallbackBackground() {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF6F1E8), Color(0xFFE8EFE8)],
        ),
      ),
    );
  }

  String get _resolvedVisualObject {
    final visualObject = widget.settings.visualObject.trim();
    if (isBlsObjectSource(visualObject)) return visualObject;

    if (isBlsLocalVisualAsset(visualObject) ||
        resolveLocalVisual(visualObject) != null ||
        (visualObject.startsWith('assets/icons/') &&
            isAnimatedAssetVisual(visualObject))) {
      return resolveLocalVisualAsset(visualObject);
    }

    if (visualObject.isEmpty) {
      return kBlsSelectableLocalVisuals.first.id;
    }

    final resolved = resolveSimulationVisualUrl(
      visualObject,
      label: widget.settings.visualLabel,
      mediaType: widget.settings.visualMediaType,
    );

    if (_isNetworkUrl(resolved) ||
        _isImageVisual(resolved) ||
        _isVideoVisual(resolved) ||
        resolved.startsWith('assets/')) {
      return resolved;
    }

    final lowerVisualObject = visualObject.toLowerCase();
    if (lowerVisualObject.contains('butterfly.png') ||
        lowerVisualObject.contains('butterfly lottie') ||
        lowerVisualObject.contains('butterfly')) {
      return butterflyTransparentAsset;
    }

    return resolved;
  }

  Widget _buildVisualObject({double? size}) {
    final visualObject = _resolvedVisualObject;
    final resolvedSize = size ?? _objectSize;
    final advancedObject = bilateralObjectFromSource(visualObject);

    if (advancedObject != null) {
      return _buildAdvancedVisualObject(advancedObject, resolvedSize);
    }

    if (isBlsObjectSource(visualObject)) {
      return BlsObjectCanvas(source: visualObject, size: resolvedSize);
    }

    if (_usesAssetAnimatedVisual) {
      final visualSource = resolveLocalVisualAsset(visualObject);
      return _stableVideoVisual ??
          AssetAnimatedVisual(
            assetPath: visualSource,
            size: resolvedSize,
            playing: _videoPlayingNotifier.value,
            stripWhiteBackground: !shouldUseSpriteVisual(visualSource),
          );
    }

    if (_usesVideoVisual) {
      return _stableVideoVisual ??
          TransparentSessionVisual(
            candidates: _sessionVisualCandidates,
            size: resolvedSize,
            playing: _videoPlayingNotifier.value,
            fallback: _buildVideoFallback(resolvedSize),
          );
    }

    if (_isAnimatedImageVisual(visualObject)) {
      return SizedBox.square(
        dimension: resolvedSize,
        child: Image.network(
          visualObject,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) =>
              _buildVideoFallback(resolvedSize),
        ),
      );
    }

    if (visualObject.startsWith('http') || visualObject.startsWith('assets/')) {
      if (visualObject.startsWith('assets/')) {
        return AssetAnimatedVisual(
          assetPath: visualObject,
          size: resolvedSize,
          playing: _videoPlayingNotifier.value,
        );
      }
      return CachedNetworkImage(
        imageUrl: visualObject,
        width: resolvedSize,
        height: resolvedSize,
        fit: BoxFit.contain,
        placeholder: (context, url) => const SizedBox(
          width: 70,
          height: 70,
          child: CircularProgressIndicator(),
        ),
        errorWidget: (context, url, error) => const Icon(Icons.error, size: 70),
      );
    }

    return Image.asset(
      visualObject,
      width: resolvedSize,
      height: resolvedSize,
      fit: BoxFit.contain,
    );
  }

  Widget _buildVideoFallback(double size) {
    final configured = widget.settings.visualPlaybackUrl?.trim();
    final source = configured?.isNotEmpty == true
        ? configured!
        : widget.settings.visualObject.trim();
    final posterCandidates = <String>[
      if (widget.settings.visualTransparentUrl?.trim().isNotEmpty == true)
        widget.settings.visualTransparentUrl!.trim(),
      cloudinaryAnimatedTransparentGif(source),
      cloudinaryTransparentVideoFrame(source),
      if (cloudinaryVideoPoster(source) != null) cloudinaryVideoPoster(source)!,
      if (widget.settings.visualPoster?.trim().isNotEmpty == true)
        widget.settings.visualPoster!.trim(),
    ];

    for (final poster in posterCandidates) {
      if (!poster.startsWith('http')) {
        if (poster.startsWith('assets/')) {
          return Image.asset(
            poster,
            width: size,
            height: size,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => _buildVideoIcon(size),
          );
        }
        continue;
      }
      return CachedNetworkImage(
        imageUrl: poster,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorWidget: (context, url, error) => _buildVideoIcon(size),
      );
    }
    return _buildVideoIcon(size);
  }

  Widget _buildVideoIcon(double size) {
    return SizedBox.square(
      dimension: size,
      child: const DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0x22FFFFFF),
        ),
        child: Icon(
          Icons.play_circle_outline_rounded,
          color: Colors.white,
          size: 42,
        ),
      ),
    );
  }

  double get _effectTime =>
      (_effectController.lastElapsedDuration ?? Duration.zero).inMilliseconds
          .toDouble();

  Widget _buildAdvancedVisualObject(BilateralObject object, double size) {
    const canvasSize = 170.0;
    return SizedBox.square(
      dimension: size,
      child: FittedBox(
        child: SizedBox.square(
          dimension: canvasSize,
          child: CustomPaint(
            painter: ObjectPainter(
              type: object,
              t: _effectTime,
              x: canvasSize / 2,
              y: canvasSize / 2,
              vx: _facesLeft ? -1 : 1,
            ),
          ),
        ),
      ),
    );
  }

  double get _objectSize {
    final visualObject = _resolvedVisualObject;
    if (shouldUseSpriteVisual(visualObject)) {
      return spriteSessionSizeFor(visualObject);
    }
    if (isBlsLocalVisualAsset(visualObject)) return 140;

    final advancedObject = bilateralObjectFromSource(visualObject);
    if (advancedObject != null) {
      return bilateralObjectDisplaySize(advancedObject);
    }

    if (!isBlsObjectSource(visualObject)) return 74;

    switch (blsSourceId(visualObject)) {
      case 'sun':
        return 140;
      case 'moon':
      case 'butterfly':
        return 120;
      case 'bird':
        return 100;
      case 'leaf':
        return 90;
      case 'feather':
        return 105;
      case 'star':
      case 'orb':
      case 'crystal':
      case 'pearl':
        return 110;
      case 'lotus':
        return 118;
      case 'dragonfly':
        return 130;
      default:
        return 110;
    }
  }

  bool get _shouldFlapWings {
    final visualObject = _resolvedVisualObject.toLowerCase();
    if (isBlsObjectSource(visualObject) ||
        bilateralObjectFromSource(visualObject) != null) {
      return false;
    }
    if (shouldUseSpriteVisual(_resolvedVisualObject)) return false;
    return visualObject.contains('butterfly') && !_isImageVisual(visualObject);
  }

  Widget _buildWingHalf({
    required bool isLeft,
    required double wingScale,
    required double wingAngle,
  }) {
    return Transform(
      alignment: isLeft ? Alignment.centerRight : Alignment.centerLeft,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.001)
        ..rotateY(isLeft ? wingAngle : -wingAngle),
      child: Transform.scale(
        scaleX: wingScale,
        alignment: isLeft ? Alignment.centerRight : Alignment.centerLeft,
        child: ClipRect(
          child: Align(
            alignment: isLeft ? Alignment.centerLeft : Alignment.centerRight,
            widthFactor: 0.5,
            child: _buildVisualObject(size: 74),
          ),
        ),
      ),
    );
  }

  Widget _buildButterflyBodyStrip() {
    return ClipRect(
      child: Align(widthFactor: 0.22, child: _buildVisualObject(size: 74)),
    );
  }

  Widget _buildFlappingButterfly() {
    final wingScale = 0.72 + (_wingAnimation.value * 0.34);
    final wingRise = (1 - _wingAnimation.value) * 3.5;
    final wingAngle = -0.42 + (_wingAnimation.value * 0.84);

    return SizedBox(
      width: 96,
      height: 88,
      child: Center(
        child: Transform.translate(
          offset: Offset(0, -wingRise),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildWingHalf(
                    isLeft: true,
                    wingScale: wingScale,
                    wingAngle: wingAngle,
                  ),
                  _buildWingHalf(
                    isLeft: false,
                    wingScale: wingScale,
                    wingAngle: wingAngle,
                  ),
                ],
              ),
              _buildButterflyBodyStrip(),
            ],
          ),
        ),
      ),
    );
  }

  void _leaveSimulation([dynamic result]) {
    _videoPlayingNotifier.value = false;
    _controller.stop();
    _turnController.stop();
    _isReversing = false;
    _displayFacingAngle = 0;
    unawaited(_stopSessionAudio());
    Navigator.pop(context, result);
  }

  Widget _buildAnimatedVisualObject({Widget? stableChild}) {
    final visualBody = _shouldFlapWings
        ? _buildFlappingButterfly()
        : (stableChild ?? _sessionMovingVisual ?? _buildVisualObject());

    if (_isSpriteVisual) {
      return _wrapFacingTurn(
        SizedBox(
          width: _objectSize,
          height: _objectSize,
          child: Center(child: visualBody),
        ),
      );
    }

    final centerWeight = 1 - _animation.value.abs();
    final isVideo = _usesVideoVisual;
    final isAssetAnimated = _usesAssetAnimatedVisual;
    final scaleBoost = isVideo || isAssetAnimated ? 0.14 : 0.06;
    final scale = 1.0 + (centerWeight * scaleBoost);
    final glowOpacity =
        0.14 + (centerWeight * ((isVideo || isAssetAnimated) ? 0.16 : 0.1));

    Widget content = Transform.rotate(
      angle: _animation.value * 0.08,
      child: Transform.scale(
        scale: scale,
        child: isVideo || isAssetAnimated
            ? SizedBox(
                width: _objectSize,
                height: _objectSize,
                child: Center(child: visualBody),
              )
            : Container(
                width: _objectSize,
                height: _objectSize,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: glowOpacity),
                      blurRadius: 28,
                      spreadRadius: 8,
                    ),
                  ],
                ),
                child: visualBody,
              ),
      ),
    );

    return _wrapFacingTurn(content);
  }

  Widget _buildObjectReflection() {
    return IgnorePointer(
      child: Opacity(
        opacity: 0.25,
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Transform.scale(
            scaleY: -0.35,
            child: _usesVideoVisual
                ? _buildVideoFallback(_objectSize)
                : _buildVisualObject(size: _objectSize),
          ),
        ),
      ),
    );
  }

  Widget _buildPaperTexture() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: 0.04,
          child: CustomPaint(painter: _PaperTexturePainter()),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          unawaited(_stopSessionAudio());
        }
      },
      child: Scaffold(
        body: Stack(
        clipBehavior: Clip.none,
        children: [
          // Background
          Positioned.fill(child: _buildBackground()),

          if (_hasObjectReflection)
            AnimatedBuilder(
              animation: _animation,
              builder: (context, child) {
                final screenSize = MediaQuery.sizeOf(context);
                final pos = _objectPosition(_animation.value, screenSize);
                return Positioned(
                  left: pos.dx,
                  top: screenSize.height * 0.72,
                  width: _objectSize,
                  height: _objectSize,
                  child: _buildObjectReflection(),
                );
              },
            ),

          // Moving Object
          AnimatedBuilder(
            animation: _shouldFlapWings
                ? Listenable.merge([
                    _animation,
                    _wingAnimation,
                    _turnController,
                  ])
                : Listenable.merge([_animation, _turnController]),
            child: _sessionMovingVisual,
            builder: (context, child) {
              final screenSize = MediaQuery.sizeOf(context);
              final pos = _objectPosition(_animation.value, screenSize);
              return Positioned(
                left: pos.dx,
                top: pos.dy,
                width: _objectSize,
                height: _objectSize,
                child: IgnorePointer(
                  child: OverflowBox(
                    minWidth: 0,
                    minHeight: 0,
                    maxWidth: _objectSize * 1.08,
                    maxHeight: _objectSize * 1.08,
                    child: SizedBox(
                      width: _objectSize,
                      height: _objectSize,
                      child: _buildAnimatedVisualObject(stableChild: child),
                    ),
                  ),
                ),
              );
            },
          ),

          if (widget.settings.showCompletionQuestions) _buildPaperTexture(),
          widget.settings.showCompletionQuestions
              ? _buildPdfSessionChrome()
              : _buildTopBar(),
          if (_showCompletionQuestions) _buildCompletionOverlay(),
          if (_showIntroGuidance) _buildIntroOverlay(),
          if (_showClosingGuidance) _buildClosingGuidanceOverlay(),
        ],
        ),
      ),
    );
  }

  Widget _buildPdfSessionChrome() {
    final totalSets = widget.settings.totalSets <= 0
        ? 34
        : widget.settings.totalSets;
    final currentSet = _moveCount.clamp(0, totalSets);
    final textColor = _sceneUsesLightText ? Colors.white : _inkText;
    final shadow = [
      Shadow(
        color: Colors.black.withValues(
          alpha: _sceneUsesLightText ? 0.25 : 0.08,
        ),
        blurRadius: 8,
        offset: const Offset(0, 1),
      ),
    ];

    return SafeArea(
      child: Stack(
        children: [
          Positioned(
            top: 28,
            left: 38,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPdfExitButton(textColor),
              ],
            ),
          ),
          Positioned(
            top: 32,
            right: 38,
            child: Text(
              '$currentSet of $totalSets',
              style: TextStyle(
                color: textColor.withValues(
                  alpha: _sceneUsesLightText ? 0.9 : 1,
                ),
                fontSize: 13,
                fontStyle: FontStyle.italic,
                shadows: shadow,
              ),
            ),
          ),
          if (widget.settings.maxDurationMinutes > 0)
            Positioned(
              top: 54,
              right: 38,
              child: Text(
                'Remaining ${_formatDuration(_sessionRemaining)}',
                style: TextStyle(
                  color: textColor.withValues(
                    alpha: _sceneUsesLightText ? 0.82 : 0.92,
                  ),
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  shadows: shadow,
                ),
              ),
            ),
          Positioned(
            right: 38,
            bottom: 32,
            child: _buildPdfPauseButton(textColor),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration value) {
    if (value == Duration.zero) return '0 min';
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60);
    if (minutes <= 0) return '${seconds}s';
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }

  Widget _buildPdfExitButton(Color textColor) {
    return _buildProminentControlButton(
      label: 'EXIT',
      icon: Icons.close_rounded,
      onPressed: () => _leaveSimulation(false),
      textColor: textColor,
    );
  }

  Widget _buildPdfPauseButton(Color textColor) {
    return _buildProminentControlButton(
      label: _isPaused ? 'RESUME' : 'PAUSE',
      icon: _isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
      onPressed: _togglePause,
      textColor: textColor,
      emphasized: true,
    );
  }

  Widget _buildProminentControlButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    required Color textColor,
    bool emphasized = false,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: TextButton.icon(
          onPressed: onPressed,
          icon: Icon(
            icon,
            size: 20,
            color: emphasized ? const Color(0xFF151515) : textColor,
          ),
          label: Text(
            label,
            style: TextStyle(
              color: emphasized ? const Color(0xFF151515) : textColor,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
          style: TextButton.styleFrom(
            backgroundColor: emphasized
                ? Colors.white.withValues(alpha: 0.9)
                : (_sceneUsesLightText
                    ? Colors.white.withValues(alpha: 0.28)
                    : Colors.black.withValues(alpha: 0.08)),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            minimumSize: const Size(108, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(26),
              side: BorderSide(
                color: emphasized
                    ? Colors.black.withValues(alpha: 0.18)
                    : (_sceneUsesLightText
                        ? Colors.white.withValues(alpha: 0.4)
                        : Colors.black.withValues(alpha: 0.12)),
                width: emphasized ? 1.5 : 1,
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _sceneUsesLightText {
    final source = resolveBlsEnvironmentSource(widget.settings.environmentImage);
    return isBlsSceneSource(source) &&
        const {'night', 'forest'}.contains(blsSourceId(source));
  }

  Widget _buildIntroOverlay() {
    final roadmap = widget.settings.roadmapSummary?.trim();
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.42),
        child: SafeArea(
          child: Align(
            alignment: const Alignment(0, -0.18),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 520),
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Phase 1 — Bilateral Stimulation',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _inkText,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'Serif',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      [
                        '1. The bilateral stimulation will start when you press Start.',
                        if (roadmap != null && roadmap.isNotEmpty)
                          '2. Roadmap: $roadmap',
                        '3. Bring your image and feeling into mind.',
                        '4. Let your mind wander — thoughts may move forward or backward in time.',
                      ].join('\n'),
                      style: const TextStyle(
                        color: _inkText,
                        fontSize: 15,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 14),
                    ElevatedButton(
                      onPressed: _handleIntroStart,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6A8A5A),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      child: const Text('Start'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompletionOverlay() {
    return Positioned.fill(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF8F5F0), Color(0xFFE8EFE8)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Take a gentle breath.\nNotice what you experienced.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _inkText,
                      fontSize: 19,
                      fontStyle: FontStyle.italic,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 32),
                  if (_showSudsRating)
                    _buildSudsCard()
                  else
                    _buildQuestionCard(
                      text:
                          'Is it changing and still connected to your original image?',
                      selectedAnswer: _firstCompletionAnswer,
                      onYes: () => _handleFirstCompletionAnswer(true),
                      onNo: () => _handleFirstCompletionAnswer(false),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildClosingGuidanceOverlay() {
    return Positioned.fill(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF8F5F0), Color(0xFFE8EFE8)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxWidth: 520),
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 30,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.spa_outlined,
                      color: Color(0xFF6A8A5A),
                      size: 42,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Return to your calm place',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _inkText,
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Bring up your pincode and spend one minute finding that calm feeling in your body.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _inkText,
                        fontSize: 15,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Please wait 4 days to 1 week before the next session while processing continues.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _inkText,
                        fontSize: 13,
                        height: 1.45,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () async {
                        await _voice.stop();
                        if (!mounted) return;
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const MyCalmSpaceExercise(),
                          ),
                        );
                        if (!mounted) return;
                        _leaveSimulation(false);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6A8A5A),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      child: const Text('Open calm place (pincode)'),
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: () => _leaveSimulation(false),
                      style: TextButton.styleFrom(foregroundColor: _inkText),
                      child: const Text('Finish for today'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSudsCard() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Return to the original image. Without tapping or eye movement, notice what you see and feel.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _inkText,
              fontSize: 15,
              fontStyle: FontStyle.italic,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'Negative emotion: $_sudsRating / 10',
            style: const TextStyle(
              color: _inkText,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          Slider(
            value: _sudsRating.toDouble(),
            min: 0,
            max: 10,
            divisions: 10,
            activeColor: const Color(0xFF6A8A5A),
            inactiveColor: const Color(0xFFD8D2C8),
            label: _sudsRating.toString(),
            onChanged: (value) {
              setState(() => _sudsRating = value.round());
            },
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _handleSudsContinue,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6A8A5A),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child: Text(
              _sudsRating <= 1 ? 'Move to phase 2' : 'Continue processing',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionCard({
    required String text,
    required bool? selectedAnswer,
    required VoidCallback onYes,
    required VoidCallback onNo,
  }) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _inkText,
              fontSize: 16,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: _buildQuestionButton(
                  'Yes',
                  onYes,
                  selected: selectedAnswer == true,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildQuestionButton(
                  'No',
                  onNo,
                  selected: selectedAnswer == false,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionButton(
    String text,
    VoidCallback onTap, {
    required bool selected,
  }) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: selected
            ? const Color(0xFF5A6A50)
            : _inkText,
        backgroundColor: selected
            ? const Color(0xFF7A9A6A).withValues(alpha: 0.18)
            : Colors.white,
        side: BorderSide(
          color: selected ? const Color(0xFF7A9A6A) : const Color(0xFFD8D2C8),
          width: 1.6,
        ),
        padding: const EdgeInsets.symmetric(vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
      ),
      child: Text(text),
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(50),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(50),
                border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  // Back button + Title
                  IconButton(
                    icon: const Icon(
                      Icons.arrow_back_ios_new,
                      color: Colors.black87,
                      size: 18,
                    ),
                    onPressed: () => _leaveSimulation(),
                  ),
                  const Text(
                    'Bilateral set',
                    style: TextStyle(
                      color: Colors.black87,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),

                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Text(
                      _setComplete
                          ? 'Set complete'
                          : '${_remainingSetTime.inSeconds}s',
                      style: const TextStyle(
                        color: Colors.black87,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),

                  // Pause / Resume button
                  ElevatedButton(
                    onPressed: _togglePause,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF537E5D),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    child: Text(
                      _setComplete
                          ? 'Done'
                          : _isPaused
                          ? 'Resume'
                          : 'Pause',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PaperTexturePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 0.6;

    for (var i = 0; i < 700; i++) {
      final x = ((i * 37) % 1000) / 1000 * size.width;
      final y = ((i * 61) % 1000) / 1000 * size.height;
      canvas.drawCircle(Offset(x, y), (i % 3 + 1) * 0.35, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
