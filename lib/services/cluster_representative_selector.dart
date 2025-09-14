import 'dart:math' as math;
import '../services/photo_indexer.dart';

/// 聚类代表照片选择器
/// 根据优先级选择聚类的代表照片：距离最近 → 时间最新 → 分辨率高
class ClusterRepresentativeSelector {
  /// 从聚类中选择代表照片
  /// [clusterCenter] 聚类中心坐标 (lat, lng)
  /// [photos] 聚类中的照片列表
  /// 返回代表照片的ID，如果没有合适的照片则返回null
  static String? selectRepresentative(
    (double lat, double lng) clusterCenter,
    List<PhotoPoint> photos,
  ) {
    if (photos.isEmpty) return null;
    
    // 如果只有一张照片，直接返回
    if (photos.length == 1) {
      return photos.first.id;
    }
    
    // 计算每张照片到聚类中心的距离
    final List<_PhotoWithDistance> photosWithDistance = photos
        .map((photo) => _PhotoWithDistance(
              photo: photo,
              distance: _calculateDistance(
                clusterCenter.$1,
                clusterCenter.$2,
                photo.lat,
                photo.lng,
              ),
            ))
        .toList();
    
    // 按优先级排序：距离最近 → 时间最新 → 分辨率高
    photosWithDistance.sort((a, b) {
      // 1. 首先按距离排序（距离越近越好）
      final distanceComparison = a.distance.compareTo(b.distance);
      if (distanceComparison != 0) {
        return distanceComparison;
      }
      
      // 2. 距离相同时，按时间排序（时间越新越好）
      final aDate = a.photo.date;
      final bDate = b.photo.date;
      if (aDate != null && bDate != null) {
        final timeComparison = bDate.compareTo(aDate); // 新的在前
        if (timeComparison != 0) {
          return timeComparison;
        }
      } else if (aDate != null) {
        return -1; // 有时间的优于没时间的
      } else if (bDate != null) {
        return 1;
      }
      
      // 3. 时间相同时，按分辨率排序（分辨率越高越好）
      final aResolution = _getPhotoResolution(a.photo);
      final bResolution = _getPhotoResolution(b.photo);
      return bResolution.compareTo(aResolution); // 分辨率高的在前
    });
    
    return photosWithDistance.first.photo.id;
  }
  
  /// 计算两点间的距离（使用Haversine公式）
  /// 返回距离（单位：米）
  static double _calculateDistance(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const double earthRadius = 6371000; // 地球半径（米）
    
    final double lat1Rad = lat1 * math.pi / 180;
    final double lat2Rad = lat2 * math.pi / 180;
    final double deltaLatRad = (lat2 - lat1) * math.pi / 180;
    final double deltaLngRad = (lng2 - lng1) * math.pi / 180;
    
    final double a = math.sin(deltaLatRad / 2) * math.sin(deltaLatRad / 2) +
        math.cos(lat1Rad) *
            math.cos(lat2Rad) *
            math.sin(deltaLngRad / 2) *
            math.sin(deltaLngRad / 2);
    
    final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    
    return earthRadius * c;
  }
  
  /// 获取照片分辨率（像素数）
  /// 如果没有分辨率信息，返回0
  static int _getPhotoResolution(PhotoPoint photo) {
    // 这里需要根据实际的PhotoPoint结构来获取分辨率信息
    // 如果PhotoPoint中没有分辨率信息，可以考虑从文件元数据中读取
    // 暂时返回一个基于文件名或其他信息的估算值
    
    // TODO: 实现真实的分辨率获取逻辑
    // 可能需要读取图片文件的EXIF信息或者缓存的元数据
    
    // 临时实现：基于文件名长度作为分辨率的粗略估算
    // 实际应用中应该从图片元数据中获取真实的宽度和高度
    return photo.id.length * 1000; // 临时实现
  }
  
  /// 批量选择多个聚类的代表照片
  /// [clusters] 聚类列表，每个元素包含聚类中心和照片列表
  /// 返回Map，键为聚类索引，值为代表照片ID
  static Map<int, String> selectRepresentativesForClusters(
    List<({(double lat, double lng) center, List<PhotoPoint> photos})> clusters,
  ) {
    final Map<int, String> representatives = {};
    
    for (int i = 0; i < clusters.length; i++) {
      final cluster = clusters[i];
      final representative = selectRepresentative(
        cluster.center,
        cluster.photos,
      );
      
      if (representative != null) {
        representatives[i] = representative;
      }
    }
    
    return representatives;
  }
}

/// 带距离信息的照片数据
class _PhotoWithDistance {
  final PhotoPoint photo;
  final double distance;
  
  _PhotoWithDistance({
    required this.photo,
    required this.distance,
  });
}