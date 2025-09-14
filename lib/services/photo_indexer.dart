import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:exif/exif.dart';

import 'exif_cache_service.dart';
import '../models/photo_index_progress.dart';
import '../models/photo_point.dart';

/// 视口边界定义
class ViewportBounds {
  final gmaps.LatLng northeast;
  final gmaps.LatLng southwest;
  
  ViewportBounds({
    required this.northeast,
    required this.southwest,
  });
  
  /// 检查坐标是否在视口内
  bool contains(double lat, double lng) {
    return lat >= southwest.latitude &&
           lat <= northeast.latitude &&
           lng >= southwest.longitude &&
           lng <= northeast.longitude;
  }
  
  @override
  String toString() {
    return 'ViewportBounds(NE: ${northeast.latitude},${northeast.longitude}, SW: ${southwest.latitude},${southwest.longitude})';
  }
}



class PhotoIndexModel extends ChangeNotifier {
  final List<PhotoPoint> _points = [];
  String? _error;
  int _total = 0;
  
  // 索引状态管理
  bool _isIndexing = false;
  int _indexedCount = 0;
  String? _lastError;
  
  // P0: 进度状态管理
  PhotoIndexProgress _progress = PhotoIndexProgress(
    totalCandidates: 0,
    done: 0,
    phase: IndexPhase.fast,
    estimatedTotal: 0,
    isCompleted: true,
  );
  bool _isPaused = false;
  CancellationToken _cancellationToken = CancellationToken();
  
  // 完成判定相关
  DateTime? _lastAddPointAt;
  final List<int> _recentNewPointsCounts = []; // 最近K批的新增点数
  static const int _completionCheckBatches = 5; // 检查最近5批
  static const Duration _completionTimeThreshold = Duration(seconds: 10); // 10秒无新增点
  
  // 队列状态跟踪
  int _viewportQueueSize = 0;
  int _backgroundQueueSize = 0;
  int _runningWorkers = 0;
  
  // 详细统计
  int _cacheHitCount = 0;
  final List<double> _recentParsingTimes = []; // 最近批次解析耗时
  int _recentFailureCount = 0;
  int _recentSkippedCount = 0;
  
  // 估算总数相关
  int _estimatedViewportCandidates = 0;
  int _estimatedBackgroundCandidates = 0;
  
  // 媒体库变更监听
  bool _isChangeListenerActive = false;
  
  // P1: 持久化缓存服务
  final ExifCacheService _cacheService = ExifCacheService.instance;
  Map<String, ExifCoordinate> _memoryCache = {}; // 内存缓存
  bool _isCachePreloaded = false;
  
  // P2: 安全网与回退机制
  final List<int> _exifParsingTimes = []; // EXIF解析耗时记录（毫秒）
  int _gcCount = 0; // GC次数统计
  DateTime? _lastGcTime;
  bool _isPerformanceDegraded = false; // 性能降级标志
  int _dynamicConcurrency = 3; // 动态并发数
  final Map<String, ExifCoordinate> _fallbackCache = {}; // 回退缓存（MediaStore无坐标时使用）
  
  // P1: 两阶段加载配置参数（优化性能和用户体验）
  int fastPageSize = 400; // 首屏已有坐标分页大小（提升至400以减少分页次数）
  int viewportBatchSize = 120; // 视口EXIF批处理大小（提升至120以提高吞吐量）
  int concurrency = 4; // 并发数（提升至4以充分利用多核性能）
  Duration smallDelay = const Duration(milliseconds: 2); // 批次间延迟（增加至2ms以减少GC压力）
  int notifyEveryBatches = 3; // 每3批通知一次UI（减少UI更新频率）
  int perViewportBudget = 600; // 每次相机稳定最多解析张数（临时提升至600）
   int _debounceMs = 500; // 视口变化防抖延迟（毫秒）
   int _recentLimitCount = 50; // 增量重扫无坐标资产限制数量
  
  // P1: 视频场景支持开关
  bool includeVideos = false; // 默认false，避免额外成本
  
  // P1: 可观测性统计变量
  int _mediaLatLngCount = 0; // 仅靠MediaStore直接拿到经纬度的张数
  int _exifParsedCount = 0; // 通过原图EXIF新增出来的张数
  int _skippedNoAccessOriginalCount = 0; // 因没有setRequireOriginal+ACCESS_MEDIA_LOCATION而解析不到GPS的张数
  
  // P1: 增量重扫窗口配置
  int _recentWindowMinutes = 5; // 默认5分钟
  
  // 后台补齐状态
  bool _isBackgroundEnrichmentActive = false;
  
  // 视口优先EXIF队列
  final Queue<String> _exifQueue = Queue<String>();
  final Set<String> _processedAssetIds = <String>{}; // 已处理的资产ID
  Timer? _viewportDebounceTimer;
  
  // P2: 去重缓存
  final Set<String> _seen = <String>{}; // 全局去重，key为asset.id
  final Set<String> _recentSeen = <String>{}; // 增量重扫去重
  
  // 平台通道
  static const MethodChannel _exifChannel = MethodChannel('com.example.photo_map_album/exif');

  List<PhotoPoint> get points => List.unmodifiable(_points);
  String? get error => _error;
  int get total => _total;
  
  // 索引状态暴露给UI
  bool get isIndexing => _isIndexing;
  int get indexedCount => _indexedCount;
  String? get lastError => _lastError;
  
  // P0: 进度状态暴露给UI
  PhotoIndexProgress get progress => _progress;
  bool get isPaused => _isPaused;
  
  // 队列状态暴露给UI
  QueueStatus get queueStatus => QueueStatus(
    viewportQueueSize: _viewportQueueSize,
    backgroundQueueSize: _backgroundQueueSize,
    runningWorkers: _runningWorkers,
  );
  
  // 详细统计信息
  DetailedStats get detailedStats => DetailedStats(
    mediaLatLngCount: _mediaLatLngCount,
    exifParsedCount: _exifParsedCount,
    cacheHitCount: _cacheHitCount,
    recentBatchAvgTime: _recentParsingTimes.isEmpty 
        ? 0.0 
        : _recentParsingTimes.reduce((a, b) => a + b) / _recentParsingTimes.length,
    recentFailureCount: _recentFailureCount,
    recentSkipCount: _recentSkippedCount,
  );
  
  // 配置参数的getter和setter
  int get fastPageSizeLimit => fastPageSize;
  set fastPageSizeLimit(int value) {
    fastPageSize = value.clamp(100, 500);
  }
  
  int get viewportBatchSizeLimit => viewportBatchSize;
  set viewportBatchSizeLimit(int value) {
    viewportBatchSize = value.clamp(50, 200);
  }
  
  int get concurrencyLevel => concurrency;
  set concurrencyLevel(int value) {
    concurrency = value.clamp(1, 5); // 最多5个并发
    // P2: GC压力安全网
    if (value <= 2) {
      smallDelay = const Duration(milliseconds: 5);
    } else {
      smallDelay = const Duration(milliseconds: 1);
    }
  }
  
  // P1: 增量重扫窗口配置
  int get recentWindowMinutes => _recentWindowMinutes;
  void setRecentWindowMinutes(int minutes) {
    _recentWindowMinutes = minutes.clamp(1, 60); // 1-60分钟范围
  }
  
  // P1: UI通知节流配置
  int get notifyBatchInterval => notifyEveryBatches;
  set notifyBatchInterval(int value) {
    notifyEveryBatches = value.clamp(1, 10);
  }
  
  // P0: 进度控制方法
  
  /// 暂停索引
  void pauseIndexing() {
    _isPaused = true;
    _updateProgress();
    debugPrint('索引已暂停');
  }
  
  /// 继续索引
  void resumeIndexing() {
    _isPaused = false;
    _updateProgress();
    debugPrint('索引已继续');
  }
  
  /// 仅解析当前视口（清空后台队列）
  void parseViewportOnly() {
    stopBackgroundEnrichment();
    _backgroundQueueSize = 0;
    _estimatedBackgroundCandidates = 0;
    _updateProgress();
    debugPrint('已切换为仅解析当前视口模式');
  }
  
  /// 取消当前操作
  void cancelCurrentOperation() {
    _cancellationToken.cancel();
    _cancellationToken = CancellationToken();
    debugPrint('当前操作已取消');
  }
  
  /// 更新进度状态
  void _updateProgress() {
    final totalCandidates = _estimatedViewportCandidates + _estimatedBackgroundCandidates;
    final done = _mediaLatLngCount + _exifParsedCount + _cacheHitCount;
    final estimatedTotal = done + totalCandidates;
    
    final isCompleted = _checkCompletionConditions();
    
    _progress = PhotoIndexProgress(
      totalCandidates: totalCandidates,
      done: done,
      phase: _getCurrentPhase(),
      estimatedTotal: estimatedTotal,
      isCompleted: isCompleted,
    );
  }
  
  /// 获取当前阶段
  IndexPhase _getCurrentPhase() {
    if (_isIndexing && !_isBackgroundEnrichmentActive) {
      return IndexPhase.fast;
    } else if (_viewportQueueSize > 0 || _runningWorkers > 0) {
      return IndexPhase.viewport;
    } else if (_isBackgroundEnrichmentActive) {
      return IndexPhase.background;
    }
    return IndexPhase.fast;
  }
  
  /// 检查完成条件
  bool _checkCompletionConditions() {
    // 条件1: 队列空闲
    final queuesEmpty = _viewportQueueSize == 0 && 
                       _backgroundQueueSize == 0 && 
                       _runningWorkers == 0;
    
    // 条件2: 最近10秒没有新增点
    final noRecentPoints = _lastAddPointAt == null || 
                          DateTime.now().difference(_lastAddPointAt!) > _completionTimeThreshold;
    
    // 条件3: 最近K批中新增点数为0
    final recentBatchesEmpty = _recentNewPointsCounts.length >= _completionCheckBatches &&
                              _recentNewPointsCounts.take(_completionCheckBatches).every((count) => count == 0);
    
    return queuesEmpty && noRecentPoints && recentBatchesEmpty;
  }
  
  /// 记录新增点位
  void _recordNewPoints(int count) {
    if (count > 0) {
      _lastAddPointAt = DateTime.now();
    }
    
    _recentNewPointsCounts.insert(0, count);
    if (_recentNewPointsCounts.length > _completionCheckBatches * 2) {
      _recentNewPointsCounts.removeLast();
    }
  }
  
  /// 更新队列状态
  void _updateQueueStatus({
    int? viewportQueueSize,
    int? backgroundQueueSize,
    int? runningWorkers,
  }) {
    if (viewportQueueSize != null) _viewportQueueSize = viewportQueueSize;
    if (backgroundQueueSize != null) _backgroundQueueSize = backgroundQueueSize;
    if (runningWorkers != null) _runningWorkers = runningWorkers;
    _updateProgress();
  }
  
  /// 启动媒体库变更监听
  Future<void> startChangeNotify() async {
    if (_isChangeListenerActive) {
      debugPrint('媒体库变更监听已启动，跳过重复调用');
      return;
    }
    
    try {
      await PhotoManager.startChangeNotify();
      PhotoManager.addChangeCallback(_onMediaLibraryChanged);
      _isChangeListenerActive = true;
      debugPrint('媒体库变更监听已启动');
    } catch (e) {
      debugPrint('启动媒体库变更监听失败: $e');
    }
  }
  
  /// 停止媒体库变更监听
  Future<void> stopChangeNotify() async {
    if (!_isChangeListenerActive) {
      return;
    }
    
    try {
      PhotoManager.removeChangeCallback(_onMediaLibraryChanged);
      await PhotoManager.stopChangeNotify();
      _isChangeListenerActive = false;
      debugPrint('媒体库变更监听已停止');
    } catch (e) {
      debugPrint('停止媒体库变更监听失败: $e');
    }
  }
  
  /// 媒体库变更回调处理
  void _onMediaLibraryChanged(MethodCall call) {
    debugPrint('检测到媒体库变更: ${call.method}');
    // 收到回调时只做增量重扫而非全量重扫
    rebuildRecent(minutes: _recentWindowMinutes);
  }

  /// P1: 预加载EXIF缓存到内存
  Future<void> _preloadCacheIfNeeded() async {
    if (_isCachePreloaded) return;
    
    try {
      debugPrint('开始预加载EXIF缓存...');
      _memoryCache = await _cacheService.preloadCache();
      _isCachePreloaded = true;
      debugPrint('EXIF缓存预加载完成，共 ${_memoryCache.length} 条记录');
    } catch (e) {
      debugPrint('预加载EXIF缓存失败: $e');
    }
  }
  
  /// P0: 两阶段加载 - 首屏快速加载（只取已有坐标）
  Future<void> buildIndexFast() async {
    debugPrint('=== PhotoIndexer.buildIndexFast() 开始执行 ===');
    if (_isIndexing) {
      debugPrint('索引正在进行中，跳过重复调用');
      return;
    }
    
    _isIndexing = true;
    _indexedCount = 0;
    _lastError = null;
    _points.clear();
    _total = 0;
    _error = null;
    _seen.clear();
    
    // P1: 重置可观测性统计
    _mediaLatLngCount = 0;
    _exifParsedCount = 0;
    _skippedNoAccessOriginalCount = 0;
    _cacheHitCount = 0;
    
    // P0: 重置进度状态
    _recentNewPointsCounts.clear();
    _lastAddPointAt = null;
    _progress = _progress.copyWith(
      phase: IndexPhase.fast,
      isCompleted: false,
    );
    _updateProgress();
    
    debugPrint('首屏快速索引开始，预加载缓存...');
    
    // P1: 预加载EXIF缓存
      await _preloadCacheIfNeeded();
      
      // P1: 定期清理过期缓存（每次索引时检查）
      unawaited(cleanupExpiredCache());
      
      // P2: 加载回退点位
      await _loadFallbackPoints();
      
      await PhotoManager.clearFileCache();
      debugPrint('PhotoManager缓存已清除');
    
    try {
      final albums = await PhotoManager.getAssetPathList(
        type: includeVideos ? RequestType.all : RequestType.image,
        filterOption: FilterOptionGroup(
          orders: [OrderOption(type: OrderOptionType.createDate, asc: false)],
        ),
      );

      if (albums.isEmpty) {
        _error = '没有找到相册';
        _lastError = _error;
        _isIndexing = false;
        notifyListeners();
        return;
      }

      // 分页获取已有坐标的assets（快速路径）
      int totalProcessed = 0;
      int pointsAdded = 0;
      
      for (final album in albums) {
        int page = 0;
        while (true) {
          final batch = await album.getAssetListPaged(page: page, size: fastPageSize);
          if (batch.isEmpty) break;
          
          // 只处理已有坐标的资产
          for (final asset in batch) {
            totalProcessed++;
            final lat = asset.latitude;
            final lng = asset.longitude;
            final hasValidCoords = lat != null &&
                lng != null &&
                lat != 0.0 &&
                lng != 0.0 &&
                !lat.isNaN &&
                !lng.isNaN;
            
            if (hasValidCoords && _seen.add(asset.id)) {
              _points.add(PhotoPoint(
                id: asset.id,
                lat: lat,
                lng: lng,
                date: asset.createDateTime,
                asset: asset,
              ));
              pointsAdded++;
              _mediaLatLngCount++; // 统计MediaStore直接获得坐标的张数
            }
          }
          
          // 节流通知UI
          if (totalProcessed % (fastPageSize * 2) == 0) {
            _indexedCount = pointsAdded;
            notifyListeners();
            await Future.delayed(const Duration(milliseconds: 1));
          }
          
          page++;
        }
      }
      
      _total = totalProcessed;
      _indexedCount = pointsAdded;
      _isIndexing = false;
      
      // P0: 记录新增点位并更新进度
      _recordNewPoints(pointsAdded);
      _updateProgress();
      
      // P1: 打印启动后摘要
      _printStatsSummary('启动后');
      
      debugPrint('首屏快速索引完成: 处理 $totalProcessed 张，获得 $pointsAdded 个点位');
      notifyListeners();
      
      // 启动后台补齐
      startBackgroundEnrichment();
      
    } catch (e, st) {
      _error = '首屏索引失败: $e';
      _lastError = _error;
      _isIndexing = false;
      debugPrint('首屏索引失败: $e\n$st');
      notifyListeners();
    }
  }
  
  /// P0: 后台补齐流程 - 慢速全库补齐
  Future<void> startBackgroundEnrichment() async {
    if (_isBackgroundEnrichmentActive) {
      debugPrint('后台补齐已在运行中');
      return;
    }
    
    _isBackgroundEnrichmentActive = true;
    debugPrint('启动后台慢速全库补齐流程...');
    
    // P0: 更新进度状态为后台补齐阶段
    _progress = _progress.copyWith(phase: IndexPhase.background);
    _updateProgress();
    
    try {
      // 获取所有相册
      final albums = await PhotoManager.getAssetPathList(
        type: includeVideos ? RequestType.all : RequestType.image,
        filterOption: FilterOptionGroup(
          orders: [OrderOption(type: OrderOptionType.createDate, asc: false)],
        ),
      );
      
      int totalScanned = 0;
      int totalProcessed = 0;
      
      // 慢速全库补齐配置
      const int slowBatchSize = 80; // 每批80张（50-100范围内）
      const int slowConcurrency = 2; // 并发数2（2-3范围内）
      const Duration batchDelay = Duration(milliseconds: 3); // 批次间延迟3ms
      
      // 逐相册、逐页处理，避免一次性加载过多资产
      for (final album in albums) {
        if (!_isBackgroundEnrichmentActive) break; // 支持中断
        
        int page = 0;
        while (_isBackgroundEnrichmentActive) {
          final batch = await album.getAssetListPaged(page: page, size: slowBatchSize);
          if (batch.isEmpty) break;
          
          final List<AssetEntity> assetsToProcess = [];
          
          // 筛选需要EXIF解析的资产（所有图片，但优先处理MediaStore坐标为空的）
          final List<AssetEntity> noMediaStoreCoords = [];
          final List<AssetEntity> hasMediaStoreCoords = [];
          
          for (final asset in batch) {
            totalScanned++;
            
            // 跳过已处理的资产
            if (_processedAssetIds.contains(asset.id)) {
              continue;
            }
            
            // 检查内存缓存，如果已有缓存且在_seen中，跳过
            if (_memoryCache.containsKey(asset.id) && _seen.contains(asset.id)) {
              continue;
            }
            
            // 检查MediaStore坐标
            final lat = asset.latitude;
            final lng = asset.longitude;
            final hasValidCoords = lat != null &&
                lng != null &&
                lat != 0.0 &&
                lng != 0.0 &&
                !lat.isNaN &&
                !lng.isNaN;
            
            if (!hasValidCoords) {
              // MediaStore无坐标，优先处理
              noMediaStoreCoords.add(asset);
            } else {
              // MediaStore有坐标，但可能EXIF有更准确的坐标
              hasMediaStoreCoords.add(asset);
            }
            
            _processedAssetIds.add(asset.id);
          }
          
          // 优先处理MediaStore无坐标的，再处理有坐标的
          assetsToProcess.addAll(noMediaStoreCoords);
          assetsToProcess.addAll(hasMediaStoreCoords);
          
          // 处理当前批次（如果有需要处理的资产）
          if (assetsToProcess.isNotEmpty) {
            debugPrint('后台补齐批次: 处理 ${assetsToProcess.length}/${batch.length} 张图片');
            
            // P0: 更新后台队列状态
            _updateQueueStatus(backgroundQueueSize: assetsToProcess.length);
            
            await _processSlowBatchedExifParsing(assetsToProcess, slowConcurrency);
            totalProcessed += assetsToProcess.length;
            
            // P0: 更新队列状态
            _updateQueueStatus(backgroundQueueSize: 0);
            
            // 批次间延迟，避免阻塞UI
            await Future.delayed(batchDelay);
          }
          
          page++;
          
          // 每处理1000张扫描的图片就打印一次进度
          if (totalScanned % 1000 == 0) {
            debugPrint('后台补齐进度: 已扫描 $totalScanned 张，已处理 $totalProcessed 张');
          }
        }
      }
      
      debugPrint('后台慢速全库补齐完成: 扫描 $totalScanned 张，处理 $totalProcessed 张需要EXIF解析的图片');
      
      // P1: 打印补齐结束后摘要
      _printStatsSummary('补齐结束时');
      
    } catch (e) {
      debugPrint('后台补齐流程失败: $e');
    } finally {
      _isBackgroundEnrichmentActive = false;
    }
  }
  
  /// 停止后台补齐流程
  void stopBackgroundEnrichment() {
    if (_isBackgroundEnrichmentActive) {
      _isBackgroundEnrichmentActive = false;
      debugPrint('后台补齐流程已停止');
    }
  }
  
  /// 慢速批量EXIF解析处理（专用于后台补齐）
  Future<void> _processSlowBatchedExifParsing(List<AssetEntity> assets, int concurrency) async {
    if (assets.isEmpty) return;
    
    final semaphore = _Semaphore(concurrency);
    int successCount = 0;
    final startTime = DateTime.now();
    
    // P0: 更新运行中的工作线程数
    _updateQueueStatus(runningWorkers: concurrency);
    
    // 并发处理当前批次
    final futures = assets.map((asset) async {
      await semaphore.acquire();
      try {
        // 检查是否暂停
        if (_isPaused || _cancellationToken.isCancelled) {
          return;
        }
        
        final result = await _tryReadLatLngFromExif(asset);
        
        if (result != null && _seen.add(asset.id)) {
          _points.add(PhotoPoint(
            id: asset.id,
            lat: result['lat']!,
            lng: result['lng']!,
            date: asset.createDateTime,
            asset: asset,
          ));
          successCount++;
        }
      } catch (e) {
        debugPrint('慢速EXIF解析失败 ${asset.id}: $e');
        _recentFailureCount++;
      } finally {
        semaphore.release();
      }
    });
    
    await Future.wait(futures);
    
    // P0: 记录解析耗时和新增点位
    final elapsedMs = DateTime.now().difference(startTime).inMilliseconds.toDouble();
    _recentParsingTimes.add(elapsedMs);
    if (_recentParsingTimes.length > 10) {
      _recentParsingTimes.removeAt(0);
    }
    
    _recordNewPoints(successCount);
    _updateQueueStatus(runningWorkers: 0);
    
    // 如果有新增点位，通知UI更新
    if (successCount > 0) {
      debugPrint('慢速批次完成: 新增 $successCount 个点位');
      notifyListeners();
    }
  }
  
  /// P0: 视口优先EXIF - 地图相机变化时调用
  void enqueueViewport(ViewportBounds bounds) {
    // 取消之前的debounce定时器
    _viewportDebounceTimer?.cancel();
    
    // 设置300ms debounce
    _viewportDebounceTimer = Timer(Duration(milliseconds: _debounceMs), () {
      _processViewportExif(bounds);
    });
  }
  
  /// 处理视口内的EXIF解析
  Future<void> _processViewportExif(ViewportBounds bounds) async {
    if (_isIndexing) {
      debugPrint('索引进行中，跳过视口EXIF处理');
      return;
    }
    
    debugPrint('开始处理视口EXIF解析...');
    
    // P0: 更新进度状态为视口补齐阶段
    _progress = _progress.copyWith(phase: IndexPhase.viewport);
    _updateProgress();
    
    try {
      // 获取相册资产（时间倒序）
      final albums = await PhotoManager.getAssetPathList(
        type: includeVideos ? RequestType.all : RequestType.image,
        filterOption: FilterOptionGroup(
          orders: [OrderOption(type: OrderOptionType.createDate, asc: false)],
        ),
      );
      
      final List<AssetEntity> candidateAssets = [];
      int budget = perViewportBudget;
      
      // 队列长度限制，避免内存溢出
      if (_exifQueue.length > 500) {
        debugPrint('EXIF队列已满(${_exifQueue.length})，清理旧任务');
        _exifQueue.clear();
      }
      
      // 分页获取资产，过滤出在视口内且无坐标且未处理过的
      for (final album in albums) {
        if (budget <= 0) break;
        
        int page = 0;
        while (budget > 0) {
          final batch = await album.getAssetListPaged(page: page, size: viewportBatchSize);
          if (batch.isEmpty) break;
          
          for (final asset in batch) {
            if (budget <= 0) break;
            
            // 跳过已处理的资产
            if (_processedAssetIds.contains(asset.id) || _seen.contains(asset.id)) {
              continue;
            }
            
            // 检查是否缺失坐标
            final lat = asset.latitude;
            final lng = asset.longitude;
            final hasValidCoords = lat != null &&
                lng != null &&
                lat != 0.0 &&
                lng != 0.0 &&
                !lat.isNaN &&
                !lng.isNaN;
            
            if (!hasValidCoords) {
              candidateAssets.add(asset);
              _processedAssetIds.add(asset.id);
              budget--;
            }
          }
          
          page++;
        }
      }
      
      if (candidateAssets.isNotEmpty) {
        debugPrint('视口EXIF: 准备解析 ${candidateAssets.length} 张图片');
        
        // P0: 更新视口队列状态
        _estimatedViewportCandidates = candidateAssets.length;
        _updateQueueStatus(viewportQueueSize: candidateAssets.length);
        
        await _processBatchedExifParsing(candidateAssets);
        
        // P0: 清空视口队列
        _updateQueueStatus(viewportQueueSize: 0);
        _estimatedViewportCandidates = 0;
        
        debugPrint('视口EXIF解析完成');
      }
      
    } catch (e) {
      debugPrint('视口EXIF处理失败: $e');
    }
  }
  
  /// 兼容性方法 - 重定向到快速索引
  Future<void> buildIndex() async {
    return buildIndexFast();
  }
  
  /// 批量EXIF解析处理
  Future<void> _processBatchedExifParsing(List<AssetEntity> assets) async {
    if (assets.isEmpty) return;
    
    debugPrint('开始批量EXIF解析，共 ${assets.length} 张图片');
    
    final semaphore = _Semaphore(_dynamicConcurrency); // 使用动态并发数
    int batchCount = 0;
    int successCount = 0;
    
    // 分批处理
    for (int i = 0; i < assets.length; i += viewportBatchSize) {
      final batch = assets.skip(i).take(viewportBatchSize).toList();
      batchCount++;
      
      // 并发处理当前批次
      final futures = batch.map((asset) async {
        await semaphore.acquire();
        try {
          final stopwatch = Stopwatch()..start();
          final result = await _tryReadLatLngFromExif(asset);
          stopwatch.stop();
          
          // P2: 记录EXIF解析耗时
          _recordExifParsingTime(stopwatch.elapsedMilliseconds);
          
          if (result != null && _seen.add(asset.id)) {
            _points.add(PhotoPoint(
              id: asset.id,
              lat: result['lat']!,
              lng: result['lng']!,
              date: asset.createDateTime,
              asset: asset,
            ));
            successCount++;
          }
        } finally {
          semaphore.release();
        }
      });
      
      await Future.wait(futures);
      
      // P2: GC监测
      _monitorGC();
      
      // 节流通知UI
      if (batchCount % notifyEveryBatches == 0) {
        notifyListeners();
        debugPrint('EXIF解析进度: ${batchCount * viewportBatchSize}/${assets.length}, 发现坐标: $successCount');
      }
      
      // 批次间延迟
      await Future.delayed(smallDelay);
    }
    
    debugPrint('EXIF解析完成: 成功解析 $successCount 张图片');
    notifyListeners();
  }
  
  /// P1: 增量重扫最近照片（两阶段策略）
  Future<void> rebuildRecent({int minutes = 5}) async {
    if (_isIndexing) {
      debugPrint('索引进行中，跳过增量重扫');
      return;
    }
    
    debugPrint('开始增量重扫最近 $minutes 分钟的照片（两阶段策略）');
    _recentSeen.clear();
    
    try {
      final cutoffTime = DateTime.now().subtract(Duration(minutes: minutes));
      
      final albums = await PhotoManager.getAssetPathList(
        type: includeVideos ? RequestType.all : RequestType.image,
        filterOption: FilterOptionGroup(
          orders: [OrderOption(type: OrderOptionType.createDate, asc: false)],
          createTimeCond: DateTimeCond(
            min: cutoffTime,
            max: DateTime.now(),
          ),
        ),
      );
      
      // 阶段1：快速收集已有坐标的资产
      int pointsAdded = 0;
      int totalProcessed = 0;
      final List<AssetEntity> noCoordAssets = [];
      
      for (final album in albums) {
        int page = 0;
        while (true) {
          final batch = await album.getAssetListPaged(page: page, size: 100);
          if (batch.isEmpty) break;
          
          for (final asset in batch) {
            if (asset.createDateTime != null && 
                asset.createDateTime!.isAfter(cutoffTime) &&
                _recentSeen.add(asset.id)) {
              totalProcessed++;
              
              final lat = asset.latitude;
              final lng = asset.longitude;
              final hasValidCoords = lat != null &&
                  lng != null &&
                  lat != 0.0 &&
                  lng != 0.0 &&
                  !lat.isNaN &&
                  !lng.isNaN;
              
              if (hasValidCoords && _seen.add(asset.id)) {
                // 阶段1：立即添加已有坐标的点
                _points.add(PhotoPoint(
                  id: asset.id,
                  lat: lat,
                  lng: lng,
                  date: asset.createDateTime,
                  asset: asset,
                ));
                pointsAdded++;
              } else if (!hasValidCoords) {
                 // 收集无坐标资产，限制数量避免全库兜底
                 if (noCoordAssets.length < _recentLimitCount) {
                   noCoordAssets.add(asset);
                 }
               }
            }
          }
          
          page++;
        }
      }
      
      debugPrint('增量重扫阶段1完成: 处理 $totalProcessed 张，立即获得 $pointsAdded 个点位');
      
      // 立即通知UI更新
      if (pointsAdded > 0) {
        notifyListeners();
      }
      
      // 阶段2：有限制地处理无坐标资产（避免全库兜底）
      if (noCoordAssets.isNotEmpty) {
        debugPrint('增量重扫阶段2: 处理 ${noCoordAssets.length} 张无坐标图片');
        await _processBatchedExifParsing(noCoordAssets);
        debugPrint('增量重扫阶段2完成');
      }
      
      debugPrint('增量重扫完成: 总计处理 $totalProcessed 张，获得坐标 ${pointsAdded + (noCoordAssets.isNotEmpty ? 1 : 0)} 批次');
      
    } catch (e) {
      debugPrint('增量重扫失败: $e');
    }
  }
  
  /// 获取缩略图
  Future<Uint8List?> getThumbnail(String assetId) async {
    try {
      final point = _points.firstWhere((p) => p.id == assetId);
      return await point.asset.thumbnailData;
    } catch (e) {
      debugPrint('获取缩略图失败: $e');
      return null;
    }
  }
  
  /// P1: 清理过期缓存
  Future<void> cleanupExpiredCache({int maxAgeDays = 30}) async {
    try {
      final maxAgeMs = maxAgeDays * 24 * 60 * 60 * 1000;
      final deletedCount = await _cacheService.cleanupExpiredCache(maxAge: maxAgeMs);
      debugPrint('清理过期缓存完成，删除 $deletedCount 条记录');
    } catch (e) {
      debugPrint('清理过期缓存失败: $e');
    }
  }
  
  /// 获取缓存统计信息
  Future<CacheStats> getCacheStats() async {
    return await _cacheService.getCacheStats();
  }
  
  /// P1: 打印可观测性统计摘要
  void _printStatsSummary(String phase) {
    final totalWithCoords = _mediaLatLngCount + _exifParsedCount;
    debugPrint('=== 可观测性统计摘要 ($phase) ===');
    debugPrint('MediaStore直接获得坐标: $_mediaLatLngCount 张');
    debugPrint('通过EXIF新增坐标: $_exifParsedCount 张');
    debugPrint('因无原图访问权限跳过: $_skippedNoAccessOriginalCount 张');
    debugPrint('总计有坐标照片: $totalWithCoords 张');
    debugPrint('========================================');
  }
  
  /// P2: 性能监测 - 记录EXIF解析耗时
  void _recordExifParsingTime(int milliseconds) {
    _exifParsingTimes.add(milliseconds);
    
    // 保持最近100次记录
    if (_exifParsingTimes.length > 100) {
      _exifParsingTimes.removeAt(0);
    }
    
    // 检查性能是否降级
    _checkPerformanceDegradation();
  }
  
  /// P2: 检查性能降级并自动调整参数
  void _checkPerformanceDegradation() {
    if (_exifParsingTimes.length < 10) return;
    
    // 计算最近10次的平均耗时
    final recentTimes = _exifParsingTimes.skip(_exifParsingTimes.length - 10);
    final avgTime = recentTimes.reduce((a, b) => a + b) / recentTimes.length;
    
    // 如果平均耗时超过500ms，认为性能降级
     if (avgTime > 500 && !_isPerformanceDegraded) {
       _isPerformanceDegraded = true;
       _dynamicConcurrency = math.max(1, _dynamicConcurrency - 1);
       debugPrint('检测到性能降级，降低并发数至: $_dynamicConcurrency');
     } else if (avgTime < 200 && _isPerformanceDegraded && _dynamicConcurrency < concurrency) {
       _isPerformanceDegraded = false;
       _dynamicConcurrency = math.min(concurrency, _dynamicConcurrency + 1);
       debugPrint('性能恢复，提升并发数至: $_dynamicConcurrency');
     }
  }
  
  /// P2: GC监测
  void _monitorGC() {
    final now = DateTime.now();
    if (_lastGcTime != null && now.difference(_lastGcTime!).inSeconds < 5) {
      _gcCount++;
      if (_gcCount > 3) {
        debugPrint('频繁GC检测到($_gcCount次)，可能存在内存压力');
        // 清理部分缓存
        if (_memoryCache.length > 1000) {
          final keysToRemove = _memoryCache.keys.take(_memoryCache.length ~/ 2).toList();
          for (final key in keysToRemove) {
            _memoryCache.remove(key);
          }
          debugPrint('清理内存缓存，剩余: ${_memoryCache.length} 条');
        }
        _gcCount = 0;
      }
    } else {
      _gcCount = 0;
    }
    _lastGcTime = now;
  }
  
  /// P2: 回退机制 - 从缓存显示点位（当MediaStore无坐标时）
  Future<void> _loadFallbackPoints() async {
    try {
      // 从内存缓存中获取坐标信息
      int fallbackCount = 0;
      
      for (final entry in _memoryCache.entries) {
        final assetId = entry.key;
        final coord = entry.value;
        
        if (!_seen.contains(assetId)) {
          // 将缓存的坐标信息保存到回退缓存中
          // 注意：这里缺少实际的AssetEntity，在实际应用中需要扩展缓存结构
          _fallbackCache[assetId] = coord;
          fallbackCount++;
        }
      }
      
      if (fallbackCount > 0) {
        debugPrint('回退机制: 从缓存加载 $fallbackCount 个点位');
      }
      
    } catch (e) {
      debugPrint('回退机制加载失败: $e');
    }
  }
  
  /// 尝试从EXIF读取经纬度（带缓存）
  Future<Map<String, double>?> _tryReadLatLngFromExif(AssetEntity asset) async {
    // P1: 视频场景支持 - 如果不包含视频且当前是视频，直接跳过
    if (!includeVideos && asset.type == AssetType.video) {
      return null;
    }
    
    // 检查MediaStore坐标（在方法开始就定义，确保作用域覆盖整个方法）
    final mediaLat = asset.latitude;
    final mediaLng = asset.longitude;
    final hasMediaStoreCoords = mediaLat != null &&
        mediaLng != null &&
        mediaLat != 0.0 &&
        mediaLng != 0.0 &&
        !mediaLat.isNaN &&
        !mediaLng.isNaN;
    
    try {
      // P1: 先检查内存缓存
      final cachedCoord = _memoryCache[asset.id];
      if (cachedCoord != null) {
        // 如果有缓存，比较缓存坐标和MediaStore坐标
        if (hasMediaStoreCoords) {
          // 如果MediaStore和缓存坐标差异很小（<0.001度，约100米），优先使用缓存
          final latDiff = (cachedCoord.latitude - mediaLat).abs();
          final lngDiff = (cachedCoord.longitude - mediaLng).abs();
          if (latDiff < 0.001 && lngDiff < 0.001) {
            return {'lat': cachedCoord.latitude, 'lng': cachedCoord.longitude};
          }
        }
        return {'lat': cachedCoord.latitude, 'lng': cachedCoord.longitude};
      }
      
      // P1: 检查数据库缓存
      final dbCachedCoord = await _cacheService.getCachedExif(asset.id);
      if (dbCachedCoord != null) {
        // 更新内存缓存
        _memoryCache[asset.id] = dbCachedCoord;
        
        // 如果有缓存，比较缓存坐标和MediaStore坐标
        if (hasMediaStoreCoords) {
          final latDiff = (dbCachedCoord.latitude - mediaLat).abs();
          final lngDiff = (dbCachedCoord.longitude - mediaLng).abs();
          if (latDiff < 0.001 && lngDiff < 0.001) {
            return {'lat': dbCachedCoord.latitude, 'lng': dbCachedCoord.longitude};
          }
        }
        return {'lat': dbCachedCoord.latitude, 'lng': dbCachedCoord.longitude};
      }
      
      // 如果MediaStore已有坐标且没有缓存，可以直接使用MediaStore坐标
      // 但仍然尝试EXIF解析以获得更准确的坐标
      if (hasMediaStoreCoords) {
        debugPrint('MediaStore已有坐标 ${asset.id}: ($mediaLat, $mediaLng)，尝试EXIF获取更准确坐标');
      }
      
      // 缓存未命中，优先使用原生方法解析EXIF
      Map<String, double>? nativeResult;
      bool hasOriginalAccess = false;
      
      try {
        // 使用原生方法获取EXIF GPS信息（支持setRequireOriginal和视频）
        final result = await _exifChannel.invokeMethod('getExifGps', {
          'contentUri': asset.id, // 使用asset.id作为content URI
          'assetType': asset.type.name, // 传递资产类型（图片或视频）
        });
        
        if (result != null && result is Map) {
          hasOriginalAccess = result['hasOriginalAccess'] == true;
          
          if (result.containsKey('latitude') && result.containsKey('longitude')) {
            final lat = (result['latitude'] as num).toDouble();
            final lng = (result['longitude'] as num).toDouble();
            
            if (!lat.isNaN && !lng.isNaN && lat != 0.0 && lng != 0.0) {
              nativeResult = {'lat': lat, 'lng': lng};
            }
          }
        }
      } catch (e) {
        debugPrint('原生EXIF解析失败 ${asset.id}: $e');
      }
      
      // 如果原生方法成功，比较MediaStore坐标和EXIF坐标
      if (nativeResult != null) {
        Map<String, double> finalResult = nativeResult;
        
        // 如果MediaStore也有坐标，比较精度
        if (hasMediaStoreCoords) {
          final exifLat = nativeResult['lat']!;
          final exifLng = nativeResult['lng']!;
          final latDiff = (exifLat - mediaLat).abs();
          final lngDiff = (exifLng - mediaLng).abs();
          
          // 如果差异很大（>0.01度，约1公里），可能EXIF更准确
          if (latDiff > 0.01 || lngDiff > 0.01) {
            debugPrint('坐标差异较大 ${asset.id}: MediaStore($mediaLat, $mediaLng) vs EXIF($exifLat, $exifLng)，使用EXIF');
            finalResult = nativeResult;
          } else {
            // 差异较小，使用EXIF坐标（通常更准确）
            finalResult = nativeResult;
          }
        }
        
        // P1: 解析成功，写入缓存
        final coordinate = ExifCoordinate(
          latitude: finalResult['lat']!, 
          longitude: finalResult['lng']!
        );
        _memoryCache[asset.id] = coordinate;
        
        // 异步写入数据库缓存
        unawaited(_cacheService.cacheExif(asset.id, finalResult['lat']!, finalResult['lng']!));
        
        // P1: 统计通过EXIF新增的张数
        _exifParsedCount++;
        
        return finalResult;
      }
      
      // P1: 统计因没有原图访问权限而跳过的张数
      if (!hasOriginalAccess) {
        _skippedNoAccessOriginalCount++;
      }
      
      // 原生方法失败，回退到Flutter EXIF解析
      debugPrint('原生EXIF解析失败，回退到Flutter解析: ${asset.id}');
      
      final file = await asset.file;
      if (file == null) return null;
      
      final bytes = await file.readAsBytes();
      final data = await readExifFromBytes(bytes);
      
      if (data.isEmpty) return null;
      
      final gpsLat = data['GPS GPSLatitude'];
      final gpsLatRef = data['GPS GPSLatitudeRef'];
      final gpsLng = data['GPS GPSLongitude'];
      final gpsLngRef = data['GPS GPSLongitudeRef'];
      
      if (gpsLat != null && gpsLatRef != null && gpsLng != null && gpsLngRef != null) {
        final lat = _parseGpsCoordinate(gpsLat.toString(), gpsLatRef.toString());
        final lng = _parseGpsCoordinate(gpsLng.toString(), gpsLngRef.toString());
        
        if (lat != null && lng != null) {
          // P1: 解析成功，写入缓存
          final coordinate = ExifCoordinate(latitude: lat, longitude: lng);
          _memoryCache[asset.id] = coordinate;
          
          // 异步写入数据库缓存
          unawaited(_cacheService.cacheExif(asset.id, lat, lng));
          
          // P1: 统计通过EXIF新增的张数
          _exifParsedCount++;
          
          return {'lat': lat, 'lng': lng};
        }
      }
      
    } catch (e) {
      debugPrint('EXIF解析失败 ${asset.id}: $e');
    }
    
    // 如果EXIF解析完全失败，但MediaStore有坐标，返回MediaStore坐标
    if (hasMediaStoreCoords) {
      debugPrint('EXIF解析失败，使用MediaStore坐标 ${asset.id}: ($mediaLat, $mediaLng)');
      
      // 将MediaStore坐标写入缓存
      final coordinate = ExifCoordinate(latitude: mediaLat!, longitude: mediaLng!);
      _memoryCache[asset.id] = coordinate;
      unawaited(_cacheService.cacheExif(asset.id, mediaLat!, mediaLng!));
      
      // 统计MediaStore直接获得坐标的张数（如果还没统计过）
      if (!_seen.contains(asset.id)) {
        _mediaLatLngCount++;
      }
      
      return {'lat': mediaLat!, 'lng': mediaLng!};
    }
    
    return null;
  }
  
  /// 解析GPS坐标 - 支持多种格式
  double? _parseGpsCoordinate(String coordinate, String ref) {
    try {
      // 格式1: 纯小数格式 (如 "39.9042")
      if (!coordinate.contains('[') && !coordinate.contains(',') && !coordinate.contains('/')) {
        final value = double.tryParse(coordinate.trim());
        if (value != null && !value.isNaN && value != 0.0) {
          double result = value;
          if (ref == 'S' || ref == 'W') {
            result = -result;
          }
          return result;
        }
      }
      
      // 格式2: 分数字符串格式 (如 "19101839/1000000")
      if (coordinate.contains('/') && !coordinate.contains('[') && !coordinate.contains(',')) {
        final value = _parseFraction(coordinate.trim());
        if (value != null && !value.isNaN && value != 0.0) {
          double result = value;
          if (ref == 'S' || ref == 'W') {
            result = -result;
          }
          return result;
        }
      }
      
      // 格式3: DMS数组格式 (如 "[39/1, 54/1, 5034/100]" 或 "[39, 54, 50.34]")
      // 移除方括号
      final cleaned = coordinate.replaceAll(RegExp(r'[\[\]]'), '');
      
      // 分割坐标部分
      final parts = cleaned.split(',');
      
      if (parts.length >= 3) {
        // 解析每个部分（可能是分数格式或小数格式）
        final degrees = _parseFraction(parts[0].trim());
        final minutes = _parseFraction(parts[1].trim());
        final seconds = _parseFraction(parts[2].trim());
        
        if (degrees != null && minutes != null && seconds != null) {
          // 验证DMS值的合理性
          if (degrees < 0 || degrees > 180 || minutes < 0 || minutes >= 60 || seconds < 0 || seconds >= 60) {
            debugPrint('GPS坐标DMS值超出合理范围: degrees=$degrees, minutes=$minutes, seconds=$seconds');
            return null;
          }
          
          double result = degrees + minutes / 60 + seconds / 3600;
          
          // 验证最终结果的合理性
          if (result.isNaN || result == 0.0) {
            return null;
          }
          
          if (ref == 'S' || ref == 'W') {
            result = -result;
          }
          return result;
        }
      }
      
      // 格式4: 单个DMS部分（如只有度数）
      if (parts.length == 1) {
        final value = _parseFraction(parts[0].trim());
        if (value != null && !value.isNaN && value != 0.0) {
          double result = value;
          if (ref == 'S' || ref == 'W') {
            result = -result;
          }
          return result;
        }
      }
      
    } catch (e) {
      debugPrint('GPS坐标解析失败: $e');
      debugPrint('原始坐标: $coordinate, 参考: $ref');
    }
    return null;
  }
  
  /// 解析分数格式的数值（如 "19101839/1000000"）
  double? _parseFraction(String value) {
    try {
      if (value.contains('/')) {
        final parts = value.split('/');
        if (parts.length == 2) {
          final numerator = double.parse(parts[0]);
          final denominator = double.parse(parts[1]);
          if (denominator != 0) {
            return numerator / denominator;
          }
        }
      } else {
        // 直接是数值
        return double.parse(value);
      }
    } catch (e) {
      debugPrint('分数解析失败: $value, 错误: $e');
    }
    return null;
  }
}

/// 信号量实现
class _Semaphore {
  final int maxCount;
  int _currentCount;
  final Queue<Completer<void>> _waitQueue = Queue<Completer<void>>();
  
  _Semaphore(this.maxCount) : _currentCount = maxCount;
  
  Future<void> acquire() async {
    if (_currentCount > 0) {
      _currentCount--;
      return;
    }
    
    final completer = Completer<void>();
    _waitQueue.add(completer);
    return completer.future;
  }
  
  void release() {
    if (_waitQueue.isNotEmpty) {
      final completer = _waitQueue.removeFirst();
      completer.complete();
    } else {
      _currentCount++;
    }
  }
}