import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:intl/intl.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math' as math;

import '../../../core/models/channel.dart';
import '../../../core/platform/platform_detector.dart';
import '../../../core/services/service_locator.dart';
import '../../../core/services/channel_test_service.dart';
import '../../../core/services/log_service.dart';
import '../../settings/providers/settings_provider.dart';

enum PlayerState {
  idle,
  loading,
  playing,
  paused,
  error,
  buffering,
}

/// Unified player provider that uses:
/// - Native Android Activity (via MethodChannel) on Android TV for best 4K performance
/// - media_kit on all other platforms (Windows, Android phone/tablet, etc.)
class PlayerProvider extends ChangeNotifier {
  // media_kit player (for all platforms except Android TV)
  Player? _mediaKitPlayer;
  VideoController? _videoController;

  // Common state
  Channel? _currentChannel;
  List<Channel> _playlist = [];
  int _currentIndex = -1;

  PlayerState _state = PlayerState.idle;
  String? _error;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;
  bool _isMuted = false;
  double _playbackSpeed = 1.0;
  bool _isFullscreen = false;
  bool _controlsVisible = true;
  int _volumeBoostDb = 0;

  int _retryCount = 0;
  static const int _maxRetries = 2; // 重试2次
  Timer? _retryTimer;
  bool _isAutoSwitching = false; // 标记是否正在自动切换源
  bool _isAutoDetecting = false; // 标记是否正在自动检测源
  bool _isSoftwareDecoding = false;
  bool _noVideoFallbackAttempted = false;
  bool _allowSoftwareFallback = true;
  String _windowsHwdecMode = 'auto-safe';
  bool _isDisposed = false;
  StreamSubscription<VideoParams>? _videoParamsSubscription;
  bool _deinterlaceConfiguredForCurrentStream = false;
  bool _initialHwdecSet = false;
  int _deinterlaceGeneration = 0; // 代际计数器，用于检测过时的 videoParams 回调
  String _videoOutput = 'auto';
  String _vo = 'unknown';
  String _configuredVo = 'auto';

  // Debug & Stream Specs
  String _hwdecMode = 'unknown';
  String _videoCodec = '';
  double _fps = 0;
  String _configuredHwdec = 'unknown';

  double _currentFps = 0;
  int _videoWidth = 0;
  int _videoHeight = 0;
  double _downloadSpeed = 0;

  String _audioCodec = '';
  int _audioChannels = 0;

  // Override duration for catchup playback
  Duration? _overrideDuration;

  // On Android TV, we use native player via Activity, so don't init any Flutter player
  // On Android phone/tablet and other platforms, use media_kit
  bool get _useNativePlayer => Platform.isAndroid && PlatformDetector.isTV;

  // Getters
  Player? get player => _mediaKitPlayer;
  VideoController? get videoController => _videoController;

  Channel? get currentChannel => _currentChannel;
  PlayerState get state => _state;
  String? get error => _error;
  Duration get position => _position;
  Duration get duration {
    // Return override duration if set and player reports zero/small duration
    if (_overrideDuration != null && _duration.inSeconds < 10) {
      return _overrideDuration!;
    }
    return _duration;
  }

  double get volume => _volume;
  bool get isMuted => _isMuted;
  double get playbackSpeed => _playbackSpeed;
  bool get isFullscreen => _isFullscreen;
  bool get controlsVisible => _controlsVisible;

  bool get isPlaying => _state == PlayerState.playing;
  bool get isLoading =>
      _state == PlayerState.loading || _state == PlayerState.buffering;
  bool get hasError => _state == PlayerState.error && _error != null;

  double get currentFps => _currentFps;
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;
  double get downloadSpeed => _downloadSpeed;

  int get currentSourceIndex => _currentChannel?.currentSourceIndex ?? 0;
  int get sourceCount => _currentChannel?.sourceCount ?? 1;

  String get videoInfo {
    if (_mediaKitPlayer == null) return '';
    final w = _mediaKitPlayer!.state.width ?? _videoWidth;
    final h = _mediaKitPlayer!.state.height ?? _videoHeight;
    if (w == 0 || h == 0) return '';
    final parts = <String>['${w}x$h'];
    if (_videoCodec.isNotEmpty) parts.add(_videoCodec);
    if (_fps > 0) parts.add('${_fps.toStringAsFixed(1)} fps');
    if (_audioCodec.isNotEmpty) {
      final audioPart = StringBuffer(_audioCodec);
      if (_audioChannels > 0) {
        audioPart.write(' | $_audioChannels声道');
      }
      parts.add(audioPart.toString());
    }
    final hwdecInfo = _formatHwdecInfo();
    if (hwdecInfo.isNotEmpty) {
      parts.add('hwdec: $hwdecInfo');
    }
    final voInfo = _formatVoInfo();
    if (voInfo.isNotEmpty) {
      parts.add('vo: $voInfo');
    }
    if (_downloadSpeed > 0) {
      final bitrateMbps = _downloadSpeed * 8 / 1000000;
      if (bitrateMbps >= 100) {
        parts.add('${bitrateMbps.toStringAsFixed(0)} Mbps');
      } else {
        parts.add('${bitrateMbps.toStringAsFixed(1)} Mbps');
      }
    }
    return parts.join(' | ');
  }

  String _formatHwdecInfo() => _hwdecMode;
  String _formatVoInfo() => _vo;

  double get progress {
    if (_duration.inMilliseconds == 0) return 0;
    return _position.inMilliseconds / _duration.inMilliseconds;
  }

  /// Create Media object with custom User-Agent header
  Media _createMedia(String url) {
    final userAgent = ServiceLocator.settings?.userAgent ?? SettingsProvider.defaultUserAgent;
    ServiceLocator.log.d('PlayerProvider: 创建Media对象 User-Agent: $userAgent');
    return Media(url, httpHeaders: {'User-Agent': userAgent});
  }

  /// Check if current content is seekable (VOD or replay)
  bool get isSeekable {
    if (_currentChannel?.isLive == true) return false;

    if (_currentChannel?.isSeekable == true) {
      if (_currentChannel?.type == ChannelType.replay) {
        return true;
      }
      if (_duration.inSeconds > 0 && _duration.inSeconds <= 86400) {
        return true;
      }
    }

    if (_duration.inSeconds > 0 && _duration.inSeconds <= 86400) {
      if (_currentChannel?.isLive != true) {
        return true;
      }
    }

    return false;
  }

  /// Check if should show progress bar based on settings and content
  bool shouldShowProgressBar(String progressBarMode) {
    if (progressBarMode == 'never') return false;
    if (_overrideDuration != null) return true;
    if (progressBarMode == 'always') return _duration.inSeconds > 0;
    return isSeekable && _duration.inSeconds > 0;
  }

  /// Set override duration for catchup playback
  void setOverrideDuration(Duration? duration) {
    _overrideDuration = duration;
    notifyListeners();
  }

  /// Check if current content is live stream
  bool get isLiveStream => !isSeekable;

  // 清除错误状态（支持 silent 参数）
  void clearError({bool silent = false}) {
    _error = null;
    _errorDisplayed = true;
    if (_state == PlayerState.error) {
      _state = PlayerState.idle;
    }
    if (!silent) {
      notifyListeners();
    }
  }

  // 错误防抖
  DateTime? _lastErrorTime;
  String? _lastErrorMessage;
  bool _errorDisplayed = false;

  void _setError(String error) {
    ServiceLocator.log.d(
        'PlayerProvider: _setError 被调用 - 当前重试次数: $_retryCount/$_maxRetries, 错误: $error');

    if (error.contains('seekable') ||
        error.contains('Cannot seek') ||
        error.contains('seek in this stream')) {
      ServiceLocator.log.d('PlayerProvider: 忽略 seek 错误（直播流不支持拖动）');
      return;
    }

    if (error.contains('Error decoding audio') ||
        error.contains('audio decoder') ||
        error.contains('Audio decoding')) {
      ServiceLocator.log.d(
          'PlayerProvider: Ignore audio decode warning (likely partial frame decode failure)');
      return;
    }

    if (_retryCount < _maxRetries && _currentChannel != null) {
      _retryCount++;
      ServiceLocator.log
          .d('PlayerProvider: 播放错误，尝试重试($_retryCount/$_maxRetries): $error');
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(milliseconds: 500), () {
        if (_currentChannel != null) {
          _retryPlayback();
        }
      });
      return;
    }

    if (_currentChannel != null && _currentChannel!.hasMultipleSources) {
      final currentSourceIndex = _currentChannel!.currentSourceIndex;
      final totalSources = _currentChannel!.sourceCount;

      int nextIndex = currentSourceIndex + 1;

      if (nextIndex < totalSources) {
        ServiceLocator.log.d(
            'PlayerProvider: 当前源(${currentSourceIndex + 1}/$totalSources) 重试失败，检测源 ${nextIndex + 1}');

        _isAutoDetecting = true;
        _checkAndSwitchToNextSource(nextIndex, error);
        return;
      } else {
        ServiceLocator.log.d(
            'PlayerProvider: 已到最后一个源 (${currentSourceIndex + 1}/$totalSources), 停止尝试');
      }
    }

    final now = DateTime.now();
    if (_errorDisplayed) {
      return;
    }
    if (_lastErrorMessage == error &&
        _lastErrorTime != null &&
        now.difference(_lastErrorTime!).inSeconds < 30) {
      return;
    }
    _lastErrorMessage = error;
    _lastErrorTime = now;

    ServiceLocator.log.d('PlayerProvider: Playback failed, show error');
    _state = PlayerState.error;
    _error = error;
    notifyListeners();
  }

  PlayerProvider() {
    _initPlayer();
  }

  // ==================== 播放控制对外 API ====================

  /// 播放频道
  Future<void> playChannel(
    Channel channel, {
    List<Channel>? playlist,
    bool preserveCurrentSource = false,
    bool silent = false,
  }) async {
    if (playlist != null) {
      _playlist = playlist;
      _currentIndex = playlist.indexWhere((c) => c.id == channel.id);
    }
    _currentChannel = channel;
    if (!preserveCurrentSource) {
      _currentChannel?.currentSourceIndex = 0;
    }
    _retryCount = 0;
    _error = null;
    _errorDisplayed = false;
    await _playCurrentSource(silent: silent);
  }

  /// 直接播放 URL
  Future<void> playUrl(String url, {String? title}) async {
    final channel = Channel(
      id: 'custom_url_${DateTime.now().millisecondsSinceEpoch}',
      name: title ?? '自定义流',
      url: url,
      sources: [url],
      groupName: '自定义',
      playlistId: 0, // 使用 int 类型替代 String
    );
    await playChannel(channel);
  }

  /// 播放下一个频道（支持来自 UI 的 name 等扩展命名参数）
  Future<void> playNext([dynamic arg]) async {
    if (_playlist.isEmpty || _currentIndex < 0) return;
    int nextIndex = (_currentIndex + 1) % _playlist.length;
    _currentIndex = nextIndex;
    await playChannel(_playlist[nextIndex]);
  }

  /// 播放上一个频道（支持来自 UI 的 name 等扩展命名参数）
  Future<void> playPrevious([dynamic arg]) async {
    if (_playlist.isEmpty || _currentIndex < 0) return;
    int prevIndex = (_currentIndex - 1 + _playlist.length) % _playlist.length;
    _currentIndex = prevIndex;
    await playChannel(_playlist[prevIndex]);
  }

  /// 切换到下一个视频源
  Future<void> switchToNextSource() async {
    if (_currentChannel == null || !_currentChannel!.hasMultipleSources) return;
    final nextIndex = (_currentChannel!.currentSourceIndex + 1) % _currentChannel!.sourceCount;
    _currentChannel!.currentSourceIndex = nextIndex;
    _retryCount = 0;
    await _playCurrentSource();
  }

  /// 切换到上一个视频源
  Future<void> switchToPreviousSource() async {
    if (_currentChannel == null || !_currentChannel!.hasMultipleSources) return;
    final prevIndex = (_currentChannel!.currentSourceIndex - 1 + _currentChannel!.sourceCount) % _currentChannel!.sourceCount;
    _currentChannel!.currentSourceIndex = prevIndex;
    _retryCount = 0;
    await _playCurrentSource();
  }

  /// 暂停
  Future<void> pause([dynamic _]) async {
    if (_useNativePlayer) return;
    await _mediaKitPlayer?.pause();
    _state = PlayerState.paused;
    notifyListeners();
  }

  /// 恢复/播放
  Future<void> play([dynamic _]) async {
    if (_useNativePlayer) return;
    await _mediaKitPlayer?.play();
    _state = PlayerState.playing;
    notifyListeners();
  }

  /// 切换播放/暂停状态
  Future<void> togglePlayPause([dynamic _]) async {
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  /// 停止播放
  Future<void> stop([dynamic _]) async {
    if (!_useNativePlayer) {
      await _mediaKitPlayer?.stop();
    }
    _state = PlayerState.idle;
    _currentChannel = null;
    _overrideDuration = null;
    notifyListeners();
  }

  /// 跳转进度
  Future<void> seek(Duration position) async {
    if (_useNativePlayer) return;
    await _mediaKitPlayer?.seek(position);
  }

  /// 设置音量 (0.0 ~ 1.0)
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    _isMuted = _volume == 0;
    if (!_useNativePlayer) {
      await _mediaKitPlayer?.setVolume(_volume * 100);
    }
    notifyListeners();
  }

  /// 静音切换
  Future<void> toggleMute() async {
    _isMuted = !_isMuted;
    if (!_useNativePlayer) {
      await _mediaKitPlayer?.setVolume(_isMuted ? 0 : _volume * 100);
    }
    notifyListeners();
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    _playbackSpeed = speed;
    if (!_useNativePlayer) {
      await _mediaKitPlayer?.setRate(speed);
    }
    notifyListeners();
  }

  /// 重新初始化播放器
  Future<void> reinitializePlayer({
    String bufferStrength = 'fast',
    bool useSoftwareDecoding = false,
  }) async {
    final currentChan = _currentChannel;
    final currentPos = _position;
    await _initMediaKitPlayer(
      bufferStrength: bufferStrength,
      useSoftwareDecoding: useSoftwareDecoding,
    );
    if (currentChan != null) {
      await playChannel(currentChan, preserveCurrentSource: true);
      if (currentPos > Duration.zero && isSeekable) {
        await seek(currentPos);
      }
    }
  }

  /// 播放回放节目入口方法
  Future<void> playCatchup({
    required Channel channel,
    required String catchupTemplate,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    if (catchupTemplate.isEmpty) {
      ServiceLocator.log.e('PlayerProvider: 回放失败，未找到有效的 catchup-source 模板');
      _setError('该频道不支持回放或无有效回放模板');
      return;
    }

    _currentChannel = channel;
    _retryCount = 0;
    _error = null;
    _errorDisplayed = false;

    final programDuration = endTime.difference(startTime);
    setOverrideDuration(programDuration);

    final catchupUrl = _buildCatchupUrl(
      channelUrl: channel.currentUrl,
      template: catchupTemplate,
      startTime: startTime,
      endTime: endTime,
    );

    ServiceLocator.log.i('PlayerProvider: 开始播放回放，目标URL -> $catchupUrl', tag: 'PlayerProvider');

    _state = PlayerState.loading;
    notifyListeners();

    try {
      if (!_useNativePlayer) {
        final realUrl = await ServiceLocator.redirectCache.resolveRealPlayUrl(catchupUrl);
        _resetDeinterlaceDetection();
        await _applyDeinterlaceFilter();
        await _mediaKitPlayer?.open(_createMedia(realUrl));
        _state = PlayerState.playing;
      }
    } catch (e) {
      ServiceLocator.log.e('PlayerProvider: 回放加载异常: $e', tag: 'PlayerProvider');
      _setError('回放加载失败: $e');
    }
    notifyListeners();
  }

  /// 内部 Helper：根据 `${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}` 替换拼接回放 URL
  String _buildCatchupUrl({
    required String channelUrl,
    required String template,
    required DateTime startTime,
    required DateTime endTime,
  }) {
    String result = template;
    final regExp = RegExp(r'\$\{\(([be])\)([^}]+)\}');

    result = result.replaceAllMapped(regExp, (match) {
      final type = match.group(1);      // 'b' 代表 begin, 'e' 代表 end
      final formatPattern = match.group(2)!; // 如 'yyyyMMddHHmmss'
      final targetTime = (type == 'b') ? startTime : endTime;

      try {
        return DateFormat(formatPattern).format(targetTime);
      } catch (e) {
        return DateFormat('yyyyMMddHHmmss').format(targetTime);
      }
    });

    if (result.startsWith('?')) {
      if (channelUrl.contains('?')) {
        return '$channelUrl&${result.substring(1)}';
      } else {
        return '$channelUrl$result';
      }
    } else if (result.startsWith('http://') || result.startsWith('https://')) {
      return result;
    } else {
      return '$channelUrl$result';
    }
  }

  /// 播放当前所选的频道（直播）
  Future<void> _playCurrentSource({bool silent = false}) async {
    if (_currentChannel == null) return;
    setOverrideDuration(null);

    final url = _currentChannel!.currentUrl;
    _state = PlayerState.loading;
    _error = null;
    if (!silent) {
      notifyListeners();
    }

    try {
      if (!_useNativePlayer) {
        final realUrl = await ServiceLocator.redirectCache.resolveRealPlayUrl(url);
        _resetDeinterlaceDetection();
        await _applyDeinterlaceFilter();
        await _mediaKitPlayer?.open(_createMedia(realUrl));
        _state = PlayerState.playing;
      }
    } catch (e) {
      _setError('播放失败: $e');
    }
    if (!silent) {
      notifyListeners();
    }
  }

  /// 检测并切换到下一个源
  Future<void> _checkAndSwitchToNextSource(
      int nextIndex, String originalError) async {
    if (_currentChannel == null || !_isAutoDetecting) return;

    _currentChannel!.currentSourceIndex = nextIndex;
    _state = PlayerState.loading;
    notifyListeners();

    ServiceLocator.log.d(
        'PlayerProvider: 检测源 ${nextIndex + 1}/${_currentChannel!.sourceCount}');

    final testService = ChannelTestService();
    final tempChannel = Channel(
      id: _currentChannel!.id,
      name: _currentChannel!.name,
      url: _currentChannel!.sources[nextIndex],
      groupName: _currentChannel!.groupName,
      logoUrl: _currentChannel!.logoUrl,
      sources: [_currentChannel!.sources[nextIndex]],
      playlistId: _currentChannel!.playlistId,
    );

    final result = await testService.testChannel(tempChannel);

    if (!_isAutoDetecting) return;

    if (!result.isAvailable) {
      final totalSources = _currentChannel!.sourceCount;
      final nextNextIndex = nextIndex + 1;

      if (nextNextIndex < totalSources) {
        _checkAndSwitchToNextSource(nextNextIndex, originalError);
      } else {
        _isAutoDetecting = false;
        _state = PlayerState.error;
        _error = '所有 $totalSources 个源都不可用';
        notifyListeners();
      }
      return;
    }

    _isAutoDetecting = false;
    _retryCount = 0;
    _isAutoSwitching = true;
    _lastErrorMessage = null;
    _playCurrentSource();
    _isAutoSwitching = false;
  }

  /// 重试播放当前频道
  Future<void> _retryPlayback() async {
    if (_currentChannel == null) return;

    _state = PlayerState.loading;
    _error = null;
    notifyListeners();

    final url = _currentChannel!.currentUrl;

    try {
      if (!_useNativePlayer) {
        final realUrl = await ServiceLocator.redirectCache.resolveRealPlayUrl(url);
        await _applyDeinterlaceFilter();
        await _mediaKitPlayer?.open(_createMedia(realUrl));
        _state = PlayerState.playing;
      }
    } catch (e) {
      _setError('Failed to play channel: $e');
    }
    notifyListeners();
  }

  void _initPlayer({bool useSoftwareDecoding = false}) {
    if (_useNativePlayer) {
      return;
    }
    _initMediaKitPlayer(useSoftwareDecoding: useSoftwareDecoding);
  }

  Future<void> warmup() async {
    if (_useNativePlayer) return;

    if (_mediaKitPlayer == null) {
      _initMediaKitPlayer();
    }
  }

  Timer? _debugInfoTimer;

  void _updateDebugInfo() {
    _debugInfoTimer?.cancel();
    _debugInfoTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_mediaKitPlayer == null) return;
      _position = _mediaKitPlayer!.state.position;
      _duration = _mediaKitPlayer!.state.duration;
      notifyListeners();
    });
  }

  Future<void> _initMediaKitPlayer(
      {bool useSoftwareDecoding = false, String bufferStrength = 'fast'}) async {
    _mediaKitPlayer?.dispose();
    _debugInfoTimer?.cancel();
    final prefs = ServiceLocator.prefs;
    final decodingMode = prefs.getString('decoding_mode') ?? 'auto';
    _windowsHwdecMode = prefs.getString('windows_hwdec_mode') ?? 'auto-safe';
    _allowSoftwareFallback = prefs.getBool('allow_software_fallback') ?? true;
    _videoOutput = prefs.getString('video_output') ?? 'auto';
    final effectiveSoftware = useSoftwareDecoding || decodingMode == 'software';
    _isSoftwareDecoding = effectiveSoftware;

    final bufferSize = switch (bufferStrength) {
      'fast' => 32 * 1024 * 1024,
      'balanced' => 64 * 1024 * 1024,
      'stable' => 128 * 1024 * 1024,
      _ => 32 * 1024 * 1024,
    };

    String? vo;
    switch (_videoOutput) {
      case 'gpu':
        vo = 'gpu';
        break;
      case 'libmpv':
        vo = 'libmpv';
        break;
      case 'auto':
      default:
        vo = null;
        break;
    }
    _configuredVo = _videoOutput;

    _mediaKitPlayer = Player(
      configuration: PlayerConfiguration(
        bufferSize: bufferSize,
        vo: vo,
        logLevel: ServiceLocator.log.currentLevel == LogLevel.debug
            ? MPVLogLevel.debug
            : (ServiceLocator.log.currentLevel == LogLevel.off
                ? MPVLogLevel.error
                : MPVLogLevel.info),
        protocolWhitelist: [
          'file', 'http', 'https', 'tcp', 'tls', 
          'crypto', 'hls', 'applehttp', 'udp', 'rtp'
        ],
      ),
    );

    String? hwdecMode;
    if (Platform.isAndroid) {
      hwdecMode = effectiveSoftware ? 'no' : 'mediacodec';
    } else if (Platform.isWindows) {
      if (effectiveSoftware) {
        hwdecMode = 'no';
      } else {
        switch (_windowsHwdecMode) {
          case 'auto-copy':
            hwdecMode = 'auto-copy';
            break;
          case 'd3d11va':
            hwdecMode = 'd3d11va';
            break;
          case 'dxva2':
            hwdecMode = 'dxva2';
            break;
          case 'auto-safe':
          default:
            hwdecMode = 'auto-safe';
            break;
        }
      }
    }

    _configuredHwdec = hwdecMode ?? 'default';

    VideoControllerConfiguration config = VideoControllerConfiguration(
      hwdec: hwdecMode,
      enableHardwareAcceleration: !effectiveSoftware,
    );

    _hwdecMode = effectiveSoftware ? 'no' : _configuredHwdec;
    _vo = vo ?? 'auto';

    _videoController = VideoController(_mediaKitPlayer!, configuration: config);
    _setupMediaKitListeners();
    _updateDebugInfo();

    _initialHwdecSet = false;
    _resetDeinterlaceDetection();
    await _applyDeinterlaceFilter();
  }

  Future<bool> _safeSetProperty(String property, String value, String label) async {
    try {
      final nativePlayer = player?.platform as dynamic;
      await nativePlayer.setProperty(property, value);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<String?> _safeGetProperty(String property, String label) async {
    try {
      final nativePlayer = player?.platform as dynamic;
      return await nativePlayer.getProperty(property);
    } catch (e) {
      return null;
    }
  }

  String _getConfiguredHwdecMode() {
    if (_isSoftwareDecoding) return 'no';
    switch (_windowsHwdecMode) {
      case 'auto-copy':
        return 'auto-copy';
      case 'd3d11va':
        return 'd3d11va';
      case 'dxva2':
        return 'dxva2';
      case 'auto-safe':
      default:
        return 'auto-safe';
    }
  }

  void _resetDeinterlaceDetection() {
    _deinterlaceGeneration++;
    _videoParamsSubscription?.cancel();
    _videoParamsSubscription = null;
    _deinterlaceConfiguredForCurrentStream = false;
  }

  Future<void> _applyDeinterlaceFilter() async {
    if (!Platform.isWindows) return;
    final prefs = ServiceLocator.prefs;
    final enabled = prefs.getBool('deinterlace_enabled') ?? true;

    await _safeSetProperty('video-sync', 'display-resample', 'video-sync');
    await _safeSetProperty('framedrop', 'vo', 'framedrop');
    await _safeSetProperty(
        'protocol-whitelist',
        'udp,rtp,rtsp,tcp,tls,data,file,http,https,crypto',
        'protocol-whitelist');

    if (enabled) {
      if (!_initialHwdecSet) {
        await _safeSetProperty('hwdec', _getConfiguredHwdecMode(), 'hwdec');
        _initialHwdecSet = true;
      }
      await _safeSetProperty('deinterlace', 'no', 'deinterlace');
      await _safeSetProperty('vf', '', 'clear_vf');
    } else {
      await _safeSetProperty('deinterlace', 'no', 'deinterlace');
      await _safeSetProperty('vf', '', 'clear_vf');
      if (!_initialHwdecSet) {
        await _safeSetProperty('hwdec', _getConfiguredHwdecMode(), 'hwdec');
        _initialHwdecSet = true;
      }
      _videoParamsSubscription?.cancel();
      _videoParamsSubscription = null;
      return;
    }

    if (_videoParamsSubscription == null) {
      _deinterlaceConfiguredForCurrentStream = false;
      _videoParamsSubscription = _mediaKitPlayer?.stream.videoParams.listen((params) async {
        final capturedGeneration = _deinterlaceGeneration;
        if (_deinterlaceConfiguredForCurrentStream || params.w == null || params.w! <= 0) return;

        final interlaced = await _safeGetProperty('video-frame-info/interlaced', 'interlaced');
        final vfFpsStr = await _safeGetProperty('estimated-vf-fps', 'vf-fps');
        final vfFps = double.tryParse(vfFpsStr ?? '') ?? 0;

        final srcGamma = await _safeGetProperty('video-params/gamma', 'gamma');
        final srcPrimaries = await _safeGetProperty('video-params/primaries', 'primaries');

        if (srcGamma == null || srcGamma.isEmpty || srcPrimaries == null || srcPrimaries.isEmpty) {
          return;
        }

        if (capturedGeneration != _deinterlaceGeneration) {
          return;
        }

        _deinterlaceConfiguredForCurrentStream = true;

        final codec = await _safeGetProperty('video-params/codec', 'codec');

        final h = params.h ?? 0;
        final w = params.w ?? 0;
        final isInterlaced = interlaced == '1';

        final is1080i = (h == 1080 && isInterlaced) ||
                        (h == 1080 && vfFps < 31 && interlaced != '0') ||
                        (codec == 'h264' && h == 1080 && w == 1920);
        final isHDR = srcPrimaries == 'bt.2020' &&
                      (srcGamma == 'pq' || srcGamma == 'hlg');

        if (isHDR) {
          if (srcGamma == 'hlg') {
            await _safeSetProperty('hdr-compute-peak', 'yes', 'hdr-compute-peak');
          } else {
            await _safeSetProperty('target-prim', 'bt.709', 'target-prim');
            await _safeSetProperty('target-trc', 'bt.1886', 'target-trc');
            await _safeSetProperty('tone-mapping', 'bt.2390', 'tone-mapping');
            await _safeSetProperty('tone-mapping-param', 'default', 'tone-mapping-param');
            await _safeSetProperty('hdr-compute-peak', 'yes', 'hdr-compute-peak');
            await _safeSetProperty('target-peak', '100', 'target-peak');
          }
        } else {
          await _safeSetProperty('target-prim', 'auto', 'target-prim');
          await _safeSetProperty('target-trc', 'auto', 'target-trc');
          await _safeSetProperty('hdr-compute-peak', 'no', 'hdr-compute-peak');
        }

        if (is1080i && !_isSoftwareDecoding) {
          await _safeSetProperty('deinterlace', 'no', 'deinterlace');

          const filters = [
            'bwdif=mode=1:parity=tff',
            'yadif=mode=1:parity=tff',
            'lavfi:yadif=mode=1:parity=tff',
          ];

          String? workingFilter;

          for (final vf in filters) {
            await _safeSetProperty('vf', '', 'clear_vf');
            final success = await _safeSetProperty('vf', vf, 'try_vf');
            if (success) {
              final currentVf = await _safeGetProperty('vf', 'verify_vf');
              if (currentVf != null && currentVf.isNotEmpty) {
                workingFilter = vf;
                break;
              }
            }
          }

          if (workingFilter == null) {
            await _safeSetProperty('hwdec', 'd3d11va-copy', 'hwdec_1080i');
            for (int retry = 0; retry < 5 && workingFilter == null; retry++) {
              await Future.delayed(const Duration(milliseconds: 50));
              for (final vf in filters) {
                await _safeSetProperty('vf', '', 'clear_vf');
                final success = await _safeSetProperty('vf', vf, 'try_vf');
                if (success) {
                  final currentVf = await _safeGetProperty('vf', 'verify_vf');
                  if (currentVf != null && currentVf.isNotEmpty) {
                    workingFilter = vf;
                    break;
                  }
                }
              }
            }
          }

          if (workingFilter == null) {
            await _safeSetProperty('vf', '', 'clear_vf');
            await _safeSetProperty('hwdec', _getConfiguredHwdecMode(), 'hwdec');
            await _safeSetProperty('deinterlace', 'yes', 'deinterlace');
          }
        } else {
          await _safeSetProperty('hwdec', _getConfiguredHwdecMode(), 'hwdec_progressive');
          await _safeSetProperty('deinterlace', 'no', 'deinterlace');
          await _safeSetProperty('vf', '', 'clear_vf');
        }
      });
    }
  }

  void _setupMediaKitListeners() {
    if (_mediaKitPlayer == null) return;

    _mediaKitPlayer!.stream.log.listen((log) {
      final message = log.text.toLowerCase();

      if (message.contains('sei type') ||
          message.contains('truncated at') ||
          message.contains('mmco') ||
          message.contains('reference frames') ||
          message.contains('exceeds max') ||
          message.contains('discarding one') ||
          message.contains('deprecated pixel format') ||
          message.contains("skip ('#ext") ||
          (message.contains('hls @') && message.contains('skip')) ||
          message.contains('no such filter') ||
          message.contains('error creating filters')) {
        return;
      }

      if (ServiceLocator.log.currentLevel != LogLevel.off) {
        ServiceLocator.log.d('MPV log: ${log.text}', tag: 'PlayerProvider');
      }
    });

    _mediaKitPlayer!.stream.error.listen((error) {
      ServiceLocator.log.e('MediaKit error: $error', tag: 'PlayerProvider');
      _setError(error.toString());
    });

    _mediaKitPlayer!.stream.playing.listen((playing) {
      if (playing) {
        _state = PlayerState.playing;
        _retryCount = 0;
      } else if (_state == PlayerState.playing) {
        _state = PlayerState.paused;
      }
      notifyListeners();
    });

    _mediaKitPlayer!.stream.buffering.listen((buffering) {
      if (buffering && _state == PlayerState.playing) {
        _state = PlayerState.buffering;
        notifyListeners();
      } else if (!buffering && _state == PlayerState.buffering) {
        _state = PlayerState.playing;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    _debugInfoTimer?.cancel();
    _retryTimer?.cancel();
    _videoParamsSubscription?.cancel();
    _mediaKitPlayer?.dispose();
    super.dispose();
  }
}
