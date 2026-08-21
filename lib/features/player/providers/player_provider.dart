import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'package:intl/intl.dart';

import '../../../core/models/channel.dart';
import '../../../core/platform/platform_detector.dart';
import '../../../core/services/service_locator.dart';
import '../../../core/services/channel_test_service.dart';
import '../../../core/services/log_service.dart';
import '../../../core/services/epg_service.dart';
import '../../settings/providers/settings_provider.dart';

enum PlayerState {
  idle,
  loading,
  playing,
  paused,
  error,
  buffering,
}

class CatchupUrlResult {
  final String url;
  final String? startTime;
  final String? endTime;

  CatchupUrlResult({required this.url, this.startTime, this.endTime});
}

class PlayerProvider extends ChangeNotifier {
  Player? _mediaKitPlayer;
  VideoController? _videoController;

  Channel? _currentChannel;
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
  static const int _maxRetries = 2;
  Timer? _retryTimer;
  bool _isAutoSwitching = false;
  bool _isAutoDetecting = false;
  bool _isSoftwareDecoding = false;
  bool _noVideoFallbackAttempted = false;
  bool _allowSoftwareFallback = true;
  String _windowsHwdecMode = 'auto-safe';
  bool _isDisposed = false;
  StreamSubscription<VideoParams>? _videoParamsSubscription;
  bool _deinterlaceConfiguredForCurrentStream = false;
  bool _initialHwdecSet = false;
  int _deinterlaceGeneration = 0;
  String _videoOutput = 'auto';
  String _vo = 'unknown';
  String _configuredVo = 'auto';

  Duration? _overrideDuration;

  bool get _useNativePlayer => Platform.isAndroid && PlatformDetector.isTV;

  Player? get player => _mediaKitPlayer;
  VideoController? get videoController => _videoController;
  Channel? get currentChannel => _currentChannel;
  PlayerState get state => _state;
  String? get error => _error;
  Duration get position => _position;
  Duration get duration {
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
  bool get isLoading => _state == PlayerState.loading || _state == PlayerState.buffering;
  bool get hasError => _state == PlayerState.error && _error != null;

  Media _createMedia(String url) {
    final userAgent = ServiceLocator.settings?.userAgent ?? SettingsProvider.defaultUserAgent;
    ServiceLocator.log.d('PlayerProvider: 创建Media对象 User-Agent: $userAgent');
    return Media(url, httpHeaders: {'User-Agent': userAgent});
  }

  bool get isSeekable {
    if (_currentChannel?.isLive == true) return false;
    if (_currentChannel?.isSeekable == true) {
      if (_currentChannel?.type == ChannelType.replay) return true;
      if (_duration.inSeconds > 0 && _duration.inSeconds <= 86400) return true;
    }
    if (_duration.inSeconds > 0 && _duration.inSeconds <= 86400) {
      if (_currentChannel?.isLive != true) return true;
    }
    return false;
  }

  bool shouldShowProgressBar(String progressBarMode) {
    if (progressBarMode == 'never') return false;
    if (_overrideDuration != null) return true;
    if (progressBarMode == 'always') return _duration.inSeconds > 0;
    return isSeekable && _duration.inSeconds > 0;
  }

  void setOverrideDuration(Duration? duration) {
    _overrideDuration = duration;
    notifyListeners();
  }

  bool get isLiveStream => !isSeekable;

  void clearError() {
    _error = null;
    _errorDisplayed = true;
    if (_state == PlayerState.error) {
      _state = PlayerState.idle;
    }
    notifyListeners();
  }

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
      ServiceLocator.log.d('PlayerProvider: Ignore audio decode warning');
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
      ServiceLocator.log
          .d('PlayerProvider: 当前源索引: $currentSourceIndex, 总源数: $totalSources');
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
    if (_errorDisplayed) return;
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
      ServiceLocator.log.d(
          'PlayerProvider: 源 ${nextIndex + 1} 不可用: ${result.error}，继续尝试下一个源');
      final totalSources = _currentChannel!.sourceCount;
      final nextNextIndex = nextIndex + 1;
      if (nextNextIndex < totalSources) {
        _checkAndSwitchToNextSource(nextNextIndex, originalError);
      } else {
        ServiceLocator.log.d('PlayerProvider: 已到最后一个源，所有源都不可用');
        _isAutoDetecting = false;
        _state = PlayerState.error;
        _error = '所有 $totalSources 个源都不可用';
        notifyListeners();
      }
      return;
    }

    ServiceLocator.log.d(
        'PlayerProvider: Source ${nextIndex + 1} is available (${result.responseTime}ms), switching');
    _isAutoDetecting = false;
    _retryCount = 0;
    _isAutoSwitching = true;
    _lastErrorMessage = null;
    _playCurrentSource();
    _isAutoSwitching = false;
  }

  Future<void> _retryPlayback() async {
    if (_currentChannel == null) return;

    ServiceLocator.log.d(
        'PlayerProvider: 正在重试播放 ${_currentChannel!.name}, 当前源索引: ${_currentChannel!.currentSourceIndex}, 重试计数: $_retryCount');
    final startTime = DateTime.now();

    _state = PlayerState.loading;
    _error = null;
    notifyListeners();

    final url = _currentChannel!.currentUrl;
    ServiceLocator.log.d('PlayerProvider: 重试URL: $url');

    try {
      if (!_useNativePlayer) {
        ServiceLocator.log
            .i('>>> Retry: start resolving redirect', tag: 'PlayerProvider');

        // ---- 使用新的 _resolveWithRrsip 内部已处理重定向 ----
        final rrsipUrl = await _resolveWithRrsip(url);
        final realUrl = rrsipUrl ?? url; // fallback 到原始 URL

        ServiceLocator.log.d('>>> 重试: 使用播放地址: $realUrl', tag: 'PlayerProvider');

        // 清除可能的 start/end 残留
        await _clearStartEndProperties();

        final playStartTime = DateTime.now();
        await _applyDeinterlaceFilter();
        await _mediaKitPlayer?.open(_createMedia(realUrl));

        final playTime = DateTime.now().difference(playStartTime).inMilliseconds;
        final totalTime = DateTime.now().difference(startTime).inMilliseconds;
        ServiceLocator.log
            .i('>>> 重试: 播放器初始化完成，耗时: ${playTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log
            .i('>>> 重试: 总耗时: ${totalTime}ms', tag: 'PlayerProvider');

        _state = PlayerState.playing;
      }
      ServiceLocator.log.d('PlayerProvider: Retry command sent');
    } catch (e) {
      final totalTime = DateTime.now().difference(startTime).inMilliseconds;
      ServiceLocator.log.d('PlayerProvider: 重试失败 (${totalTime}ms): $e');
      _setError('Failed to play channel: $e');
    }
    notifyListeners();
  }

  // ---------- 辅助方法：清除 start/end 属性 ----------
  Future<void> _clearStartEndProperties() async {
    if (_mediaKitPlayer == null || _useNativePlayer) return;
    try {
      final nativePlayer = _mediaKitPlayer!.platform as dynamic;
      await nativePlayer.setProperty('start', 'none');
      await nativePlayer.setProperty('end', 'none');
      ServiceLocator.log.d('已重置 start/end 属性为 none');
    } catch (e) {
      // 忽略错误
    }
  }

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

  double get currentFps => _currentFps;
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;
  double get downloadSpeed => _downloadSpeed;

  String get videoInfo {
    if (_mediaKitPlayer == null) return '';
    final w = _mediaKitPlayer!.state.width;
    final h = _mediaKitPlayer!.state.height;
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

  double get progress {
    if (_duration.inMilliseconds == 0) return 0;
    return _position.inMilliseconds / _duration.inMilliseconds;
  }

  PlayerProvider() {
    _initPlayer();
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
      ServiceLocator.log
          .d('PlayerProvider: 预热播放器 - 初始化 media_kit', tag: 'PlayerProvider');
      _initMediaKitPlayer();
    }
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

    ServiceLocator.log.i('========== 初始化播放器 ==========', tag: 'PlayerProvider');
    ServiceLocator.log
        .i('平台: ${Platform.operatingSystem}', tag: 'PlayerProvider');
    ServiceLocator.log.i('软解码模式: $useSoftwareDecoding', tag: 'PlayerProvider');
    ServiceLocator.log.i('缓冲强度: $bufferStrength', tag: 'PlayerProvider');

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
    ServiceLocator.log.i('硬件解码模式: ${hwdecMode ?? "默认"}', tag: 'PlayerProvider');
    ServiceLocator.log
        .i('硬件加速: ${!effectiveSoftware}', tag: 'PlayerProvider');

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

    ServiceLocator.log.i('播放器初始化完成', tag: 'PlayerProvider');
  }

  Future<bool> _safeSetProperty(String property, String value, String label) async {
    try {
      final nativePlayer = player?.platform as dynamic;
      await nativePlayer.setProperty(property, value);
      return true;
    } catch (e) {
      ServiceLocator.log.d('设置 $label 失败: $e', tag: 'PlayerProvider');
      return false;
    }
  }

  Future<String?> _safeGetProperty(String property, String label) async {
    try {
      final nativePlayer = player?.platform as dynamic;
      return await nativePlayer.getProperty(property);
    } catch (e) {
      ServiceLocator.log.d('读取 $label 失败: $e', tag: 'PlayerProvider');
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
      ServiceLocator.log.i('去交错已禁用', tag: 'PlayerProvider');
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
          ServiceLocator.log.d(
              '色彩空间信息尚未就绪 (gamma=$srcGamma, primaries=$srcPrimaries)，延迟到下次 videoParams 事件配置',
              tag: 'PlayerProvider');
          return;
        }

        if (capturedGeneration != _deinterlaceGeneration) {
          ServiceLocator.log.d('videoParams 回调已过时（代际变化），忽略', tag: 'PlayerProvider');
          return;
        }

        _deinterlaceConfiguredForCurrentStream = true;

        final sigPeak = await _safeGetProperty('video-params/sig-peak', 'sig-peak');
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
            ServiceLocator.log.i(
                'HDR 源(HLG): mpv 默认 HLG→SDR 转换 (gamma=$srcGamma, primaries=$srcPrimaries)',
                tag: 'PlayerProvider');
          } else {
            await _safeSetProperty('target-prim', 'bt.709', 'target-prim');
            await _safeSetProperty('target-trc', 'bt.1886', 'target-trc');
            await _safeSetProperty('tone-mapping', 'bt.2390', 'tone-mapping');
            await _safeSetProperty('tone-mapping-param', 'default', 'tone-mapping-param');
            await _safeSetProperty('hdr-compute-peak', 'yes', 'hdr-compute-peak');
            await _safeSetProperty('target-peak', '100', 'target-peak');
            ServiceLocator.log.i(
                'HDR 源(PQ/HDR10): 色调映射到 SDR (gamma=$srcGamma, primaries=$srcPrimaries, sig-peak=$sigPeak)',
                tag: 'PlayerProvider');
          }
        } else {
          await _safeSetProperty('target-prim', 'auto', 'target-prim');
          await _safeSetProperty('target-trc', 'auto', 'target-trc');
          await _safeSetProperty('hdr-compute-peak', 'no', 'hdr-compute-peak');
          ServiceLocator.log.i(
              'SDR 源: 标准输出 (gamma=$srcGamma, primaries=$srcPrimaries)',
              tag: 'PlayerProvider');
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
                ServiceLocator.log.i(
                    '1080i: 软件滤镜 $vf (hwdec=d3d11va-copy)',
                    tag: 'PlayerProvider');
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
                    ServiceLocator.log.i(
                        '1080i: 软件滤镜 $vf (hwdec=d3d11va-copy, 第二轮)',
                        tag: 'PlayerProvider');
                    break;
                  }
                }
              }
            }
          }

          if (workingFilter == null) {
            ServiceLocator.log.i(
                '1080i: 软件滤镜不可用，退回硬件去交错 (deinterlace=yes)',
                tag: 'PlayerProvider');
            await _safeSetProperty('vf', '', 'clear_vf');
            await _safeSetProperty('hwdec', _getConfiguredHwdecMode(), 'hwdec');
            await _safeSetProperty('deinterlace', 'yes', 'deinterlace');
          }
        } else {
          await _safeSetProperty('hwdec', _getConfiguredHwdecMode(), 'hwdec_progressive');
          await _safeSetProperty('deinterlace', 'no', 'deinterlace');
          await _safeSetProperty('vf', '', 'clear_vf');
          final label = h > 0 ? '${h}p 逐行源' : '源（默认按逐行处理）';
          final currentHwdec = _isSoftwareDecoding ? '软解(no)' : _getConfiguredHwdecMode();
          ServiceLocator.log.i('$label: $currentHwdec 硬解, 无去交错', tag: 'PlayerProvider');
        }
      });
    }
  }

  void _setupMediaKitListeners() {
    ServiceLocator.log.d('设置播放器监听器', tag: 'PlayerProvider');

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

      if (message.contains('using hardware decoding') ||
          message.contains('software decoding') ||
          message.contains('hwdec') ||
          message.contains('video output driver') ||
          message.contains('vo:')) {
        final hwdecBefore = _hwdecMode;
        final voBefore = _vo;
        _updateHwdecFromLog(message);
        _updateVoFromLog(message);
        if (_hwdecMode != hwdecBefore || _vo != voBefore) {
          ServiceLocator.log.i(
              '[Decoder] hwdec: $_hwdecMode, vo: $_vo (${log.text})',
              tag: 'PlayerProvider');
        }
      }

      if (log.level == 'error') {
        ServiceLocator.log.e('MPV错误: ${log.text}', tag: 'PlayerProvider');
      } else if (log.level == 'warn') {
        ServiceLocator.log.w('MPV警告: ${log.text}', tag: 'PlayerProvider');
      }
    });

    _mediaKitPlayer!.stream.playing.listen((playing) {
      ServiceLocator.log.d('播放状态变化: playing=$playing', tag: 'PlayerProvider');
      if (playing) {
        _state = PlayerState.playing;
        Future.delayed(const Duration(seconds: 3), () {
          if (_state == PlayerState.playing && _currentChannel != null) {
            ServiceLocator.log
                .d('PlayerProvider: Playback stable, reset retry count');
            _retryCount = 0;
          }
        });
      } else if (_state == PlayerState.playing) {
        _state = PlayerState.paused;
      }
      notifyListeners();
    });

    _mediaKitPlayer!.stream.buffering.listen((buffering) {
      ServiceLocator.log.d('缓冲状态: buffering=$buffering', tag: 'PlayerProvider');
      if (buffering &&
          _state != PlayerState.idle &&
          _state != PlayerState.error) {
        _state = PlayerState.buffering;
      } else if (!buffering && _state == PlayerState.buffering) {
        _state = _mediaKitPlayer!.state.playing
            ? PlayerState.playing
            : PlayerState.paused;
      }
      notifyListeners();
    });

    _mediaKitPlayer!.stream.position.listen((pos) {
      _position = pos;
      notifyListeners();
    });

    _mediaKitPlayer!.stream.duration.listen((dur) {
      _duration = dur;
      notifyListeners();
    });

    _mediaKitPlayer!.stream.tracks.listen((tracks) {
      ServiceLocator.log.d(
          '轨道信息更新: 视频轨:${tracks.video.length}, 音频轨:${tracks.audio.length}',
          tag: 'PlayerProvider');

      for (final track in tracks.video) {
        if (track.codec != null) {
          _videoCodec = track.codec!;
          ServiceLocator.log.i('视频编码: ${track.codec}', tag: 'PlayerProvider');
        }
        if (track.fps != null) {
          _fps = track.fps!;
          ServiceLocator.log
              .i('视频帧率: ${track.fps} fps', tag: 'PlayerProvider');
        }
        if (track.w != null && track.h != null) {
          ServiceLocator.log
              .i('视频分辨率: ${track.w}x${track.h}', tag: 'PlayerProvider');
        }
      }

      for (final track in tracks.audio) {
        if (track.codec != null) {
          _audioCodec = track.codec!;
          ServiceLocator.log.i('音频编码: ${track.codec}', tag: 'PlayerProvider');
        }
      }

      notifyListeners();
    });

    _mediaKitPlayer!.stream.volume.listen((vol) {
      _volume = vol / 100;
      notifyListeners();
    });

    _mediaKitPlayer!.stream.error.listen((err) {
      if (err.isNotEmpty) {
        ServiceLocator.log.e('播放器错误: $err', tag: 'PlayerProvider');

        if (err.toLowerCase().contains('decode') ||
            err.toLowerCase().contains('decoder')) {
          ServiceLocator.log.e('>>> 解码错误: $err', tag: 'PlayerProvider');
        } else if (err.toLowerCase().contains('render') ||
            err.toLowerCase().contains('display')) {
          ServiceLocator.log.e('>>> 网络错误: $err', tag: 'PlayerProvider');
        } else if (err.toLowerCase().contains('hwdec') ||
            err.toLowerCase().contains('hardware')) {
          ServiceLocator.log.e('>>> 硬件加速错误: $err', tag: 'PlayerProvider');
        } else if (err.toLowerCase().contains('codec')) {
          ServiceLocator.log.e('>>> 解码器错误: $err', tag: 'PlayerProvider');
        }

        if (_shouldTrySoftwareFallback(err)) {
          ServiceLocator.log.w('尝试软件回退', tag: 'PlayerProvider');
          _attemptSoftwareFallback();
        } else {
          _setError(err);
        }
      }
    });

    _mediaKitPlayer!.stream.width.listen((width) {
      if (width != null && width > 0) {
        ServiceLocator.log.d('视频宽度: $width', tag: 'PlayerProvider');
      }
      notifyListeners();
    });

    _mediaKitPlayer!.stream.height.listen((height) {
      if (height != null && height > 0) {
        ServiceLocator.log.d('视频高度: $height', tag: 'PlayerProvider');
      }
      notifyListeners();
    });
  }

  Timer? _debugInfoTimer;

  void _updateDebugInfo() {
    _debugInfoTimer?.cancel();

    _debugInfoTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_mediaKitPlayer == null) return;

      if (ServiceLocator.log.currentLevel == LogLevel.off &&
          (_hwdecMode == 'unknown' || _hwdecMode.isEmpty)) {
        _hwdecMode = _configuredHwdec;
      }

      _safeGetProperty('hwdec-current', 'hwdec-current').then((current) {
        if (current != null && current.isNotEmpty && current != _hwdecMode) {
          _hwdecMode = current;
          notifyListeners();
        }
      });

      _safeGetProperty('audio-params/codec', 'audio-codec').then((codec) {
        if (codec != null && codec.isNotEmpty && codec != _audioCodec) {
          _audioCodec = codec;
          notifyListeners();
        }
      });
      _safeGetProperty('audio-params/channels', 'audio-channels').then((ch) {
        final chCount = _parseChannelCount(ch ?? '');
        if (chCount > 0 && chCount != _audioChannels) {
          _audioChannels = chCount;
          notifyListeners();
        }
      });

      final newWidth = _mediaKitPlayer!.state.width ?? 0;
      final newHeight = _mediaKitPlayer!.state.height ?? 0;

      if (newWidth != _videoWidth || newHeight != _videoHeight) {
        if (newWidth > 0 && newHeight > 0) {
          ServiceLocator.log.i('视频解码成功: ${newWidth}x$newHeight',
              tag: 'PlayerProvider');
        } else if (_videoWidth > 0 && newWidth == 0) {
          ServiceLocator.log.w('视频解码失败', tag: 'PlayerProvider');
        }
      }

      _videoWidth = newWidth;
      _videoHeight = newHeight;

      if (_state == PlayerState.playing && _fps > 0) {
        _currentFps = _fps;
      } else {
        _currentFps = 0;
      }

      if (_state == PlayerState.playing) {
        _safeGetProperty('video-bitrate', 'video-bitrate').then((v) {
          _safeGetProperty('audio-bitrate', 'audio-bitrate').then((a) {
            final vBps = double.tryParse(v ?? '');
            final aBps = double.tryParse(a ?? '');
            if (vBps != null && vBps > 0) {
              _downloadSpeed = (vBps + (aBps ?? 0)) / 8;
            } else {
              _fallbackBitrateEstimate();
            }
          });
        });
      } else {
        _downloadSpeed = 0;
      }

      notifyListeners();
    });
  }

  void _fallbackBitrateEstimate() {
    if (_videoWidth <= 0 || _videoHeight <= 0) {
      _downloadSpeed = 0;
      return;
    }
    final pixels = _videoWidth * _videoHeight;
    final fps = _fps > 0 ? _fps : 25.0;
    double compressionFactor;
    if (pixels >= 3840 * 2160) {
      compressionFactor = 0.04;
    } else if (pixels >= 1920 * 1080) {
      compressionFactor = 0.06;
    } else if (pixels >= 1280 * 720) {
      compressionFactor = 0.08;
    } else {
      compressionFactor = 0.10;
    }
    final estimatedBitrate = pixels * fps * compressionFactor;
    _downloadSpeed = estimatedBitrate / 8.0;
  }

  int _parseChannelCount(String layout) {
    if (layout.isEmpty) return 0;
    final match = RegExp(r'(\d+)').firstMatch(layout);
    if (match != null) {
      final count = int.tryParse(match.group(1)!);
      if (count != null && count > 0) return count;
    }
    switch (layout.toLowerCase()) {
      case 'mono':
        return 1;
      case 'stereo':
        return 2;
      case 'quad':
        return 4;
      case 'surround':
        return 5;
    }
    return 0;
  }

  void _updateHwdecFromLog(String lowerMessage) {
    String? detected;
    final hwdecMatch = RegExp(r'using hardware decoding\s*\(([^)]+)\)')
        .firstMatch(lowerMessage);
    if (hwdecMatch != null) {
      detected = hwdecMatch.group(1);
    }
    final hwdecKeyMatch = RegExp(r'hwdec(?:-current)?\s*[:=]\s*([\w\-]+)')
        .firstMatch(lowerMessage);
    if (detected == null && hwdecKeyMatch != null) {
      detected = hwdecKeyMatch.group(1);
    }
    if (detected == null && lowerMessage.contains('software decoding')) {
      detected = 'no';
    }
    if (detected != null && detected.isNotEmpty && detected != _hwdecMode) {
      _hwdecMode = detected;
      notifyListeners();
    }
  }

  void _updateVoFromLog(String lowerMessage) {
    String? detected;
    final voMatch =
        RegExp(r'vo:\s*\[?([a-z0-9_\-]+)\]?').firstMatch(lowerMessage);
    if (voMatch != null) {
      detected = voMatch.group(1);
    }
    final driverMatch = RegExp(r'video output driver:\s*([a-z0-9_\-]+)')
        .firstMatch(lowerMessage);
    if (detected == null && driverMatch != null) {
      detected = driverMatch.group(1);
    }
    if (detected != null && detected.isNotEmpty && detected != _vo) {
      _vo = detected;
      notifyListeners();
    }
  }

  String _formatHwdecInfo() {
    final configured = _configuredHwdec.trim();
    final actual = _hwdecMode.trim();
    if (configured.isEmpty || configured == 'unknown') {
      return actual == 'unknown' ? '' : actual;
    }
    if (actual.isEmpty || actual == 'unknown' || actual == configured) {
      return configured;
    }
    return '$configured -> $actual';
  }

  String _formatVoInfo() {
    final configured = _configuredVo.trim();
    final actual = _vo.trim();
    if (configured.isEmpty || configured == 'unknown') {
      return actual == 'unknown' ? '' : actual;
    }
    if (actual.isEmpty || actual == 'unknown' || actual == configured) {
      return configured;
    }
    return '$configured -> $actual';
  }

  bool _shouldTrySoftwareFallback(String error) {
    final lowerError = error.toLowerCase();
    if (!_allowSoftwareFallback) return false;
    return (lowerError.contains('codec') ||
            lowerError.contains('decoder') ||
            lowerError.contains('hwdec') ||
            lowerError.contains('mediacodec')) &&
        _retryCount < _maxRetries;
  }

  void _attemptSoftwareFallback() {
    if (!_allowSoftwareFallback) return;
    _retryCount++;
    final channelToPlay = _currentChannel;
    _initMediaKitPlayer(useSoftwareDecoding: true);
    if (channelToPlay != null) playChannel(channelToPlay);
  }

  // ============ Public API ============
  Future<void> playChannel(Channel channel,
      {bool preserveCurrentSource = false}) async {
    // 彻底停止当前播放，重置状态
    if (_mediaKitPlayer != null && !_useNativePlayer) {
      ServiceLocator.log.d('playChannel: 停止当前播放');
      await _mediaKitPlayer?.stop();
      await _clearStartEndProperties();
      // 重置回放相关
      _originalChannel = null;
      _currentCatchupProgram = null;
      _overrideDuration = null;
    }
  
    // 重置所有状态
    _state = PlayerState.idle;
    _error = null;
    _lastErrorMessage = null;
    _errorDisplayed = false;
    _retryCount = 0;
    _retryTimer?.cancel();
    _isAutoDetecting = false;
    _noVideoFallbackAttempted = false;
    _resetDeinterlaceDetection();
    
    ServiceLocator.log
        .i('========== 开始播放频道==========', tag: 'PlayerProvider');
    ServiceLocator.log
        .i('频道: ${channel.name} (ID: ${channel.id})', tag: 'PlayerProvider');
    ServiceLocator.log.d('URL: ${channel.url}', tag: 'PlayerProvider');
    ServiceLocator.log.d('源数量 ${channel.sourceCount}', tag: 'PlayerProvider');
    final playStartTime = DateTime.now();

    _currentChannel = channel;
    _state = PlayerState.loading;
    _error = null;
    _lastErrorMessage = null;
    _errorDisplayed = false;
    _retryCount = 0;
    _retryTimer?.cancel();
    _isAutoDetecting = false;
    _noVideoFallbackAttempted = false;
    _resetDeinterlaceDetection();
    loadVolumeSettings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notifyListeners();
    });

    if (channel.hasMultipleSources && !preserveCurrentSource) {
      ServiceLocator.log
          .i('频道有 ${channel.sourceCount} 个源，开始检测可用源', tag: 'PlayerProvider');
      final detectStartTime = DateTime.now();
      final availableSourceIndex = await _findFirstAvailableSource(channel);
      final detectTime =
          DateTime.now().difference(detectStartTime).inMilliseconds;
      if (availableSourceIndex != null) {
        channel.currentSourceIndex = availableSourceIndex;
        ServiceLocator.log.i(
            '找到可用源 ${availableSourceIndex + 1}/${channel.sourceCount}，检测耗时: ${detectTime}ms',
            tag: 'PlayerProvider');
      } else {
        ServiceLocator.log.e(
            '所有 ${channel.sourceCount} 个源都不可用，检测耗时: ${detectTime}ms',
            tag: 'PlayerProvider');
        _setError('所有 ${channel.sourceCount} 个源均不可用');
        return;
      }
    } else if (channel.hasMultipleSources) {
      channel.currentSourceIndex =
          channel.currentSourceIndex.clamp(0, channel.sourceCount - 1);
      ServiceLocator.log.d(
          'PlayerProvider: preserveCurrentSource=true, using source ${channel.currentSourceIndex + 1}/${channel.sourceCount}');
    }

    final playUrl = channel.currentUrl;
    ServiceLocator.log.d('准备播放URL: $playUrl', tag: 'PlayerProvider');

    try {
      final playerInitStartTime = DateTime.now();

      if (!_useNativePlayer) {
        ServiceLocator.log
            .i('>>> 尝试 rrsip 转换', tag: 'PlayerProvider');
        final rrsipUrl = await _resolveWithRrsip(playUrl);
        final realUrl = rrsipUrl ?? playUrl; // fallback

        ServiceLocator.log.d('>>> 使用播放地址: $realUrl', tag: 'PlayerProvider');

        // 清除 start/end 残留
        await _clearStartEndProperties();

        ServiceLocator.log
            .i('>>> Start initializing player', tag: 'PlayerProvider');
        final playStartTime = DateTime.now();
        await _applyDeinterlaceFilter();
        await _mediaKitPlayer?.open(_createMedia(realUrl));

        final playTime =
            DateTime.now().difference(playStartTime).inMilliseconds;
        ServiceLocator.log
            .i('>>> 播放器初始化完成，耗时: ${playTime}ms', tag: 'PlayerProvider');
        _state = PlayerState.playing;
        notifyListeners();
        _scheduleNoVideoFallbackIfNeeded();
      }

      final channelId = channel.id;
      final playlistId = channel.playlistId;
      if (channelId != null) {
        await ServiceLocator.watchHistory
            .addWatchHistory(channelId, playlistId);
      }

      final playerInitTime =
          DateTime.now().difference(playerInitStartTime).inMilliseconds;
      final totalTime = DateTime.now().difference(playStartTime).inMilliseconds;
      ServiceLocator.log.i(
          '>>> 播放流程总耗时: ${totalTime}ms (播放器初始化: ${playerInitTime}ms)',
          tag: 'PlayerProvider');
      ServiceLocator.log.i('========== 频道播放总耗时: ${totalTime}ms ==========',
          tag: 'PlayerProvider');
    } catch (e) {
      ServiceLocator.log.e('播放频道失败', tag: 'PlayerProvider', error: e);
      _setError('Failed to play channel: $e');
      return;
    }
  }

  Future<void> reinitializePlayer({required String bufferStrength}) async {
    if (_useNativePlayer) return;
    final channelToPlay = _currentChannel;
    _state = PlayerState.loading;
    notifyListeners();
    _initMediaKitPlayer(bufferStrength: bufferStrength);
    if (channelToPlay != null) {
      await playChannel(channelToPlay);
    }
  }

  Future<int?> _findFirstAvailableSource(Channel channel) async {
    ServiceLocator.log
        .d('开始检测第${channel.sourceCount} 个源', tag: 'PlayerProvider');
    final testService = ChannelTestService();

    for (int i = 0; i < channel.sourceCount; i++) {
      channel.currentSourceIndex = i;
      notifyListeners();

      final tempChannel = Channel(
        id: channel.id,
        name: channel.name,
        url: channel.sources[i],
        groupName: channel.groupName,
        logoUrl: channel.logoUrl,
        sources: [channel.sources[i]],
        playlistId: channel.playlistId,
      );

      ServiceLocator.log
          .d('检测源 ${i + 1}/${channel.sourceCount}', tag: 'PlayerProvider');
      final testStartTime = DateTime.now();

      final result = await testService.testChannel(tempChannel);
      final testTime = DateTime.now().difference(testStartTime).inMilliseconds;

      if (result.isAvailable) {
        ServiceLocator.log.i(
            '源${i + 1} 可用，响应时间: ${result.responseTime}ms，检测耗时: ${testTime}ms',
            tag: 'PlayerProvider');
        return i;
      } else {
        ServiceLocator.log.w(
            '✗ 源 ${i + 1} 不可用: ${result.error}，检测耗时: ${testTime}ms',
            tag: 'PlayerProvider');
      }
    }

    ServiceLocator.log
        .e('所有${channel.sourceCount} 个源都不可用', tag: 'PlayerProvider');
    return null;
  }

  Future<void> playUrl(String url, {String? name}) async {
    if (_useNativePlayer) {
      ServiceLocator.log
          .w('playUrl: Android TV 使用原生播放器，不支持此方法', tag: 'PlayerProvider');
      return;
    }

    final startTime = DateTime.now();
    _state = PlayerState.loading;
    _error = null;
    _lastErrorMessage = null;
    _errorDisplayed = false;
    _noVideoFallbackAttempted = false;
    _resetDeinterlaceDetection();
    loadVolumeSettings();
    notifyListeners();

    try {
      ServiceLocator.log
          .i('>>> 尝试 rrsip 转换', tag: 'PlayerProvider');
      final rrsipUrl = await _resolveWithRrsip(url);
      final realUrl = rrsipUrl ?? url;

      ServiceLocator.log.d('>>> 使用播放地址: $realUrl', tag: 'PlayerProvider');

      await _clearStartEndProperties();

      ServiceLocator.log
          .i('>>> Start initializing player', tag: 'PlayerProvider');
      final playStartTime = DateTime.now();
      await _applyDeinterlaceFilter();
      await _mediaKitPlayer?.open(_createMedia(realUrl));

      final playTime = DateTime.now().difference(playStartTime).inMilliseconds;
      final totalTime = DateTime.now().difference(startTime).inMilliseconds;
      ServiceLocator.log
          .i('>>> 播放器初始化完成，耗时: ${playTime}ms', tag: 'PlayerProvider');
      ServiceLocator.log
          .i('>>> 播放流程总耗时: ${totalTime}ms', tag: 'PlayerProvider');

      _state = PlayerState.playing;
      _scheduleNoVideoFallbackIfNeeded();
    } catch (e) {
      final totalTime = DateTime.now().difference(startTime).inMilliseconds;
      ServiceLocator.log
          .e('>>> 播放失败 (${totalTime}ms): $e', tag: 'PlayerProvider');
      _setError('Failed to play: $e');
      return;
    }
    notifyListeners();
  }

  void togglePlayPause() {
    if (_useNativePlayer) return;
    _mediaKitPlayer?.playOrPause();
  }

  void pause() {
    if (_useNativePlayer) return;
    _mediaKitPlayer?.pause();
  }

  void play() {
    if (_useNativePlayer) return;
    _mediaKitPlayer?.play();
  }

  Future<void> stop({bool silent = false}) async {
    _state = PlayerState.idle;
    _error = null;
    _overrideDuration = null;
    _retryCount = 0;
    _retryTimer?.cancel();
    _isAutoDetecting = false;

    if (_mediaKitPlayer != null) {
      _mediaKitPlayer?.stop();
    }
    _state = PlayerState.idle;
    _currentChannel = null;

    if (!silent) {
      notifyListeners();
    }
  }

  void seek(Duration position) {
    if (_useNativePlayer) return;
    _mediaKitPlayer?.seek(position);
  }

  void seekForward(int seconds) {
    seek(_position + Duration(seconds: seconds));
  }

  void seekBackward(int seconds) {
    final newPos = _position - Duration(seconds: seconds);
    seek(newPos.isNegative ? Duration.zero : newPos);
  }

  void setVolume(double volume) {
    _volume = volume.clamp(0.0, 1.0);
    _applyVolume();
    if (_volume > 0) _isMuted = false;
    notifyListeners();
  }

  double _volumeBeforeMute = 1.0;

  void toggleMute() {
    if (!_isMuted) {
      _volumeBeforeMute = _volume > 0 ? _volume : 1.0;
    }
    _isMuted = !_isMuted;
    if (!_isMuted && _volume == 0) {
      _volume = _volumeBeforeMute;
    }
    _applyVolume();
    notifyListeners();
  }

  void setVolumeBoost(int db) {
    _volumeBoostDb = db.clamp(-20, 20);
    _applyVolume();
    notifyListeners();
  }

  void loadVolumeSettings() {
    final prefs = ServiceLocator.prefs;
    _volumeBoostDb = prefs.getInt('volume_boost') ?? 0;
    _applyVolume();
  }

  void _applyVolume() {
    if (_useNativePlayer) return;

    if (_isMuted) {
      _mediaKitPlayer?.setVolume(0);
      return;
    }

    final multiplier = math.pow(10, _volumeBoostDb / 20.0);
    final effectiveVolume =
        (_volume * multiplier).clamp(0.0, 2.0);
    _mediaKitPlayer?.setVolume(effectiveVolume * 100);
  }

  void setPlaybackSpeed(double speed) {
    if (_useNativePlayer) return;
    _playbackSpeed = speed;
    _mediaKitPlayer?.setRate(speed);
    notifyListeners();
  }

  void toggleFullscreen() {
    _isFullscreen = !_isFullscreen;
    notifyListeners();
  }

  void setFullscreen(bool fullscreen) {
    _isFullscreen = fullscreen;
    notifyListeners();
  }

  void setControlsVisible(bool visible) {
    _controlsVisible = visible;
    notifyListeners();
  }

  void toggleControls() {
    _controlsVisible = !_controlsVisible;
    notifyListeners();
  }

  void playNext(List<Channel> channels) {
    if (_currentChannel == null || channels.isEmpty) return;
    final idx = channels.indexWhere((c) => c.id == _currentChannel!.id);
    if (idx == -1 || idx >= channels.length - 1) return;
    playChannel(channels[idx + 1]);
  }

  void playPrevious(List<Channel> channels) {
    if (_currentChannel == null || channels.isEmpty) return;
    final idx = channels.indexWhere((c) => c.id == _currentChannel!.id);
    if (idx <= 0) return;
    playChannel(channels[idx - 1]);
  }

  void switchToNextSource() {
    if (_currentChannel == null || !_currentChannel!.hasMultipleSources) return;
    _isAutoDetecting = false;
    _retryTimer?.cancel();
    final newIndex = (_currentChannel!.currentSourceIndex + 1) %
        _currentChannel!.sourceCount;
    _currentChannel!.currentSourceIndex = newIndex;

    ServiceLocator.log.d(
        'PlayerProvider: 手动切换到源 ${newIndex + 1}/${_currentChannel!.sourceCount}');

    if (!_isAutoSwitching) {
      _retryCount = 0;
      ServiceLocator.log
          .d('PlayerProvider: Manual source switch, reset retry state');
    }
    _playCurrentSource();
  }

  void switchToPreviousSource() {
    if (_currentChannel == null || !_currentChannel!.hasMultipleSources) return;
    _isAutoDetecting = false;
    _retryTimer?.cancel();
    final newIndex = (_currentChannel!.currentSourceIndex - 1 +
            _currentChannel!.sourceCount) %
        _currentChannel!.sourceCount;
    _currentChannel!.currentSourceIndex = newIndex;

    ServiceLocator.log.d(
        'PlayerProvider: 手动切换到源 ${newIndex + 1}/${_currentChannel!.sourceCount}');

    if (!_isAutoSwitching) {
      _retryCount = 0;
      ServiceLocator.log
          .d('PlayerProvider: Manual source switch, reset retry state');
    }
    _playCurrentSource();
  }

  Future<void> _playCurrentSource() async {
    if (_currentChannel == null) return;

    ServiceLocator.log.d('开始播放频道源', tag: 'PlayerProvider');
    ServiceLocator.log.d(
        '频道: ${_currentChannel!.name}, 源索引 ${_currentChannel!.currentSourceIndex}/${_currentChannel!.sourceCount}',
        tag: 'PlayerProvider');

    final testService = ChannelTestService();
    final tempChannel = Channel(
      id: _currentChannel!.id,
      name: _currentChannel!.name,
      url: _currentChannel!.currentUrl,
      groupName: _currentChannel!.groupName,
      logoUrl: _currentChannel!.logoUrl,
      sources: [_currentChannel!.currentUrl],
      playlistId: _currentChannel!.playlistId,
    );

    ServiceLocator.log
        .i('检测源可用性: ${_currentChannel!.currentUrl}', tag: 'PlayerProvider');

    final result = await testService.testChannel(tempChannel);

    if (!result.isAvailable) {
      ServiceLocator.log.w('源不可用: ${result.error}', tag: 'PlayerProvider');
      _setError('源不可用: ${result.error}');
      return;
    }

    ServiceLocator.log
        .i('源可用，响应时间: ${result.responseTime}ms', tag: 'PlayerProvider');

    final url = _currentChannel!.currentUrl;
    final startTime = DateTime.now();

    _state = PlayerState.loading;
    _error = null;
    _lastErrorMessage = null;
    _errorDisplayed = false;
    _noVideoFallbackAttempted = false;
    notifyListeners();

    try {
      if (!_useNativePlayer) {
        ServiceLocator.log
            .i('>>> 切换源: 尝试 rrsip 转换', tag: 'PlayerProvider');
        final rrsipUrl = await _resolveWithRrsip(url);
        final realUrl = rrsipUrl ?? url;

        ServiceLocator.log
            .d('>>> 切换源: 使用播放地址: $realUrl', tag: 'PlayerProvider');

        await _clearStartEndProperties();

        final playStartTime = DateTime.now();
        await _applyDeinterlaceFilter();
        await _mediaKitPlayer?.open(_createMedia(realUrl));

        final playTime =
            DateTime.now().difference(playStartTime).inMilliseconds;
        final totalTime = DateTime.now().difference(startTime).inMilliseconds;
        ServiceLocator.log
            .i('>>> 切换源: 播放器初始化完成，耗时: ${playTime}ms', tag: 'PlayerProvider');
        ServiceLocator.log
            .i('>>> 切换源: 总耗时: ${totalTime}ms', tag: 'PlayerProvider');

        _state = PlayerState.playing;
        _scheduleNoVideoFallbackIfNeeded();
      }
      ServiceLocator.log.i('播放成功', tag: 'PlayerProvider');
    } catch (e) {
      final totalTime = DateTime.now().difference(startTime).inMilliseconds;
      ServiceLocator.log
          .e('播放失败 (${totalTime}ms)', tag: 'PlayerProvider', error: e);
      _setError('Failed to play source: $e');
      return;
    }
    notifyListeners();
  }

  int get currentSourceIndex => (_currentChannel?.currentSourceIndex ?? 0) + 1;
  int get sourceCount => _currentChannel?.sourceCount ?? 1;

  void setCurrentChannelOnly(Channel channel) {
    _currentChannel = channel;
    notifyListeners();
  }

  // ============ DNS 解析与 rrsip 转换 ============
  final Map<String, String> _dnsCache = {};
  final Map<String, DateTime> _cacheTime = {};
  final Duration _cacheDuration = const Duration(minutes: 5);

  /// 将 URL 转换为 IP 直连 + rrsip 形式。
  /// 内部先处理 302 重定向，获取最终 URL，然后解析最终域名的 IP，构造新 URL。
  /// 如果转换失败返回 null。
  Future<String?> _resolveWithRrsip(String url) async {
    try {
      // 1. 获取最终 URL（处理 302 重定向）
      final finalUrl = await ServiceLocator.redirectCache.resolveRealPlayUrl(url);
      final uri = Uri.parse(finalUrl);

      // 如果已经是 IP 直连且带有 rrsip，无需转换
      if (_isIP(uri.host) && uri.queryParameters.containsKey('rrsip')) {
        return finalUrl;
      }

      // 原始域名（用于 rrsip 参数）
      final originalUri = Uri.parse(url);
      final originalHost = originalUri.host;

      // 如果最终主机已经是 IP，则无需转换，但需要确保 rrsip 参数存在
      if (_isIP(uri.host)) {
        if (!uri.queryParameters.containsKey('rrsip')) {
          final newUri = uri.replace(
            queryParameters: {
              ...uri.queryParameters,
              'rrsip': originalHost,
            },
          );
          return newUri.toString();
        }
        return finalUrl;
      }

      // 解析最终主机（域名）的 IP
      final ip = await _resolveDomain(uri.host);
      if (ip == null) {
        return null;
      }

      // 构造新 URL：用 IP 替换主机，保留原查询参数，添加 rrsip
      final newUri = uri.replace(
        host: ip,
        queryParameters: {
          ...uri.queryParameters,
          'rrsip': originalHost,
        },
      );
      return newUri.toString();
    } catch (e) {
      ServiceLocator.log.w('_resolveWithRrsip 失败: $e');
      return null;
    }
  }

  Future<String?> _resolveDomain(String host, {bool preferIPv6 = false}) async {
    if (_dnsCache.containsKey(host) &&
        _cacheTime.containsKey(host) &&
        DateTime.now().difference(_cacheTime[host]!) < _cacheDuration) {
      return _dnsCache[host];
    }

    try {
      final addresses = await InternetAddress.lookup(host);
      String? bestIp;

      if (preferIPv6) {
        for (final addr in addresses) {
          if (addr.type == InternetAddressType.IPv6 && !_isPrivateIP(addr.address)) {
            bestIp = addr.address;
            break;
          }
        }
        if (bestIp == null) {
          for (final addr in addresses) {
            if (addr.type == InternetAddressType.IPv4 && !_isPrivateIP(addr.address)) {
              bestIp = addr.address;
              break;
            }
          }
        }
        bestIp ??= addresses.first.address;
      } else {
        for (final addr in addresses) {
          if (addr.type == InternetAddressType.IPv4 && !_isPrivateIP(addr.address)) {
            bestIp = addr.address;
            break;
          }
        }
        if (bestIp == null) {
          for (final addr in addresses) {
            if (addr.type == InternetAddressType.IPv6 && !_isPrivateIP(addr.address)) {
              bestIp = addr.address;
              break;
            }
          }
        }
        bestIp ??= addresses.first.address;
      }

      _dnsCache[host] = bestIp;
      _cacheTime[host] = DateTime.now();
      return bestIp;
    } catch (e) {
      ServiceLocator.log.w('DNS解析失败: $e');
      return null;
    }
  }

  bool _isIP(String host) {
    return RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host) ||
           RegExp(r'^[0-9a-fA-F:]+$').hasMatch(host);
  }

  bool _isPrivateIP(String ip) {
    if (ip.startsWith('10.')) return true;
    if (ip.startsWith('192.168.')) return true;
    if (ip.startsWith('172.') && ip.split('.').length > 1) {
      final second = int.tryParse(ip.split('.')[1]) ?? 0;
      if (second >= 16 && second <= 31) return true;
    }
    if (ip == '127.0.0.1') return true;

    if (ip.startsWith('fe80:')) return true;
    if (ip.startsWith('fc00:') || ip.startsWith('fd00:')) return true;
    if (ip == '::1') return true;
    if (ip.startsWith('ff00:')) return true;
    if (ip.startsWith('::')) return true;

    return false;
  }

  // ============ 回放 URL 生成 ============
  CatchupUrlResult? generateCatchupUrlWithTime(Channel channel, EpgProgram program) {
    String? catchupSource = channel.catchupSource;
    if (catchupSource == null || catchupSource.isEmpty) {
      final defaultTemplate = ServiceLocator.settings?.defaultCatchupSource;
      if (defaultTemplate != null && defaultTemplate.isNotEmpty) {
        catchupSource = defaultTemplate;
      } else {
        catchupSource = '?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}';
      }
    }
    if (catchupSource == null) return null;

    final catchupMode = channel.catchup?.toLowerCase() ?? 'default';
    final startLocal = program.start;
    final endLocal = program.end;
    final startUtc = startLocal.toUtc();
    final endUtc = endLocal.toUtc();

    final startIso = startUtc.toIso8601String();
    final startIsoClean = startIso.replaceAll(RegExp(r'\.\d+Z$'), 'Z');
    final endIso = endUtc.toIso8601String();
    final endIsoClean = endIso.replaceAll(RegExp(r'\.\d+Z$'), 'Z');

    var url = catchupSource;

    final customFormatRegex = RegExp(r'\$\{\(([bBeE])([uU]?)\)([^}]+)\}');
    final customMatches = customFormatRegex.allMatches(url);
    for (final match in customMatches) {
      final timeMarker = match.group(1)!.toLowerCase();
      final tzMarker = match.group(2)!.toLowerCase();
      final formatStr = match.group(3)!;
      DateTime dateTime;
      if (tzMarker == 'u') {
        dateTime = (timeMarker == 'b') ? startUtc : endUtc;
      } else {
        dateTime = (timeMarker == 'b') ? startLocal : endLocal;
      }
      try {
        final formatter = DateFormat(formatStr);
        final formatted = formatter.format(dateTime);
        url = url.replaceFirst(match.group(0)!, formatted);
      } catch (_) {}
    }

    final braceFormatRegex = RegExp(r'\{\(([bBeE])([uU]?)\)([^}]+)\}');
    final braceMatches = braceFormatRegex.allMatches(url);
    for (final match in braceMatches) {
      final timeMarker = match.group(1)!.toLowerCase();
      final tzMarker = match.group(2)!.toLowerCase();
      final formatStr = match.group(3)!;
      DateTime dateTime;
      if (tzMarker == 'u') {
        dateTime = (timeMarker == 'b') ? startUtc : endUtc;
      } else {
        dateTime = (timeMarker == 'b') ? startLocal : endLocal;
      }
      try {
        final formatter = DateFormat(formatStr);
        final formatted = formatter.format(dateTime);
        url = url.replaceFirst(match.group(0)!, formatted);
      } catch (_) {}
    }

    url = url.replaceAll(RegExp(r'\$\{start\}'), startIsoClean);
    url = url.replaceAll(RegExp(r'\$\{stop\}'), endIsoClean);
    url = url.replaceAll(RegExp(r'\$\{end\}'), endIsoClean);

    url = url.replaceAll(RegExp(r'\{start\}'), startIsoClean);
    url = url.replaceAll(RegExp(r'\{stop\}'), endIsoClean);
    url = url.replaceAll(RegExp(r'\{end\}'), endIsoClean);

    if (catchupMode == 'append') {
      final template = catchupSource;
      final startSec = startUtc.millisecondsSinceEpoch ~/ 1000;
      final endSec = endUtc.millisecondsSinceEpoch ~/ 1000;
      final replaced = template
          .replaceAll('{utc}', startSec.toString())
          .replaceAll('{utcend}', endSec.toString());
      final fullUrl = channel.url + replaced;
      return CatchupUrlResult(url: fullUrl, startTime: null, endTime: null);
    }

    final looksLikeFullUrl = catchupSource.contains('://');
    String finalUrl;
    if (!looksLikeFullUrl) {
      var fragment = url.trimLeft();
      if (fragment.startsWith('?') || fragment.startsWith('&')) {
        fragment = fragment.substring(1);
      }
      final separator = channel.url.contains('?') ? '&' : '?';
      finalUrl = channel.url + separator + fragment;
    } else {
      finalUrl = url;
    }

    final parsed = Uri.parse(finalUrl);
    String? startTime;
    String? endTime;
    final playseek = parsed.queryParameters['playseek'];
    if (playseek != null && playseek.contains('-')) {
      final parts = playseek.split('-');
      if (parts.length == 2) {
        startTime = parts[0];
        endTime = parts[1];
      }
    }

    final cleanUri = parsed.replace(queryParameters: {
      ...parsed.queryParameters,
      'playseek': null,
    });
    final cleanUrl = cleanUri.toString();

    return CatchupUrlResult(
      url: cleanUrl,
      startTime: startTime,
      endTime: endTime,
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    _debugInfoTimer?.cancel();
    _retryTimer?.cancel();
    _mediaKitPlayer?.dispose();
    super.dispose();
  }

  void _scheduleNoVideoFallbackIfNeeded() {
    if (_useNativePlayer) return;
    if (!Platform.isWindows) return;
    if (_isSoftwareDecoding) return;
    if (!_allowSoftwareFallback) return;
    if (_noVideoFallbackAttempted) return;

    _noVideoFallbackAttempted = true;
    Future.delayed(const Duration(seconds: 3), () {
      if (_isDisposed) return;
      if (_state == PlayerState.playing &&
          _videoWidth == 0 &&
          _videoHeight == 0) {
        ServiceLocator.log
            .w('PlayerProvider: 音频帧变慢时画面卡顿，尝试软件回退', tag: 'PlayerProvider');
        _attemptSoftwareFallback();
      }
    });
  }
}
