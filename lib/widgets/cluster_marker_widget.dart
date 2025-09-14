import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import '../services/cluster_engine.dart';

/// 聚合标记Widget
class ClusterMarkerWidget extends StatelessWidget {
  final ClusterItem cluster;
  final String geoLabel;
  final String timeLabel;
  final AssetEntity? thumbnailAsset;
  final double size;
  final Color backgroundColor;
  final Color textColor;
  final Color badgeColor;
  final TextStyle? labelStyle;
  final TextStyle? timeStyle;
  final TextStyle? countStyle;

  const ClusterMarkerWidget({
    Key? key,
    required this.cluster,
    required this.geoLabel,
    required this.timeLabel,
    this.thumbnailAsset,
    this.size = 80.0,
    this.backgroundColor = Colors.white,
    this.textColor = Colors.black87,
    this.badgeColor = Colors.red,
    this.labelStyle,
    this.timeStyle,
    this.countStyle,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 主体部分：缩略图 + 计数徽标
        _buildMainMarker(),
        const SizedBox(height: 4),
        // 底部文本
        _buildLabel(),
      ],
    );
  }

  /// 构建主标记（缩略图 + 计数徽标）
  Widget _buildMainMarker() {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          // 缩略图背景
          _buildThumbnail(),
          // 计数徽标（仅当count > 1时显示）
          if (cluster.pointCount > 1) _buildCountBadge(),
        ],
      ),
    );
  }

  /// 构建缩略图
  Widget _buildThumbnail() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.15),
        color: backgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.15),
        child: thumbnailAsset != null
            ? _buildAssetThumbnail()
            : _buildPlaceholder(),
      ),
    );
  }

  /// 构建资源缩略图
  Widget _buildAssetThumbnail() {
    return FutureBuilder<Widget?>(
      future: _loadThumbnail(),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null) {
          return snapshot.data!;
        }
        return _buildPlaceholder();
      },
    );
  }

  /// 加载缩略图
  Future<Widget?> _loadThumbnail() async {
    if (thumbnailAsset == null) return null;
    
    try {
      final thumbnailData = await thumbnailAsset!.thumbnailDataWithSize(
        ThumbnailSize.square(size.toInt()),
      );
      
      if (thumbnailData != null) {
        return Image.memory(
          thumbnailData,
          fit: BoxFit.cover,
          width: size,
          height: size,
        );
      }
    } catch (e) {
      // 加载失败，返回占位符
    }
    
    return null;
  }

  /// 构建占位符
  Widget _buildPlaceholder() {
    return Container(
      width: size,
      height: size,
      color: Colors.grey[300],
      child: Icon(
        Icons.photo,
        size: size * 0.4,
        color: Colors.grey[600],
      ),
    );
  }

  /// 构建计数徽标
  Widget _buildCountBadge() {
    final count = cluster.pointCount;
    final badgeSize = size * 0.35;
    
    return Positioned(
      top: -2,
      right: -2,
      child: Container(
        width: badgeSize,
        height: badgeSize,
        decoration: BoxDecoration(
          color: badgeColor,
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Center(
          child: Text(
            _formatCount(count),
            style: countStyle ??
                TextStyle(
                  color: Colors.white,
                  fontSize: badgeSize * 0.35,
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  /// 构建底部标签
  Widget _buildLabel() {
    final labelText = _buildLabelText();
    
    return Container(
      constraints: BoxConstraints(maxWidth: size * 1.5),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: backgroundColor.withOpacity(0.9),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        labelText,
        style: labelStyle ??
            TextStyle(
              color: textColor,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// 构建标签文本
  String _buildLabelText() {
    if (timeLabel.isNotEmpty) {
      return '$geoLabel · $timeLabel';
    }
    return geoLabel;
  }

  /// 格式化计数显示
  String _formatCount(int count) {
    if (count < 1000) {
      return count.toString();
    } else if (count < 10000) {
      return '${(count / 1000).toStringAsFixed(1)}k';
    } else {
      return '${(count / 1000).toInt()}k';
    }
  }
}

/// 聚合标记配置
class ClusterMarkerConfig {
  final double size;
  final Color backgroundColor;
  final Color textColor;
  final Color badgeColor;
  final TextStyle? labelStyle;
  final TextStyle? timeStyle;
  final TextStyle? countStyle;
  final BorderRadius? borderRadius;
  final List<BoxShadow>? shadows;

  const ClusterMarkerConfig({
    this.size = 80.0,
    this.backgroundColor = Colors.white,
    this.textColor = Colors.black87,
    this.badgeColor = Colors.red,
    this.labelStyle,
    this.timeStyle,
    this.countStyle,
    this.borderRadius,
    this.shadows,
  });

  /// 默认配置
  static const ClusterMarkerConfig defaultConfig = ClusterMarkerConfig();

  /// 紧凑配置（较小尺寸）
  static const ClusterMarkerConfig compactConfig = ClusterMarkerConfig(
    size: 60.0,
  );

  /// 大尺寸配置
  static const ClusterMarkerConfig largeConfig = ClusterMarkerConfig(
    size: 100.0,
  );

  /// 深色主题配置
  static const ClusterMarkerConfig darkConfig = ClusterMarkerConfig(
    backgroundColor: Color(0xFF2D2D2D),
    textColor: Colors.white,
    badgeColor: Color(0xFFFF6B6B),
  );

  /// 复制并修改配置
  ClusterMarkerConfig copyWith({
    double? size,
    Color? backgroundColor,
    Color? textColor,
    Color? badgeColor,
    TextStyle? labelStyle,
    TextStyle? timeStyle,
    TextStyle? countStyle,
    BorderRadius? borderRadius,
    List<BoxShadow>? shadows,
  }) {
    return ClusterMarkerConfig(
      size: size ?? this.size,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      textColor: textColor ?? this.textColor,
      badgeColor: badgeColor ?? this.badgeColor,
      labelStyle: labelStyle ?? this.labelStyle,
      timeStyle: timeStyle ?? this.timeStyle,
      countStyle: countStyle ?? this.countStyle,
      borderRadius: borderRadius ?? this.borderRadius,
      shadows: shadows ?? this.shadows,
    );
  }
}