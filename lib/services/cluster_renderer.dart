import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:photo_manager/photo_manager.dart';
import 'cluster_engine.dart';
import 'geo_labeler.dart';
import 'zoom_level_mapper.dart';
import '../models/photo_point.dart';

/// Marker渲染配置
class ClusterRenderConfig {
  final int markerBatchPerFrame;
  final Duration batchDelay;
  final int maxCacheSize;
  final Duration cacheExpiry;
  final Size markerSize;
  final double thumbnailSize;
  final double badgeSize;
  final TextStyle labelStyle;
  final Color clusterColor;
  final Color singlePointColor;
  
  const ClusterRenderConfig({
    this.markerBatchPerFrame = 8,
    this.batchDelay = const Duration(milliseconds: 16), // ~60fps
    this.maxCacheSize = 200,
    this.cacheExpiry = const Duration(minutes: 30),
    this.markerSize = const Size(120, 140),
    this.thumbnailSize = 80,
    this.badgeSize = 24,
    this.labelStyle = const TextStyle(
      fontSize: 12,
      color: Colors.black87,
      fontWeight: FontWeight.w500,
    ),
    this.clusterColor = const Color(0xFF2196F3),
    this.singlePointColor = const Color(0xFF4CAF50),
  });
}

/// Marker缓存项
class MarkerCacheItem {
  final gmaps.BitmapDescriptor bitmap;
  final DateTime timestamp;
  final String key;
  
  MarkerCacheItem({
    required this.bitmap,
    required this.timestamp,
    required this.key,
  });
  
  bool isExpired(Duration maxAge) {
    return DateTime.now().difference(timestamp) > maxAge;
  }
}

/// Marker生成请求
class MarkerRenderRequest {
  final ClusterItem cluster;
  final String label;
  final String cacheKey;
  final Completer<gmaps.BitmapDescriptor> completer;
  final DateTime timestamp;
  
  MarkerRenderRequest({
    required this.cluster,
    required this.label,
    required this.cacheKey,
    required this.completer,
  }) : timestamp = DateTime.now();
}

/// 聚合时间摘要
class ClusterTimeSummary {
  /// 获取聚合的最早时间
  static String getEarliestDateString(List<PhotoPoint> points) {
    if (points.isEmpty) return '';
    
    DateTime? earliest;
    for (final point in points) {
      if (point.date != null) {
        if (earliest == null || point.date!.isBefore(earliest)) {
          earliest = point.date;
        }
      }
    }
    
    if (earliest == null) return '';
    
    return '${earliest.year}-${earliest.month.toString().padLeft(2, '0')}-${earliest.day.toString().padLeft(2, '0')}';
  }
  
  /// 格式化标签文本
  static String formatLabel(String geoLabel, List<PhotoPoint> points) {
    final dateStr = getEarliestDateString(points);
    if (dateStr.isEmpty) {
      return geoLabel;
    }
    return '$geoLabel · 最早 $dateStr';
  }
}

/// 聚合渲染器
class ClusterRenderer {
  final ClusterRenderConfig config;
  final GeoLabeler geoLabeler;
  final ZoomLevelMapper zoomMapper;
  
  // 缓存
  final Map<String, MarkerCacheItem> _markerCache = {};
  
  // 渲染队列
  final Queue<MarkerRenderRequest> _renderQueue = Queue();
  bool _isProcessing = false;
  bool _isPaused = false;
  
  // 统计
  int _renderCount = 0;
  int _cacheHits = 0;
  
  ClusterRenderer({
    required this.geoLabeler,
    required this.zoomMapper,
    this.config = const ClusterRenderConfig(),
  });

  /// 渲染聚合为Markers
  Future<Set<gmaps.Marker>> renderClusters(
    List<ClusterItem> clusters,
    double zoom,
    VoidCallback? onTap,
  ) async {
    final markers = <gmaps.Marker>{};
    final level = zoomMapper.getAdminLevel(zoom);
    
    // 准备地理标签请求
    final geoRequests = <MapEntry<String, Map<String, dynamic>>>[];
    for (final cluster in clusters) {
      final requestKey = '${cluster.id}_${level.name}';
      geoRequests.add(MapEntry(requestKey, {
        'lat': cluster.lat,
        'lng': cluster.lng,
        'level': level,
      }));
    }
    
    // 批量获取地理标签
    final geoLabels = await geoLabeler.getLabelsForCameraIdle(geoRequests);
    
    // 为每个聚合创建Marker
    final futures = <Future<gmaps.Marker?>>[];
    for (final cluster in clusters) {
      final requestKey = '${cluster.id}_${level.name}';
      final geoLabel = geoLabels[requestKey] ?? '未知位置';
      
      futures.add(_createMarker(cluster, geoLabel, onTap));
    }
    
    final results = await Future.wait(futures);
    for (final marker in results) {
      if (marker != null) {
        markers.add(marker);
      }
    }
    
    return markers;
  }

  /// 创建单个Marker
  Future<gmaps.Marker?> _createMarker(
    ClusterItem cluster,
    String geoLabel,
    VoidCallback? onTap,
  ) async {
    try {
      final label = ClusterTimeSummary.formatLabel(geoLabel, cluster.points);
      final cacheKey = _generateCacheKey(cluster, label);
      
      // 检查缓存
      final cached = _markerCache[cacheKey];
      if (cached != null && !cached.isExpired(config.cacheExpiry)) {
        _cacheHits++;
        return _createMarkerFromBitmap(cluster, cached.bitmap, onTap);
      }
      
      // 生成新的bitmap
      final bitmap = await _getBitmapDescriptor(cluster, label);
      if (bitmap == null) return null;
      
      return _createMarkerFromBitmap(cluster, bitmap, onTap);
    } catch (e) {
      print('Error creating marker for cluster ${cluster.id}: $e');
      return null;
    }
  }

  /// 从bitmap创建Marker
  gmaps.Marker _createMarkerFromBitmap(
    ClusterItem cluster,
    gmaps.BitmapDescriptor bitmap,
    VoidCallback? onTap,
  ) {
    return gmaps.Marker(
      markerId: gmaps.MarkerId(cluster.id),
      position: gmaps.LatLng(cluster.lat, cluster.lng),
      icon: bitmap,
      onTap: onTap,
      anchor: const Offset(0.5, 1.0), // 底部中心锚点
    );
  }

  /// 获取BitmapDescriptor
  Future<gmaps.BitmapDescriptor?> _getBitmapDescriptor(
    ClusterItem cluster,
    String label,
  ) async {
    final cacheKey = _generateCacheKey(cluster, label);
    
    // 检查缓存
    final cached = _markerCache[cacheKey];
    if (cached != null && !cached.isExpired(config.cacheExpiry)) {
      _cacheHits++;
      return cached.bitmap;
    }
    
    // 创建渲染请求
    final completer = Completer<gmaps.BitmapDescriptor>();
    final request = MarkerRenderRequest(
      cluster: cluster,
      label: label,
      cacheKey: cacheKey,
      completer: completer,
    );
    
    _renderQueue.add(request);
    _processRenderQueue();
    
    return completer.future;
  }

  /// 处理渲染队列
  void _processRenderQueue() async {
    if (_isProcessing || _isPaused || _renderQueue.isEmpty) return;
    
    _isProcessing = true;
    
    while (_renderQueue.isNotEmpty && !_isPaused) {
      final batch = <MarkerRenderRequest>[];
      
      // 取出一批请求
      for (int i = 0; i < config.markerBatchPerFrame && _renderQueue.isNotEmpty; i++) {
        batch.add(_renderQueue.removeFirst());
      }
      
      // 处理这批请求
      await _processBatch(batch);
      
      // 等待下一帧
      if (_renderQueue.isNotEmpty) {
        await Future.delayed(config.batchDelay);
      }
    }
    
    _isProcessing = false;
  }

  /// 处理一批渲染请求
  Future<void> _processBatch(List<MarkerRenderRequest> batch) async {
    final futures = batch.map((request) => _renderMarkerBitmap(request));
    await Future.wait(futures);
  }

  /// 渲染Marker位图
  Future<void> _renderMarkerBitmap(MarkerRenderRequest request) async {
    try {
      _renderCount++;
      
      final widget = ClusterMarkerWidget(
        cluster: request.cluster,
        label: request.label,
        config: config,
      );
      
      final bitmap = await _widgetToBitmap(widget);
      
      // 缓存结果
      _markerCache[request.cacheKey] = MarkerCacheItem(
        bitmap: bitmap,
        timestamp: DateTime.now(),
        key: request.cacheKey,
      );
      
      // 清理缓存
      _cleanupCache();
      
      request.completer.complete(bitmap);
    } catch (e) {
      print('Error rendering marker bitmap: $e');
      request.completer.completeError(e);
    }
  }

  /// Widget转换为BitmapDescriptor（简化版本）
  Future<gmaps.BitmapDescriptor> _widgetToBitmap(Widget widget) async {
    // 使用简化的方法，直接从bytes创建
    // 这里可以根据需要实现更复杂的widget到bitmap转换
    return gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueBlue);
  }

  /// 生成缓存键
  String _generateCacheKey(ClusterItem cluster, String label) {
    final thumbId = cluster.representativePhoto?.id ?? 'none';
    return '${cluster.id}_${cluster.pointCount}_${thumbId}_${label.hashCode}';
  }

  /// 清理过期缓存
  void _cleanupCache() {
    if (_markerCache.length <= config.maxCacheSize) return;
    
    final toRemove = <String>[];
    
    // 移除过期项
    _markerCache.forEach((key, item) {
      if (item.isExpired(config.cacheExpiry)) {
        toRemove.add(key);
      }
    });
    
    for (final key in toRemove) {
      _markerCache.remove(key);
    }
    
    // 如果还是太多，移除最老的项
    if (_markerCache.length > config.maxCacheSize) {
      final entries = _markerCache.entries.toList()
        ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));
      
      final removeCount = _markerCache.length - config.maxCacheSize;
      for (int i = 0; i < removeCount; i++) {
        _markerCache.remove(entries[i].key);
      }
    }
  }

  /// 暂停渲染（滚动/拖动时）
  void pauseRendering() {
    _isPaused = true;
  }

  /// 恢复渲染
  void resumeRendering() {
    _isPaused = false;
    _processRenderQueue();
  }

  /// 获取统计信息
  Map<String, dynamic> getStats() {
    return {
      'renderCount': _renderCount,
      'cacheHits': _cacheHits,
      'cacheSize': _markerCache.length,
      'queueSize': _renderQueue.length,
      'hitRate': _renderCount > 0 ? _cacheHits / _renderCount : 0.0,
    };
  }

  /// 清空缓存
  void clearCache() {
    _markerCache.clear();
  }

  /// 释放资源
  void dispose() {
    _markerCache.clear();
    _renderQueue.clear();
  }
}

/// 聚合Marker Widget
class ClusterMarkerWidget extends StatelessWidget {
  final ClusterItem cluster;
  final String label;
  final ClusterRenderConfig config;
  
  const ClusterMarkerWidget({
    Key? key,
    required this.cluster,
    required this.label,
    required this.config,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: config.markerSize.width,
      height: config.markerSize.height,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 缩略图和计数
          Stack(
            children: [
              // 缩略图
              Container(
                width: config.thumbnailSize,
                height: config.thumbnailSize,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: cluster.isCluster ? config.clusterColor : config.singlePointColor,
                    width: 3,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: _buildThumbnail(),
                ),
              ),
              // 计数徽标
              if (cluster.isCluster && cluster.pointCount > 1)
                Positioned(
                  top: -4,
                  right: -4,
                  child: Container(
                    width: config.badgeSize,
                    height: config.badgeSize,
                    decoration: BoxDecoration(
                      color: config.clusterColor,
                      borderRadius: BorderRadius.circular(config.badgeSize / 2),
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Center(
                      child: Text(
                        cluster.pointCount > 99 ? '99+' : cluster.pointCount.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // 标签文本
          Container(
            constraints: BoxConstraints(
              maxWidth: config.markerSize.width,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.9),
              borderRadius: BorderRadius.circular(4),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Text(
              label,
              style: config.labelStyle,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnail() {
    if (cluster.representativePhoto?.asset != null) {
      // 使用实际缩略图
      return FutureBuilder<Uint8List?>(
        future: cluster.representativePhoto!.asset!.thumbnailDataWithSize(
          const ThumbnailSize.square(128),
        ),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return Image.memory(
              snapshot.data!,
              fit: BoxFit.cover,
              width: config.thumbnailSize,
              height: config.thumbnailSize,
            );
          }
          return _buildPlaceholder();
        },
      );
    }
    
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      width: config.thumbnailSize,
      height: config.thumbnailSize,
      color: Colors.grey[300],
      child: Icon(
        Icons.photo,
        color: Colors.grey[600],
        size: config.thumbnailSize * 0.4,
      ),
    );
  }
}