import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'package:geocoding/geocoding.dart';
import 'zoom_level_mapper.dart';

/// Geohash工具类
class GeohashUtils {
  static const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';
  
  /// 生成geohash
  static String encode(double lat, double lng, int precision) {
    double latMin = -90.0, latMax = 90.0;
    double lngMin = -180.0, lngMax = 180.0;
    
    String geohash = '';
    int bits = 0;
    int bit = 0;
    bool evenBit = true;
    
    while (geohash.length < precision) {
      if (evenBit) {
        // 处理经度
        double mid = (lngMin + lngMax) / 2;
        if (lng >= mid) {
          bit = (bit << 1) | 1;
          lngMin = mid;
        } else {
          bit = bit << 1;
          lngMax = mid;
        }
      } else {
        // 处理纬度
        double mid = (latMin + latMax) / 2;
        if (lat >= mid) {
          bit = (bit << 1) | 1;
          latMin = mid;
        } else {
          bit = bit << 1;
          latMax = mid;
        }
      }
      
      evenBit = !evenBit;
      bits++;
      
      if (bits == 5) {
        geohash += _base32[bit];
        bits = 0;
        bit = 0;
      }
    }
    
    return geohash;
  }
}

/// 地理标签缓存项
class GeoLabelCacheItem {
  final String label;
  final DateTime timestamp;
  final AdminLevel level;
  
  GeoLabelCacheItem({
    required this.label,
    required this.timestamp,
    required this.level,
  });
  
  bool isExpired(Duration maxAge) {
    return DateTime.now().difference(timestamp) > maxAge;
  }
}

/// 逆地理编码请求项
class GeocodeRequest {
  final double lat;
  final double lng;
  final AdminLevel level;
  final String cacheKey;
  final Completer<String> completer;
  final DateTime timestamp;
  
  GeocodeRequest({
    required this.lat,
    required this.lng,
    required this.level,
    required this.cacheKey,
    required this.completer,
  }) : timestamp = DateTime.now();
}

/// 地理标签器配置
class GeoLabelerConfig {
  final int maxGeocodePerIdle;
  final Duration cacheMaxAge;
  final int maxCacheSize;
  final Duration requestTimeout;
  final String fallbackLabel;
  
  const GeoLabelerConfig({
    this.maxGeocodePerIdle = 25,
    this.cacheMaxAge = const Duration(hours: 24),
    this.maxCacheSize = 1000,
    this.requestTimeout = const Duration(seconds: 10),
    this.fallbackLabel = '未知区域',
  });
}

/// 地理标签器
class GeoLabeler {
  final GeoLabelerConfig config;
  final ZoomLevelMapper zoomMapper;
  
  // 缓存
  final Map<String, GeoLabelCacheItem> _cache = {};
  
  // 请求队列
  final Queue<GeocodeRequest> _requestQueue = Queue();
  bool _isProcessing = false;
  
  // 统计
  int _requestCount = 0;
  int _cacheHits = 0;
  
  GeoLabeler({
    required this.zoomMapper,
    this.config = const GeoLabelerConfig(),
  });

  /// 获取地理标签
  Future<String> getLabel(double lat, double lng, AdminLevel level) async {
    final precision = zoomMapper.getGeohashPrecision(level);
    final cacheKey = '${GeohashUtils.encode(lat, lng, precision)}_${level.name}';
    
    // 检查缓存
    final cached = _cache[cacheKey];
    if (cached != null && !cached.isExpired(config.cacheMaxAge)) {
      _cacheHits++;
      return cached.label;
    }
    
    // 创建请求
    final completer = Completer<String>();
    final request = GeocodeRequest(
      lat: lat,
      lng: lng,
      level: level,
      cacheKey: cacheKey,
      completer: completer,
    );
    
    _requestQueue.add(request);
    _processQueue();
    
    return completer.future;
  }

  /// 批量获取标签（相机空闲时调用）
  Future<Map<String, String>> getLabelsForCameraIdle(
    List<MapEntry<String, Map<String, dynamic>>> requests,
  ) async {
    final results = <String, String>{};
    final futures = <Future<String>>[];
    final keys = <String>[];
    
    for (final request in requests.take(config.maxGeocodePerIdle)) {
      final data = request.value;
      final lat = data['lat'] as double;
      final lng = data['lng'] as double;
      final level = data['level'] as AdminLevel;
      
      keys.add(request.key);
      futures.add(getLabel(lat, lng, level));
    }
    
    final labels = await Future.wait(futures);
    for (int i = 0; i < keys.length; i++) {
      results[keys[i]] = labels[i];
    }
    
    return results;
  }

  /// 处理请求队列
  void _processQueue() async {
    if (_isProcessing || _requestQueue.isEmpty) return;
    
    _isProcessing = true;
    
    while (_requestQueue.isNotEmpty) {
      final batch = <GeocodeRequest>[];
      
      // 取出一批请求（最多maxGeocodePerIdle个）
      for (int i = 0; i < config.maxGeocodePerIdle && _requestQueue.isNotEmpty; i++) {
        batch.add(_requestQueue.removeFirst());
      }
      
      // 并行处理这批请求
      await _processBatch(batch);
      
      // 如果还有请求，稍等一下再处理下一批
      if (_requestQueue.isNotEmpty) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    
    _isProcessing = false;
  }

  /// 处理一批请求
  Future<void> _processBatch(List<GeocodeRequest> batch) async {
    final futures = batch.map((request) => _processRequest(request));
    await Future.wait(futures);
  }

  /// 处理单个请求
  Future<void> _processRequest(GeocodeRequest request) async {
    try {
      _requestCount++;
      
      final label = await _performGeocode(request.lat, request.lng, request.level)
          .timeout(config.requestTimeout);
      
      // 缓存结果
      _cache[request.cacheKey] = GeoLabelCacheItem(
        label: label,
        timestamp: DateTime.now(),
        level: request.level,
      );
      
      // 清理过期缓存
      _cleanupCache();
      
      request.completer.complete(label);
    } catch (e) {
      print('Geocoding error for ${request.lat}, ${request.lng}: $e');
      request.completer.complete(config.fallbackLabel);
    }
  }

  /// 执行逆地理编码
  Future<String> _performGeocode(double lat, double lng, AdminLevel level) async {
    try {
      final placemarks = await placemarkFromCoordinates(lat, lng);
      
      if (placemarks.isEmpty) {
        return config.fallbackLabel;
      }
      
      final placemark = placemarks.first;
      return _extractLabelFromPlacemark(placemark, level);
    } catch (e) {
      throw Exception('Geocoding failed: $e');
    }
  }

  /// 从地标中提取标签
  String _extractLabelFromPlacemark(Placemark placemark, AdminLevel level) {
    switch (level) {
      case AdminLevel.country:
        return placemark.country ?? config.fallbackLabel;
      case AdminLevel.admin1:
        return placemark.administrativeArea ?? placemark.country ?? config.fallbackLabel;
      case AdminLevel.city:
        return placemark.locality ?? placemark.administrativeArea ?? config.fallbackLabel;
      case AdminLevel.district:
        return placemark.subAdministrativeArea ?? placemark.locality ?? config.fallbackLabel;
      case AdminLevel.street:
        return placemark.thoroughfare ?? placemark.subLocality ?? placemark.locality ?? config.fallbackLabel;
    }
  }

  /// 清理过期缓存
  void _cleanupCache() {
    if (_cache.length <= config.maxCacheSize) return;
    
    final now = DateTime.now();
    final toRemove = <String>[];
    
    // 移除过期项
    _cache.forEach((key, item) {
      if (item.isExpired(config.cacheMaxAge)) {
        toRemove.add(key);
      }
    });
    
    for (final key in toRemove) {
      _cache.remove(key);
    }
    
    // 如果还是太多，移除最老的项
    if (_cache.length > config.maxCacheSize) {
      final entries = _cache.entries.toList()
        ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));
      
      final removeCount = _cache.length - config.maxCacheSize;
      for (int i = 0; i < removeCount; i++) {
        _cache.remove(entries[i].key);
      }
    }
  }

  /// 处理跨行政区簇命名
  String getCrossRegionLabel(List<String> labels, AdminLevel level) {
    if (labels.isEmpty) return config.fallbackLabel;
    if (labels.length == 1) return labels.first;
    
    // 统计各名称出现次数
    final counts = <String, int>{};
    for (final label in labels) {
      counts[label] = (counts[label] ?? 0) + 1;
    }
    
    // 找出出现最多的名称
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    final mainLabel = sorted.first.key;
    final uniqueCount = counts.length;
    
    if (uniqueCount > 1) {
      return '$mainLabel 等${uniqueCount}地';
    }
    
    return mainLabel;
  }

  /// 获取统计信息
  Map<String, dynamic> getStats() {
    return {
      'requestCount': _requestCount,
      'cacheHits': _cacheHits,
      'cacheSize': _cache.length,
      'queueSize': _requestQueue.length,
      'hitRate': _requestCount > 0 ? _cacheHits / _requestCount : 0.0,
    };
  }

  /// 清空缓存
  void clearCache() {
    _cache.clear();
  }

  /// 预热缓存（为常见位置预加载标签）
  Future<void> warmupCache(List<Map<String, dynamic>> locations) async {
    final futures = <Future<String>>[];
    
    for (final location in locations) {
      final lat = location['lat'] as double;
      final lng = location['lng'] as double;
      final level = location['level'] as AdminLevel? ?? AdminLevel.city;
      
      futures.add(getLabel(lat, lng, level));
    }
    
    await Future.wait(futures);
  }

  /// 释放资源
  void dispose() {
    _cache.clear();
    _requestQueue.clear();
  }
}