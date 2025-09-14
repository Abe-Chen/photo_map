/// 行政级别枚举
enum AdminLevel {
  country,    // 国家
  admin1,     // 省/州
  city,       // 市
  district,   // 区县
  street,     // 街道
}

/// 缩放级别到行政级别的映射器
class ZoomLevelMapper {
  // 默认映射配置
  static const Map<AdminLevel, int> _defaultPrecisions = {
    AdminLevel.country: 3,
    AdminLevel.admin1: 4,
    AdminLevel.city: 5,
    AdminLevel.district: 6,
    AdminLevel.street: 7,
  };

  // 缩放级别阈值配置
  final Map<AdminLevel, List<int>> _zoomRanges;
  final Map<AdminLevel, int> _geohashPrecisions;

  ZoomLevelMapper({
    Map<AdminLevel, List<int>>? customZoomRanges,
    Map<AdminLevel, int>? customPrecisions,
  }) : _zoomRanges = customZoomRanges ?? _getDefaultZoomRanges(),
       _geohashPrecisions = customPrecisions ?? _defaultPrecisions;

  /// 获取默认的缩放级别范围
  static Map<AdminLevel, List<int>> _getDefaultZoomRanges() {
    return {
      AdminLevel.country: [0, 4],    // Z ≤ 4
      AdminLevel.admin1: [5, 6],     // Z 5-6
      AdminLevel.city: [7, 9],       // Z 7-9
      AdminLevel.district: [10, 12], // Z 10-12
      AdminLevel.street: [13, 20],   // Z ≥ 13
    };
  }

  /// 根据缩放级别获取对应的行政级别
  AdminLevel getAdminLevel(double zoom) {
    final zoomInt = zoom.round();
    
    for (final entry in _zoomRanges.entries) {
      final range = entry.value;
      if (zoomInt >= range[0] && zoomInt <= range[1]) {
        return entry.key;
      }
    }
    
    // 默认返回街道级别（最详细）
    return AdminLevel.street;
  }

  /// 获取行政级别对应的geohash精度
  int getGeohashPrecision(AdminLevel level) {
    return _geohashPrecisions[level] ?? 7;
  }

  /// 根据缩放级别直接获取geohash精度
  int getGeohashPrecisionByZoom(double zoom) {
    final level = getAdminLevel(zoom);
    return getGeohashPrecision(level);
  }

  /// 获取行政级别的显示名称
  String getAdminLevelName(AdminLevel level) {
    switch (level) {
      case AdminLevel.country:
        return '国家';
      case AdminLevel.admin1:
        return '省/州';
      case AdminLevel.city:
        return '市';
      case AdminLevel.district:
        return '区县';
      case AdminLevel.street:
        return '街道';
    }
  }

  /// 获取行政级别的英文名称（用于API调用）
  String getAdminLevelKey(AdminLevel level) {
    switch (level) {
      case AdminLevel.country:
        return 'country';
      case AdminLevel.admin1:
        return 'administrative_area_level_1';
      case AdminLevel.city:
        return 'locality';
      case AdminLevel.district:
        return 'administrative_area_level_2';
      case AdminLevel.street:
        return 'route';
    }
  }

  /// 判断是否需要更详细的级别
  bool shouldUseMoreDetailedLevel(double currentZoom, double targetZoom) {
    final currentLevel = getAdminLevel(currentZoom);
    final targetLevel = getAdminLevel(targetZoom);
    return targetLevel.index > currentLevel.index;
  }

  /// 获取建议的缩放级别范围
  List<int> getZoomRange(AdminLevel level) {
    return _zoomRanges[level] ?? [13, 20];
  }

  /// 获取所有支持的行政级别
  List<AdminLevel> getAllLevels() {
    return AdminLevel.values;
  }

  /// 创建自定义配置的映射器
  factory ZoomLevelMapper.custom({
    required Map<AdminLevel, List<int>> zoomRanges,
    Map<AdminLevel, int>? geohashPrecisions,
  }) {
    return ZoomLevelMapper(
      customZoomRanges: zoomRanges,
      customPrecisions: geohashPrecisions,
    );
  }

  /// 创建高精度配置的映射器（适用于高密度区域）
  factory ZoomLevelMapper.highPrecision() {
    return ZoomLevelMapper(
      customZoomRanges: {
        AdminLevel.country: [0, 3],
        AdminLevel.admin1: [4, 5],
        AdminLevel.city: [6, 8],
        AdminLevel.district: [9, 11],
        AdminLevel.street: [12, 20],
      },
      customPrecisions: {
        AdminLevel.country: 3,
        AdminLevel.admin1: 5,
        AdminLevel.city: 6,
        AdminLevel.district: 7,
        AdminLevel.street: 8,
      },
    );
  }

  /// 创建低精度配置的映射器（适用于性能优先场景）
  factory ZoomLevelMapper.lowPrecision() {
    return ZoomLevelMapper(
      customZoomRanges: {
        AdminLevel.country: [0, 5],
        AdminLevel.admin1: [6, 8],
        AdminLevel.city: [9, 11],
        AdminLevel.district: [12, 14],
        AdminLevel.street: [15, 20],
      },
      customPrecisions: {
        AdminLevel.country: 2,
        AdminLevel.admin1: 3,
        AdminLevel.city: 4,
        AdminLevel.district: 5,
        AdminLevel.street: 6,
      },
    );
  }
}