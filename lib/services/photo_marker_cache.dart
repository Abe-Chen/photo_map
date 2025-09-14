import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'thumb_task_manager.dart';

/// 照片标记缓存类，使用DefaultCacheManager实现持久化缓存
class PhotoMarkerCache {
  static const int _thumbnailSize = 144; // 缩略图尺寸
  
  // 持久化缓存管理器
  static final CacheManager _cacheManager = DefaultCacheManager();
  
  // 内存缓存：BitmapDescriptor对象缓存
  final Map<String, BitmapDescriptor> _memoryCache = <String, BitmapDescriptor>{};
  final List<String> _memoryAccessOrder = <String>[]; // 内存缓存访问顺序
  static const int _memoryCacheSize = 50; // 内存缓存大小
  
  // 任务管理器，控制并发解码任务
  final ThumbTaskManager _taskManager = ThumbTaskManager(maxConcurrent: 4);
  
  // 正在加载的请求映射，避免重复请求
  final Map<String, Completer<BitmapDescriptor?>> _inflightRequests = <String, Completer<BitmapDescriptor?>>{};
  
  /// 获取照片的BitmapDescriptor
  /// [assetId] 照片资源ID
  /// [width] 缩略图宽度，默认144
  /// [height] 缩略图高度，默认144
  Future<BitmapDescriptor?> getBitmapDescriptor(
    String assetId, {
    int width = _thumbnailSize,
    int height = _thumbnailSize,
  }) async {
    final String cacheKey = '$assetId@${width}x$height';
    
    // 1. 先查内存缓存
    if (_memoryCache.containsKey(cacheKey)) {
      _updateMemoryAccessOrder(cacheKey);
      return _memoryCache[cacheKey];
    }
    
    // 2. 检查是否已有相同请求在进行中
    if (_inflightRequests.containsKey(cacheKey)) {
      return await _inflightRequests[cacheKey]!.future;
    }
    
    // 3. 创建新的加载请求
    final Completer<BitmapDescriptor?> completer = Completer<BitmapDescriptor?>();
    _inflightRequests[cacheKey] = completer;
    
    try {
      // 4. 使用任务管理器调度解码任务
      final ThumbTaskToken<BitmapDescriptor?> token = _taskManager.schedule(
        cacheKey,
        () => _loadWithCascade(cacheKey, assetId, width, height),
      );
      
      final BitmapDescriptor? descriptor = await token.future;
      completer.complete(descriptor);
      return descriptor;
    } catch (e) {
      if (e is TaskCancelledException) {
        // 任务被取消，返回null
        completer.complete(null);
        return null;
      }
      completer.completeError(e);
      return null;
    } finally {
      // 5. 清理inflight请求
      _inflightRequests.remove(cacheKey);
    }
  }
  
  /// 级联加载：内存 → 磁盘 → 解码生成 → 双写缓存
  Future<BitmapDescriptor?> _loadWithCascade(String cacheKey, String assetId, int width, int height) async {
    try {
      // 1. 查磁盘缓存
      final FileInfo? fileInfo = await _cacheManager.getFileFromCache(cacheKey);
      if (fileInfo != null) {
        // 从磁盘缓存加载
        final Uint8List diskData = await fileInfo.file.readAsBytes();
        final BitmapDescriptor descriptor = await _createBitmapDescriptor(diskData);
        // 回填内存缓存
        _putToMemoryCache(cacheKey, descriptor);
        return descriptor;
      }
      
      // 2. 磁盘缓存未命中，从AssetEntity解码生成
      final Uint8List? thumbData = await _loadThumbnailFromAsset(assetId, width, height);
      if (thumbData == null) return null;
      
      // 3. 双写缓存：先写磁盘，再写内存
      await _cacheManager.putFile(cacheKey, thumbData);
      final BitmapDescriptor descriptor = await _createBitmapDescriptor(thumbData);
      _putToMemoryCache(cacheKey, descriptor);
      
      return descriptor;
    } catch (e) {
      debugPrint('Failed to load thumbnail for $assetId: $e');
      return null;
    }
  }
  
  /// 从AssetEntity加载缩略图数据
  Future<Uint8List?> _loadThumbnailFromAsset(String assetId, int width, int height) async {
    try {
      // 获取AssetEntity
      final AssetEntity? asset = await AssetEntity.fromId(assetId);
      if (asset == null) return null;
      
      // 获取缩略图数据
      return await asset.thumbnailDataWithSize(
        ThumbnailSize(width, height),
      );
    } catch (e) {
      debugPrint('Failed to load asset thumbnail for $assetId: $e');
      return null;
    }
  }
  
  /// 将图片数据转换为BitmapDescriptor
  Future<BitmapDescriptor> _createBitmapDescriptor(Uint8List imageData) async {
    final ui.Codec codec = await ui.instantiateImageCodec(
      imageData,
      targetWidth: _thumbnailSize,
      targetHeight: _thumbnailSize,
    );
    final ui.FrameInfo frameInfo = await codec.getNextFrame();
    final ui.Image image = frameInfo.image;
    
    // 创建圆形遮罩的图片
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final Size size = Size(_thumbnailSize.toDouble(), _thumbnailSize.toDouble());
    
    // 绘制圆形背景
    final Paint backgroundPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width / 2,
      backgroundPaint,
    );
    
    // 绘制圆形图片
    final Path clipPath = Path()
      ..addOval(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.clipPath(clipPath);
    
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint(),
    );
    
    // 绘制边框
    final Paint borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width / 2 - 1,
      borderPaint,
    );
    
    final ui.Picture picture = recorder.endRecording();
    final ui.Image finalImage = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    
    final ByteData? byteData = await finalImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    
    image.dispose();
    finalImage.dispose();
    
    if (byteData == null) {
      throw Exception('Failed to convert image to byte data');
    }
    
    return BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
  }
  
  /// 将BitmapDescriptor放入内存缓存
  void _putToMemoryCache(String key, BitmapDescriptor descriptor) {
    // 如果内存缓存已满，移除最久未使用的项
    if (_memoryCache.length >= _memoryCacheSize) {
      final String oldestKey = _memoryAccessOrder.first;
      _memoryCache.remove(oldestKey);
      _memoryAccessOrder.removeAt(0);
    }
    
    _memoryCache[key] = descriptor;
    _memoryAccessOrder.add(key);
  }
  
  /// 更新内存缓存访问顺序（LRU）
  void _updateMemoryAccessOrder(String key) {
    _memoryAccessOrder.remove(key);
    _memoryAccessOrder.add(key);
  }
  
  /// 取消指定集合之外的所有任务
  void cancelTasksNotIn(Set<String> keepKeys) {
    _taskManager.cancelTasksNotIn(keepKeys);
  }
  
  /// 清空缓存
  void clear() {
    _memoryCache.clear();
    _memoryAccessOrder.clear();
    _inflightRequests.clear();
    _taskManager.cancelAllTasks();
    _cacheManager.emptyCache(); // 清空磁盘缓存
  }
  
  /// 获取缓存统计信息
  Map<String, dynamic> getCacheStats() {
    final taskStats = _taskManager.getStats();
    return {
      'memoryCacheSize': _memoryCache.length,
      'maxMemoryCacheSize': _memoryCacheSize,
      'inflightRequests': _inflightRequests.length,
      'taskManager': taskStats,
    };
  }
}