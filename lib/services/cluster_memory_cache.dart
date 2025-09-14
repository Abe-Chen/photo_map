import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 聚类记忆缓存
/// 使用LRU算法缓存{zoom,clusterId} -> assetId的映射
/// 支持SharedPreferences持久化
class ClusterMemoryCache {
  static const int _maxCacheSize = 200;
  static const String _cacheKey = 'cluster_memory_cache';
  
  // LRU缓存：key为"zoom_clusterId"，value为assetId
  final Map<String, String> _cache = <String, String>{};
  
  // 访问顺序记录（最近访问的在最后）
  final List<String> _accessOrder = <String>[];
  
  static ClusterMemoryCache? _instance;
  
  ClusterMemoryCache._();
  
  /// 获取单例实例
  static ClusterMemoryCache get instance {
    _instance ??= ClusterMemoryCache._();
    return _instance!;
  }
  
  /// 生成缓存键
  /// [zoom] 缩放级别
  /// [clusterId] 聚类ID
  static String _generateKey(int zoom, String clusterId) {
    return '${zoom}_$clusterId';
  }
  
  /// 获取聚类的代表照片ID
  /// [zoom] 缩放级别
  /// [clusterId] 聚类ID
  /// 返回代表照片ID，如果不存在则返回null
  String? getRepresentative(int zoom, String clusterId) {
    final String key = _generateKey(zoom, clusterId);
    final String? assetId = _cache[key];
    
    if (assetId != null) {
      // 更新访问顺序
      _updateAccessOrder(key);
    }
    
    return assetId;
  }
  
  /// 设置聚类的代表照片ID
  /// [zoom] 缩放级别
  /// [clusterId] 聚类ID
  /// [assetId] 代表照片ID
  void setRepresentative(int zoom, String clusterId, String assetId) {
    final String key = _generateKey(zoom, clusterId);
    
    // 如果缓存已满，移除最久未访问的项
    if (_cache.length >= _maxCacheSize && !_cache.containsKey(key)) {
      _evictLeastRecentlyUsed();
    }
    
    _cache[key] = assetId;
    _updateAccessOrder(key);
  }
  
  /// 更新访问顺序
  /// [key] 缓存键
  void _updateAccessOrder(String key) {
    // 移除旧的访问记录
    _accessOrder.remove(key);
    // 添加到最后（最近访问）
    _accessOrder.add(key);
  }
  
  /// 移除最久未访问的项
  void _evictLeastRecentlyUsed() {
    if (_accessOrder.isNotEmpty) {
      final String oldestKey = _accessOrder.removeAt(0);
      _cache.remove(oldestKey);
    }
  }
  
  /// 清空缓存
  void clear() {
    _cache.clear();
    _accessOrder.clear();
  }
  
  /// 获取缓存统计信息
  Map<String, dynamic> getCacheStats() {
    return {
      'cacheSize': _cache.length,
      'maxCacheSize': _maxCacheSize,
      'accessOrderLength': _accessOrder.length,
      'cacheKeys': _cache.keys.toList(),
    };
  }
  
  /// 从SharedPreferences加载缓存
  Future<void> loadFromPreferences() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? cacheJson = prefs.getString(_cacheKey);
      
      if (cacheJson != null) {
        final Map<String, dynamic> cacheData = json.decode(cacheJson);
        
        // 恢复缓存数据
        final Map<String, dynamic>? cache = cacheData['cache'];
        final List<dynamic>? accessOrder = cacheData['accessOrder'];
        
        if (cache != null) {
          _cache.clear();
          cache.forEach((key, value) {
            if (key is String && value is String) {
              _cache[key] = value;
            }
          });
        }
        
        if (accessOrder != null) {
          _accessOrder.clear();
          for (final item in accessOrder) {
            if (item is String) {
              _accessOrder.add(item);
            }
          }
        }
        
        // 确保访问顺序与缓存数据一致
        _validateCacheConsistency();
      }
    } catch (e) {
      // 加载失败时清空缓存
      clear();
      print('Failed to load cluster memory cache: $e');
    }
  }
  
  /// 保存缓存到SharedPreferences
  Future<void> saveToPreferences() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      
      final Map<String, dynamic> cacheData = {
        'cache': _cache,
        'accessOrder': _accessOrder,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      
      final String cacheJson = json.encode(cacheData);
      await prefs.setString(_cacheKey, cacheJson);
    } catch (e) {
      print('Failed to save cluster memory cache: $e');
    }
  }
  
  /// 验证缓存一致性
  void _validateCacheConsistency() {
    // 移除访问顺序中不存在于缓存的键
    _accessOrder.removeWhere((key) => !_cache.containsKey(key));
    
    // 为缓存中存在但访问顺序中不存在的键添加访问记录
    for (final key in _cache.keys) {
      if (!_accessOrder.contains(key)) {
        _accessOrder.add(key);
      }
    }
  }
  
  /// 移除特定聚类的缓存
  /// [zoom] 缩放级别
  /// [clusterId] 聚类ID
  void removeRepresentative(int zoom, String clusterId) {
    final String key = _generateKey(zoom, clusterId);
    _cache.remove(key);
    _accessOrder.remove(key);
  }
  
  /// 移除特定缩放级别的所有缓存
  /// [zoom] 缩放级别
  void removeByZoom(int zoom) {
    final String zoomPrefix = '${zoom}_';
    final List<String> keysToRemove = _cache.keys
        .where((key) => key.startsWith(zoomPrefix))
        .toList();
    
    for (final key in keysToRemove) {
      _cache.remove(key);
      _accessOrder.remove(key);
    }
  }
  
  /// 检查缓存是否包含指定的聚类
  /// [zoom] 缩放级别
  /// [clusterId] 聚类ID
  bool containsRepresentative(int zoom, String clusterId) {
    final String key = _generateKey(zoom, clusterId);
    return _cache.containsKey(key);
  }
  
  /// 获取所有缓存的聚类信息
  List<({int zoom, String clusterId, String assetId})> getAllRepresentatives() {
    final List<({int zoom, String clusterId, String assetId})> result = [];
    
    for (final entry in _cache.entries) {
      final parts = entry.key.split('_');
      if (parts.length >= 2) {
        final int? zoom = int.tryParse(parts[0]);
        final String clusterId = parts.sublist(1).join('_');
        
        if (zoom != null) {
          result.add((
            zoom: zoom,
            clusterId: clusterId,
            assetId: entry.value,
          ));
        }
      }
    }
    
    return result;
  }
}