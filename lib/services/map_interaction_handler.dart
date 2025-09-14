import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import '../models/photo_point.dart';
import 'cluster_engine.dart';

/// 地图交互处理器
class MapInteractionHandler {
  final gmaps.GoogleMapController? _mapController;
  final VoidCallback? _onCameraIdle;
  final Function(PhotoPoint)? _onPhotoTap;
  final Function(ClusterItem)? _onClusterTap;
  
  Timer? _debounceTimer;
  Timer? _idleTimer;
  bool _isMoving = false;
  
  final MapInteractionConfig _config;
  
  MapInteractionHandler({
    gmaps.GoogleMapController? mapController,
    VoidCallback? onCameraIdle,
    Function(PhotoPoint)? onPhotoTap,
    Function(ClusterItem)? onClusterTap,
    MapInteractionConfig? config,
  }) : _mapController = mapController,
       _onCameraIdle = onCameraIdle,
       _onPhotoTap = onPhotoTap,
       _onClusterTap = onClusterTap,
       _config = config ?? MapInteractionConfig.defaultConfig;

  /// 处理相机开始移动
  void onCameraMoveStarted() {
    _isMoving = true;
    _debounceTimer?.cancel();
    _idleTimer?.cancel();
  }

  /// 处理相机移动中
  void onCameraMove(gmaps.CameraPosition position) {
    _isMoving = true;
    _debounceTimer?.cancel();
    _idleTimer?.cancel();
  }

  /// 处理相机移动结束（空闲）
  void onCameraIdle() {
    _isMoving = false;
    
    // 防抖处理：延迟执行，避免频繁触发
    _debounceTimer?.cancel();
    _debounceTimer = Timer(Duration(milliseconds: _config.debounceMs), () {
      if (!_isMoving) {
        _triggerCameraIdle();
      }
    });
  }

  /// 触发相机空闲回调
  void _triggerCameraIdle() {
    _onCameraIdle?.call();
  }

  /// 处理聚合点击
  Future<void> handleClusterTap(
    ClusterItem cluster,
    List<PhotoPoint> allPhotoPoints,
  ) async {
    if (_mapController == null) return;
    
    if (cluster.isCluster) {
      // 聚合点击：放大到合适的边界
      await _zoomToClusterBounds(cluster, allPhotoPoints);
    } else {
      // 单个照片点击：查找对应的PhotoPoint并触发回调
      final photoPoint = _findPhotoPoint(cluster, allPhotoPoints);
      if (photoPoint != null) {
        _onPhotoTap?.call(photoPoint);
      }
    }
    
    // 触发聚合点击回调
    _onClusterTap?.call(cluster);
  }

  /// 放大到聚合边界
  Future<void> _zoomToClusterBounds(
    ClusterItem cluster,
    List<PhotoPoint> allPhotoPoints,
  ) async {
    if (_mapController == null) return;
    
    try {
      // 获取聚合中的所有照片点
      final clusterPoints = _getClusterPhotoPoints(cluster, allPhotoPoints);
      
      if (clusterPoints.isEmpty) {
        // 如果没有找到照片点，只是放大一级
        final currentZoom = await _getCurrentZoom();
        await _mapController!.animateCamera(
          gmaps.CameraUpdate.newCameraPosition(
            gmaps.CameraPosition(
              target: gmaps.LatLng(cluster.lat, cluster.lng),
              zoom: (currentZoom + _config.zoomIncrement).clamp(0.0, 20.0),
            ),
          ),
        );
        return;
      }
      
      // 计算边界
      final bounds = _calculateBounds(clusterPoints);
      
      // 检查聚合大小，决定缩放策略
      if (clusterPoints.length > _config.maxPointsForFullZoom) {
        // 点数过多，只放大一级
        final currentZoom = await _getCurrentZoom();
        final center = gmaps.LatLng(
          (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
          (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
        );
        await _mapController!.animateCamera(
          gmaps.CameraUpdate.newCameraPosition(
            gmaps.CameraPosition(
              target: center,
              zoom: (currentZoom + _config.zoomIncrement).clamp(0.0, 20.0),
            ),
          ),
        );
      } else {
        // 点数适中，放大到能看到所有点
        await _mapController!.animateCamera(
          gmaps.CameraUpdate.newLatLngBounds(
            bounds,
            _config.boundsPadding,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error zooming to cluster bounds: $e');
    }
  }

  /// 获取聚合中的照片点
  List<PhotoPoint> _getClusterPhotoPoints(
    ClusterItem cluster,
    List<PhotoPoint> allPhotoPoints,
  ) {
    // TODO: 根据实际的ClusterItem结构获取成员信息
    // 这里暂时返回附近的点作为示例
    const searchRadius = 0.001; // 约100米
    
    return allPhotoPoints.where((point) {
      final distance = _calculateDistance(
        cluster.lat, cluster.lng,
        point.lat, point.lng,
      );
      return distance <= searchRadius;
    }).toList();
  }

  /// 计算两点间距离（简化版本）
  double _calculateDistance(double lat1, double lng1, double lat2, double lng2) {
    final dLat = lat2 - lat1;
    final dLng = lng2 - lng1;
    return (dLat * dLat + dLng * dLng);
  }

  /// 计算边界
  gmaps.LatLngBounds _calculateBounds(List<PhotoPoint> points) {
    if (points.isEmpty) {
      throw ArgumentError('Points list cannot be empty');
    }
    
    double minLat = points.first.lat;
    double maxLat = points.first.lat;
    double minLng = points.first.lng;
    double maxLng = points.first.lng;
    
    for (final point in points) {
      minLat = minLat < point.lat ? minLat : point.lat;
      maxLat = maxLat > point.lat ? maxLat : point.lat;
      minLng = minLng < point.lng ? minLng : point.lng;
      maxLng = maxLng > point.lng ? maxLng : point.lng;
    }
    
    return gmaps.LatLngBounds(
      southwest: gmaps.LatLng(minLat, minLng),
      northeast: gmaps.LatLng(maxLat, maxLng),
    );
  }

  /// 获取当前缩放级别
  Future<double> _getCurrentZoom() async {
    if (_mapController == null) return 10.0;
    
    try {
      final position = await _mapController!.getVisibleRegion();
      // 简化计算，实际应该根据可见区域计算缩放级别
      return 10.0; // 默认值
    } catch (e) {
      return 10.0;
    }
  }

  /// 查找对应的照片点
  PhotoPoint? _findPhotoPoint(
    ClusterItem cluster,
    List<PhotoPoint> allPhotoPoints,
  ) {
    try {
      return allPhotoPoints.firstWhere((point) => point.id == cluster.id);
    } catch (e) {
      return null;
    }
  }

  /// 移动到指定位置
  Future<void> moveToLocation(
    double lat,
    double lng, {
    double? zoom,
    bool animate = true,
  }) async {
    if (_mapController == null) return;
    
    final targetZoom = zoom ?? await _getCurrentZoom();
    final cameraUpdate = gmaps.CameraUpdate.newCameraPosition(
      gmaps.CameraPosition(
        target: gmaps.LatLng(lat, lng),
        zoom: targetZoom,
      ),
    );
    
    if (animate) {
      await _mapController!.animateCamera(cameraUpdate);
    } else {
      await _mapController!.moveCamera(cameraUpdate);
    }
  }

  /// 获取当前可见区域
  Future<gmaps.LatLngBounds?> getVisibleRegion() async {
    if (_mapController == null) return null;
    
    try {
      return await _mapController!.getVisibleRegion();
    } catch (e) {
      debugPrint('Error getting visible region: $e');
      return null;
    }
  }

  /// 清理资源
  void dispose() {
    _debounceTimer?.cancel();
    _idleTimer?.cancel();
  }
}

/// 地图交互配置
class MapInteractionConfig {
  /// 防抖延迟（毫秒）
  final int debounceMs;
  
  /// 缩放增量
  final double zoomIncrement;
  
  /// 边界内边距
  final double boundsPadding;
  
  /// 完全缩放的最大点数
  final int maxPointsForFullZoom;
  
  /// 是否启用动画
  final bool enableAnimation;
  
  /// 动画持续时间（毫秒）
  final int animationDurationMs;
  
  const MapInteractionConfig({
    this.debounceMs = 250,
    this.zoomIncrement = 2.0,
    this.boundsPadding = 100.0,
    this.maxPointsForFullZoom = 50,
    this.enableAnimation = true,
    this.animationDurationMs = 500,
  });
  
  /// 默认配置
  static const MapInteractionConfig defaultConfig = MapInteractionConfig();
  
  /// 快速响应配置（较短防抖）
  static const MapInteractionConfig fastConfig = MapInteractionConfig(
    debounceMs: 150,
    animationDurationMs: 300,
  );
  
  /// 慢速响应配置（较长防抖，适合性能较差的设备）
  static const MapInteractionConfig slowConfig = MapInteractionConfig(
    debounceMs: 500,
    animationDurationMs: 800,
    maxPointsForFullZoom: 30,
  );
  
  /// 无动画配置
  static const MapInteractionConfig noAnimationConfig = MapInteractionConfig(
    enableAnimation: false,
    debounceMs: 200,
  );
}

/// 底部卡片控制器
class BottomCardController {
  final ValueNotifier<PhotoPoint?> _selectedPhoto = ValueNotifier(null);
  final ValueNotifier<bool> _isVisible = ValueNotifier(false);
  
  /// 当前选中的照片
  ValueNotifier<PhotoPoint?> get selectedPhoto => _selectedPhoto;
  
  /// 卡片是否可见
  ValueNotifier<bool> get isVisible => _isVisible;
  
  /// 显示照片卡片
  void showPhotoCard(PhotoPoint photo) {
    _selectedPhoto.value = photo;
    _isVisible.value = true;
  }
  
  /// 隐藏卡片
  void hideCard() {
    _isVisible.value = false;
    // 延迟清空选中照片，避免动画过程中闪烁
    Future.delayed(const Duration(milliseconds: 300), () {
      _selectedPhoto.value = null;
    });
  }
  
  /// 切换卡片显示状态
  void toggleCard() {
    if (_isVisible.value) {
      hideCard();
    } else if (_selectedPhoto.value != null) {
      _isVisible.value = true;
    }
  }
  
  /// 清理资源
  void dispose() {
    _selectedPhoto.dispose();
    _isVisible.dispose();
  }
}