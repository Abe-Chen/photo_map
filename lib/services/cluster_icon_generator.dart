import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 聚类图标生成器
/// 支持多种像素尺寸，根据设备像素比自动选择最佳尺寸
class ClusterIconGenerator {
  // 支持的像素尺寸
  static const List<int> _supportedSizes = [48, 64, 80];
  
  // BitmapDescriptor缓存：sizeKey -> descriptor
  static final Map<String, BitmapDescriptor> _iconCache = <String, BitmapDescriptor>{};
  
  /// 根据设备像素比选择最佳尺寸
  /// [devicePixelRatio] 设备像素比
  static int _selectOptimalSize(double devicePixelRatio) {
    if (devicePixelRatio <= 1.5) {
      return 48; // 低密度屏幕
    } else if (devicePixelRatio <= 2.5) {
      return 64; // 中密度屏幕
    } else {
      return 80; // 高密度屏幕
    }
  }
  
  /// 生成聚类图标
  /// [count] 聚类中的点数量
  /// [devicePixelRatio] 设备像素比
  /// [color] 气泡颜色，默认为蓝色
  /// [thumbnailBytes] 可选的缩略图字节数据，将显示在右下角
  static Future<BitmapDescriptor> generateClusterIcon(
    int count, {
    required double devicePixelRatio,
    Color color = Colors.blue,
    Uint8List? thumbnailBytes,
  }) async {
    final int size = _selectOptimalSize(devicePixelRatio);
    final String thumbnailHash = thumbnailBytes != null ? thumbnailBytes.hashCode.toString() : 'none';
    final String cacheKey = '${count}_${size}_${color.value}_$thumbnailHash';
    
    // 检查缓存
    if (_iconCache.containsKey(cacheKey)) {
      return _iconCache[cacheKey]!;
    }
    
    // 生成新图标
    final BitmapDescriptor descriptor = await _createClusterIcon(
      count,
      size,
      color,
      thumbnailBytes,
    );
    
    // 缓存图标
    _iconCache[cacheKey] = descriptor;
    
    return descriptor;
  }
  
  /// 创建聚类图标
  /// [count] 聚类中的点数量
  /// [size] 图标像素尺寸
  /// [color] 气泡颜色
  /// [thumbnailBytes] 可选的缩略图字节数据
  static Future<BitmapDescriptor> _createClusterIcon(
    int count,
    int size,
    Color color,
    Uint8List? thumbnailBytes,
  ) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final double radius = size / 2.0;
    final Offset center = Offset(radius, radius);
    
    // 绘制外圈阴影
    final Paint shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0);
    canvas.drawCircle(
      center.translate(1, 1), // 阴影偏移
      radius - 1,
      shadowPaint,
    );
    
    // 绘制主圆形背景
    final Paint backgroundPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius - 2, backgroundPaint);
    
    // 绘制边框
    final Paint borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, radius - 2, borderPaint);
    
    // 绘制文字
    final String text = _formatCount(count);
    final TextStyle textStyle = TextStyle(
      color: Colors.white,
      fontSize: _calculateFontSize(size, text.length),
      fontWeight: FontWeight.bold,
      fontFamily: 'Roboto',
    );
    
    final TextSpan textSpan = TextSpan(
      text: text,
      style: textStyle,
    );
    
    final TextPainter textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    
    textPainter.layout();
    
    // 计算文字居中位置
    final Offset textOffset = Offset(
      center.dx - textPainter.width / 2,
      center.dy - textPainter.height / 2,
    );
    
    textPainter.paint(canvas, textOffset);
    
    // 绘制右下角缩略图（如果提供）
    if (thumbnailBytes != null) {
      await _drawThumbnailOverlay(
        canvas,
        thumbnailBytes,
        size,
        center,
        radius,
      );
    }
    
    // 转换为图片
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(size, size);
    
    final ByteData? byteData = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    
    image.dispose();
    
    if (byteData == null) {
      throw Exception('Failed to convert cluster icon to byte data');
    }
    
    return BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
  }
  
  /// 格式化计数显示
  /// [count] 原始计数
  static String _formatCount(int count) {
    if (count < 1000) {
      return count.toString();
    } else if (count < 10000) {
      return '${(count / 1000).toStringAsFixed(1)}K';
    } else if (count < 1000000) {
      return '${(count / 1000).round()}K';
    } else {
      return '${(count / 1000000).toStringAsFixed(1)}M';
    }
  }
  
  /// 根据图标尺寸和文字长度计算字体大小
  /// [iconSize] 图标像素尺寸
  /// [textLength] 文字长度
  static double _calculateFontSize(int iconSize, int textLength) {
    double baseFontSize;
    
    switch (iconSize) {
      case 48:
        baseFontSize = 12.0;
        break;
      case 64:
        baseFontSize = 16.0;
        break;
      case 80:
        baseFontSize = 20.0;
        break;
      default:
        baseFontSize = iconSize * 0.25; // 默认为图标尺寸的25%
    }
    
    // 根据文字长度调整字体大小
    if (textLength >= 4) {
      baseFontSize *= 0.8; // 长文字缩小20%
    } else if (textLength >= 3) {
      baseFontSize *= 0.9; // 中等长度文字缩小10%
    }
    
    return baseFontSize;
  }
  
  /// 清空图标缓存
  static void clearCache() {
    _iconCache.clear();
  }
  
  /// 获取缓存统计信息
  static Map<String, dynamic> getCacheStats() {
    return {
      'cachedIcons': _iconCache.length,
      'supportedSizes': _supportedSizes,
      'cacheKeys': _iconCache.keys.toList(),
    };
  }
  
  /// 绘制右下角缩略图叠加层
  /// [canvas] 画布
  /// [thumbnailBytes] 缩略图字节数据
  /// [iconSize] 图标总尺寸
  /// [center] 图标中心点
  /// [radius] 图标半径
  static Future<void> _drawThumbnailOverlay(
    Canvas canvas,
    Uint8List thumbnailBytes,
    int iconSize,
    Offset center,
    double radius,
  ) async {
    try {
      // 解码缩略图
      final ui.Codec codec = await ui.instantiateImageCodec(thumbnailBytes);
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ui.Image thumbnailImage = frameInfo.image;
      
      // 计算缩略图尺寸和位置（右下角，约为图标尺寸的1/3）
      final double thumbnailSize = iconSize * 0.35;
      final double thumbnailRadius = thumbnailSize / 2;
      
      // 右下角位置
      final Offset thumbnailCenter = Offset(
        center.dx + radius * 0.5,
        center.dy + radius * 0.5,
      );
      
      // 绘制缩略图背景圆形（白色边框）
      final Paint thumbnailBorderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(thumbnailCenter, thumbnailRadius + 2, thumbnailBorderPaint);
      
      // 创建圆形裁剪路径
      canvas.save();
      final Path clipPath = Path()
        ..addOval(Rect.fromCircle(
          center: thumbnailCenter,
          radius: thumbnailRadius,
        ));
      canvas.clipPath(clipPath);
      
      // 绘制缩略图
      final Rect thumbnailRect = Rect.fromCenter(
        center: thumbnailCenter,
        width: thumbnailSize,
        height: thumbnailSize,
      );
      
      canvas.drawImageRect(
        thumbnailImage,
        Rect.fromLTWH(0, 0, thumbnailImage.width.toDouble(), thumbnailImage.height.toDouble()),
        thumbnailRect,
        Paint(),
      );
      
      canvas.restore();
      
      // 绘制缩略图边框
      final Paint thumbnailOutlinePaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(thumbnailCenter, thumbnailRadius, thumbnailOutlinePaint);
      
      thumbnailImage.dispose();
    } catch (e) {
      // 如果缩略图绘制失败，静默忽略
      print('Failed to draw thumbnail overlay: $e');
    }
  }
  
  /// 预生成常用图标
  /// [devicePixelRatio] 设备像素比
  /// [color] 气泡颜色
  /// [thumbnailBytes] 可选的缩略图字节数据
  static Future<void> preloadCommonIcons(
    double devicePixelRatio, {
    Color color = Colors.blue,
    Uint8List? thumbnailBytes,
  }) async {
    // 预生成常用的聚类数量图标
    final List<int> commonCounts = [2, 3, 5, 10, 20, 50, 100, 500, 1000];
    
    for (final count in commonCounts) {
      await generateClusterIcon(
        count,
        devicePixelRatio: devicePixelRatio,
        color: color,
        thumbnailBytes: thumbnailBytes,
      );
    }
  }
}