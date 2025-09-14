/// 索引进度状态管理
class PhotoIndexProgress {
  /// 需要补齐坐标的候选总数（视口内未带坐标 + 背景队列 + 缓存未命中）
  final int totalCandidates;
  
  /// 已解析且拿到坐标的数量
  final int done;
  
  /// 当前阶段：fast / viewport / background
  final IndexPhase phase;
  
  /// 估算的目标总数（带~前缀显示）
  final int estimatedTotal;
  
  /// 是否已完成（队列空闲且满足完成条件）
  final bool isCompleted;
  
  PhotoIndexProgress({
    required this.totalCandidates,
    required this.done,
    required this.phase,
    required this.estimatedTotal,
    required this.isCompleted,
  });
  
  /// 进度百分比 (0.0 - 1.0)
  double get progressRatio {
    if (totalCandidates == 0) return 1.0;
    return (done / totalCandidates).clamp(0.0, 1.0);
  }
  
  /// 是否应该显示进度条
  bool get shouldShowProgress {
    return totalCandidates > 0 || !isCompleted;
  }
  
  PhotoIndexProgress copyWith({
    int? totalCandidates,
    int? done,
    IndexPhase? phase,
    int? estimatedTotal,
    bool? isCompleted,
  }) {
    return PhotoIndexProgress(
      totalCandidates: totalCandidates ?? this.totalCandidates,
      done: done ?? this.done,
      phase: phase ?? this.phase,
      estimatedTotal: estimatedTotal ?? this.estimatedTotal,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }
}

/// 索引阶段枚举
enum IndexPhase {
  fast,     // 快速索引阶段
  viewport, // 视口补齐阶段
  background, // 后台补齐阶段
  idle,     // 空闲状态
}

extension IndexPhaseExtension on IndexPhase {
  String get displayName {
    switch (this) {
      case IndexPhase.fast:
        return '快速加载中';
      case IndexPhase.viewport:
        return '视口补齐';
      case IndexPhase.background:
        return '后台补齐';
      case IndexPhase.idle:
        return '最新';
    }
  }
}

/// 队列状态信息
class QueueStatus {
  /// 视口队列大小
  final int viewportQueueSize;
  
  /// 后台队列大小
  final int backgroundQueueSize;
  
  /// 正在运行的工作线程数
  final int runningWorkers;
  
  QueueStatus({
    required this.viewportQueueSize,
    required this.backgroundQueueSize,
    required this.runningWorkers,
  });
}

/// 详细统计信息
class DetailedStats {
  final int mediaLatLngCount;    // MediaStore直接获取的数量
  final int exifParsedCount;     // EXIF解析新增的数量
  final int cacheHitCount;       // 缓存命中数量
  final int recentFailureCount;  // 最近失败数
  final int recentSkipCount;     // 最近跳过数
  final double recentBatchAvgTime; // 最近批次平均耗时(ms)
  
  const DetailedStats({
    this.mediaLatLngCount = 0,
    this.exifParsedCount = 0,
    this.cacheHitCount = 0,
    this.recentFailureCount = 0,
    this.recentSkipCount = 0,
    this.recentBatchAvgTime = 0.0,
  });
}

/// 取消令牌
class CancellationToken {
  bool _isCancelled = false;
  
  bool get isCancelled => _isCancelled;
  
  void cancel() {
    _isCancelled = true;
  }
  
  void reset() {
    _isCancelled = false;
  }
}