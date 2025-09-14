import 'dart:async';
import 'dart:math';
import 'package:supercluster_dart/supercluster_dart.dart';
import '../models/photo_point.dart';

/// 聚合引擎配置
class ClusterConfig {
  final int maxZoom;
  final int minZoom;
  final int radius; // 像素半径
  final int extent;
  final int rebuildThrottleMs; // 重建节流时间

  const ClusterConfig({
    this.maxZoom = 20,
    this.minZoom = 0,
    this.radius = 60,
    this.extent = 512,
    this.rebuildThrottleMs = 500,
  });
}

/// 聚合结果项
class ClusterItem {
  final String id;
  final double lat;
  final double lng;
  final int pointCount;
  final List<PhotoPoint> points;
  final bool isCluster;
  final PhotoPoint? representativePhoto; // 代表图片（最新或距中心最近）

  ClusterItem({
    required this.id,
    required this.lat,
    required this.lng,
    required this.pointCount,
    required this.points,
    required this.isCluster,
    this.representativePhoto,
  });

  factory ClusterItem.fromCluster(Map<String, dynamic> cluster) {
    final properties = cluster['properties'] as Map<String, dynamic>;
    final geometry = cluster['geometry'] as Map<String, dynamic>;
    final coordinates = geometry['coordinates'] as List;
    
    final points = (properties['points'] as List<dynamic>)
        .cast<PhotoPoint>();
    
    // 选择代表图片：取最新的照片
    PhotoPoint? representative;
    if (points.isNotEmpty) {
      representative = points.reduce((a, b) {
        if (a.date == null && b.date == null) return a;
        if (a.date == null) return b;
        if (b.date == null) return a;
        return a.date!.isAfter(b.date!) ? a : b;
      });
    }

    return ClusterItem(
      id: properties['cluster_id']?.toString() ?? 'cluster_${coordinates[0]}_${coordinates[1]}',
      lat: coordinates[1].toDouble(),
      lng: coordinates[0].toDouble(),
      pointCount: properties['point_count'] ?? points.length,
      points: points,
      isCluster: (properties['point_count'] ?? 1) > 1,
      representativePhoto: representative,
    );
  }

  factory ClusterItem.fromPoint(PhotoPoint point) {
    return ClusterItem(
      id: point.id,
      lat: point.lat,
      lng: point.lng,
      pointCount: 1,
      points: [point],
      isCluster: false,
      representativePhoto: point,
    );
  }
}

/// 聚合引擎
class ClusterEngine {
  final ClusterConfig config;
  Supercluster? _supercluster;
  List<PhotoPoint> _allPoints = [];
  Timer? _rebuildTimer;
  bool _isBuilding = false;

  ClusterEngine({this.config = const ClusterConfig()});

  /// 构建索引
  Future<void> buildIndex(List<PhotoPoint> points) async {
    if (_isBuilding) return;
    _isBuilding = true;

    try {
      _allPoints = List.from(points);
      
      // 转换为Supercluster需要的格式
      final features = points.map((point) => {
        'type': 'Feature',
        'properties': {
          'id': point.id,
          'point': point,
        },
        'geometry': {
          'type': 'Point',
          'coordinates': [point.lng, point.lat],
        },
      }).toList();

      _supercluster = Supercluster(
        points: features,
        maxZoom: config.maxZoom,
        minZoom: config.minZoom,
        radius: config.radius,
        extent: config.extent,
      );
    } finally {
      _isBuilding = false;
    }
  }

  /// 获取指定区域和缩放级别的聚合结果
  List<ClusterItem> getClusters(List<double> bbox, int zoom) {
    if (_supercluster == null) return [];

    try {
      final clusters = _supercluster!.getClusters(bbox, zoom);
      return clusters.map((cluster) {
        final properties = cluster['properties'] as Map<String, dynamic>;
        
        if (properties.containsKey('cluster_id')) {
          // 这是一个聚合
          return ClusterItem.fromCluster(cluster);
        } else {
          // 这是单个点
          final point = properties['point'] as PhotoPoint;
          return ClusterItem.fromPoint(point);
        }
      }).toList();
    } catch (e) {
      print('Error getting clusters: $e');
      return [];
    }
  }

  /// 增量更新（节流）
  void rebuildPartial(List<PhotoPoint> newPoints) {
    _rebuildTimer?.cancel();
    _rebuildTimer = Timer(Duration(milliseconds: config.rebuildThrottleMs), () {
      buildIndex(newPoints);
    });
  }

  /// 获取聚合的子项
  List<PhotoPoint> getClusterChildren(String clusterId) {
    if (_supercluster == null) return [];
    
    try {
      // 这里需要根据实际的supercluster_dart API来实现
      // 暂时返回空列表，后续根据实际API调整
      return [];
    } catch (e) {
      print('Error getting cluster children: $e');
      return [];
    }
  }

  /// 获取聚合的展开边界
  Map<String, double>? getClusterExpansionBounds(String clusterId) {
    if (_supercluster == null) return null;
    
    try {
      // 这里需要根据实际的supercluster_dart API来实现
      // 暂时返回null，后续根据实际API调整
      return null;
    } catch (e) {
      print('Error getting cluster expansion bounds: $e');
      return null;
    }
  }

  /// 清理资源
  void dispose() {
    _rebuildTimer?.cancel();
    _supercluster = null;
    _allPoints.clear();
  }

  /// 获取当前点数量
  int get pointCount => _allPoints.length;

  /// 是否已构建索引
  bool get isIndexBuilt => _supercluster != null;
}