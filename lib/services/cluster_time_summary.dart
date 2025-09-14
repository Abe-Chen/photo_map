import 'package:intl/intl.dart';
import '../models/photo_point.dart';
import 'cluster_engine.dart';

/// 聚合时间摘要
class ClusterTimeSummary {
  static final DateFormat _dateFormatter = DateFormat('yyyy-MM-dd');
  static final DateFormat _yearFormatter = DateFormat('yyyy');
  static final DateFormat _monthFormatter = DateFormat('yyyy-MM');
  
  /// 获取聚合的时间标签
  /// 
  /// [cluster] 聚合项
  /// [photoPoints] 所有照片点数据
  /// [format] 时间格式类型
  /// 返回格式化的时间字符串，如果没有有效时间则返回空字符串
  static String getTimeLabel(
    ClusterItem cluster,
    List<PhotoPoint> photoPoints, {
    TimeLabelFormat format = TimeLabelFormat.date,
  }) {
    final clusterPoints = _getClusterPoints(cluster, photoPoints);
    if (clusterPoints.isEmpty) return '';
    
    final earliestDate = _getEarliestDate(clusterPoints);
    if (earliestDate == null) return '';
    
    return _formatDate(earliestDate, format);
  }
  
  /// 获取聚合的时间范围标签
  /// 
  /// [cluster] 聚合项
  /// [photoPoints] 所有照片点数据
  /// 返回时间范围字符串，如"2023-01-01 ~ 2023-12-31"
  static String getTimeRangeLabel(
    ClusterItem cluster,
    List<PhotoPoint> photoPoints,
  ) {
    final clusterPoints = _getClusterPoints(cluster, photoPoints);
    if (clusterPoints.isEmpty) return '';
    
    final dates = _getAllValidDates(clusterPoints);
    if (dates.isEmpty) return '';
    
    if (dates.length == 1) {
      return _formatDate(dates.first, TimeLabelFormat.date);
    }
    
    dates.sort();
    final earliest = dates.first;
    final latest = dates.last;
    
    // 如果是同一年，只显示月日
    if (earliest.year == latest.year) {
      if (earliest.month == latest.month) {
        // 同月，显示具体日期范围
        return '${_formatDate(earliest, TimeLabelFormat.date)} ~ ${earliest.day != latest.day ? latest.day.toString().padLeft(2, '0') : ''}';
      } else {
        // 同年不同月
        return '${DateFormat('MM-dd').format(earliest)} ~ ${DateFormat('MM-dd').format(latest)}';
      }
    }
    
    // 不同年份
    return '${_formatDate(earliest, TimeLabelFormat.date)} ~ ${_formatDate(latest, TimeLabelFormat.date)}';
  }
  
  /// 获取聚合的详细时间统计
  /// 
  /// [cluster] 聚合项
  /// [photoPoints] 所有照片点数据
  /// 返回时间统计信息
  static ClusterTimeStats getTimeStats(
    ClusterItem cluster,
    List<PhotoPoint> photoPoints,
  ) {
    final clusterPoints = _getClusterPoints(cluster, photoPoints);
    final dates = _getAllValidDates(clusterPoints);
    
    if (dates.isEmpty) {
      return ClusterTimeStats(
        totalCount: clusterPoints.length,
        validDateCount: 0,
        earliestDate: null,
        latestDate: null,
        timeSpanDays: 0,
      );
    }
    
    dates.sort();
    final earliest = dates.first;
    final latest = dates.last;
    final timeSpanDays = latest.difference(earliest).inDays;
    
    return ClusterTimeStats(
      totalCount: clusterPoints.length,
      validDateCount: dates.length,
      earliestDate: earliest,
      latestDate: latest,
      timeSpanDays: timeSpanDays,
    );
  }
  
  /// 获取聚合中的照片点
  static List<PhotoPoint> _getClusterPoints(
    ClusterItem cluster,
    List<PhotoPoint> photoPoints,
  ) {
    if (cluster.isCluster) {
      // 如果是聚合，需要根据聚合的成员ID找到对应的照片点
      // 这里假设cluster有成员信息，暂时返回空列表，需要根据实际ClusterItem结构调整
      // TODO: 根据实际的ClusterItem结构获取成员信息
      return <PhotoPoint>[];
    } else {
      // 如果是单个点，直接查找对应的照片点
      final point = photoPoints.firstWhere(
        (p) => p.id == cluster.id,
        orElse: () => throw StateError('PhotoPoint not found for cluster ${cluster.id}'),
      );
      return [point];
    }
  }
  
  /// 获取最早的日期
  static DateTime? _getEarliestDate(List<PhotoPoint> points) {
    DateTime? earliest;
    
    for (final point in points) {
      if (point.date != null) {
        if (earliest == null || point.date!.isBefore(earliest)) {
          earliest = point.date;
        }
      }
    }
    
    return earliest;
  }
  
  /// 获取所有有效日期
  static List<DateTime> _getAllValidDates(List<PhotoPoint> points) {
    return points
        .where((point) => point.date != null)
        .map((point) => point.date!)
        .toList();
  }
  
  /// 格式化日期
  static String _formatDate(DateTime date, TimeLabelFormat format) {
    switch (format) {
      case TimeLabelFormat.date:
        return _dateFormatter.format(date);
      case TimeLabelFormat.year:
        return _yearFormatter.format(date);
      case TimeLabelFormat.month:
        return _monthFormatter.format(date);
      case TimeLabelFormat.relative:
        return _getRelativeTimeLabel(date);
    }
  }
  
  /// 获取相对时间标签
  static String _getRelativeTimeLabel(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);
    
    if (difference.inDays == 0) {
      return '今天';
    } else if (difference.inDays == 1) {
      return '昨天';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}天前';
    } else if (difference.inDays < 30) {
      final weeks = (difference.inDays / 7).floor();
      return '${weeks}周前';
    } else if (difference.inDays < 365) {
      final months = (difference.inDays / 30).floor();
      return '${months}个月前';
    } else {
      final years = (difference.inDays / 365).floor();
      return '${years}年前';
    }
  }
}

/// 时间标签格式
enum TimeLabelFormat {
  /// 完整日期 (yyyy-MM-dd)
  date,
  /// 年份 (yyyy)
  year,
  /// 年月 (yyyy-MM)
  month,
  /// 相对时间 (今天、昨天、N天前等)
  relative,
}

/// 聚合时间统计
class ClusterTimeStats {
  /// 总照片数量
  final int totalCount;
  
  /// 有效日期的照片数量
  final int validDateCount;
  
  /// 最早日期
  final DateTime? earliestDate;
  
  /// 最晚日期
  final DateTime? latestDate;
  
  /// 时间跨度（天数）
  final int timeSpanDays;
  
  const ClusterTimeStats({
    required this.totalCount,
    required this.validDateCount,
    required this.earliestDate,
    required this.latestDate,
    required this.timeSpanDays,
  });
  
  /// 是否有有效时间数据
  bool get hasValidTime => validDateCount > 0;
  
  /// 时间覆盖率（有时间信息的照片比例）
  double get timeCoverageRatio => totalCount > 0 ? validDateCount / totalCount : 0.0;
  
  /// 是否为单日照片
  bool get isSingleDay => timeSpanDays == 0;
  
  /// 是否为长期跨度（超过30天）
  bool get isLongTimeSpan => timeSpanDays > 30;
  
  @override
  String toString() {
    return 'ClusterTimeStats(total: $totalCount, validDates: $validDateCount, '
           'earliest: $earliestDate, latest: $latestDate, span: ${timeSpanDays}d)';
  }
}

/// 时间标签配置
class TimeLabelConfig {
  /// 默认时间格式
  final TimeLabelFormat defaultFormat;
  
  /// 是否显示相对时间
  final bool showRelativeTime;
  
  /// 是否显示时间范围
  final bool showTimeRange;
  
  /// 单日照片是否显示时间
  final bool showTimeForSingleDay;
  
  /// 时间标签前缀
  final String timePrefix;
  
  /// 无时间数据时的占位文本
  final String noTimePlaceholder;
  
  const TimeLabelConfig({
    this.defaultFormat = TimeLabelFormat.date,
    this.showRelativeTime = false,
    this.showTimeRange = false,
    this.showTimeForSingleDay = true,
    this.timePrefix = '最早',
    this.noTimePlaceholder = '',
  });
  
  /// 默认配置
  static const TimeLabelConfig defaultConfig = TimeLabelConfig();
  
  /// 简洁配置（不显示时间前缀）
  static const TimeLabelConfig compactConfig = TimeLabelConfig(
    timePrefix: '',
    showTimeForSingleDay: false,
  );
  
  /// 详细配置（显示时间范围和相对时间）
  static const TimeLabelConfig detailedConfig = TimeLabelConfig(
    showRelativeTime: true,
    showTimeRange: true,
  );
}