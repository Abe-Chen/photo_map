import 'package:flutter/foundation.dart';
import 'package:supercluster/supercluster.dart';
import 'photo_indexer.dart';

/// 聚类边界框
class ClusterBounds {
  final double west;
  final double south;
  final double east;
  final double north;
  
  ClusterBounds({
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  });
  
  List<double> toList() => [west, south, east, north];
}

/// SuperCluster提供者，管理照片点的聚类
class SuperclusterProvider {
  SuperclusterImmutable<PhotoPoint>? _supercluster;
  List<PhotoPoint> _photoPoints = [];
  
  // 配置参数
  static const int minZoom = 0;
  static const int maxZoom = 18;
  static const int radius = 60;
  static const int extent = 2048;
  
  /// 初始化聚类器，加载照片点数据
  void initialize(List<PhotoPoint> photoPoints) {
    _photoPoints = photoPoints;
    
    if (photoPoints.isEmpty) {
      _supercluster = null;
      return;
    }
    
    // 创建SuperclusterImmutable实例
    _supercluster = SuperclusterImmutable<PhotoPoint>(
      getX: (PhotoPoint point) => point.lng as double,
      getY: (PhotoPoint point) => point.lat as double,
      minZoom: minZoom,
      maxZoom: maxZoom,
      radius: radius,
      extent: extent,
    );
    
    // 加载数据
    _supercluster!.load(photoPoints);
    
    debugPrint('SuperclusterProvider初始化完成，加载了${photoPoints.length}个照片点');
  }
  
  /// 获取指定边界框和缩放级别的聚类结果
  List<LayerElement<PhotoPoint>> getClusters(
    ClusterBounds bounds, 
    int zoom
  ) {
    if (_supercluster == null) {
      return [];
    }
    
    // 确保zoom在有效范围内
    final clampedZoom = zoom.clamp(minZoom, maxZoom);
    
    try {
      final result = _supercluster!.search(
        bounds.west,
        bounds.south, 
        bounds.east,
        bounds.north,
        clampedZoom,
      );
      
      debugPrint('获取聚类结果: bounds=${bounds.toList()}, zoom=$clampedZoom, 结果数量=${result.length}');
      return result;
    } catch (e) {
      debugPrint('获取聚类结果失败: $e');
      return [];
    }
  }
  
  /// 获取当前加载的照片点数量
  int get photoPointCount => _photoPoints.length;
  
  /// 检查是否已初始化
  bool get isInitialized => _supercluster != null;
  
  /// 清空数据
  void clear() {
    _supercluster = null;
    _photoPoints.clear();
    debugPrint('SuperclusterProvider已清空');
  }
}