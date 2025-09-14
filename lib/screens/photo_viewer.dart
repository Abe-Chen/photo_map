import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

// 简单的图片缓存
class ImageCache {
  static final Map<String, Uint8List> _cache = {};
  
  static void add(String key, Uint8List data) {
    _cache[key] = data;
  }
  
  static Uint8List? get(String key) {
    return _cache[key];
  }
  
  static bool contains(String key) {
    return _cache.containsKey(key);
  }
}

class PhotoViewer extends StatefulWidget {
  final AssetEntity asset;
  
  const PhotoViewer({
    super.key, 
    required this.asset,
  });

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _animation;
  Uint8List? _thumbnailBytes;
  Uint8List? _fullImageBytes;
  bool _isLoadingFullImage = false;
  
  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _animation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );
    _animationController.forward();
    
    // 立即加载缩略图
    _loadThumbnail();
    // 然后加载原图
    _loadFullImage();
  }
  
  Future<void> _loadThumbnail() async {
    // 先检查缓存
    final String thumbnailKey = 'thumbnail_${widget.asset.id}';
    if (ImageCache.contains(thumbnailKey)) {
      setState(() {
        _thumbnailBytes = ImageCache.get(thumbnailKey);
      });
      return;
    }
    
    // 加载中等大小的缩略图 (比地图上的缩略图大，但比原图小)
    final thumbBytes = await widget.asset.thumbnailDataWithSize(
      const ThumbnailSize(800, 800),
    );
    
    if (thumbBytes != null && mounted) {
      setState(() {
        _thumbnailBytes = thumbBytes;
      });
      // 缓存缩略图
      ImageCache.add(thumbnailKey, thumbBytes);
    }
  }
  
  Future<void> _loadFullImage() async {
    if (_isLoadingFullImage) return;
    
    setState(() {
      _isLoadingFullImage = true;
    });
    
    // 先检查缓存
    final String fullImageKey = 'fullimage_${widget.asset.id}';
    if (ImageCache.contains(fullImageKey)) {
      setState(() {
        _fullImageBytes = ImageCache.get(fullImageKey);
        _isLoadingFullImage = false;
      });
      return;
    }
    
    // 加载原图
    final bytes = await widget.asset.originBytes;
    
    if (bytes != null && mounted) {
      setState(() {
        _fullImageBytes = bytes;
        _isLoadingFullImage = false;
      });
      // 缓存原图
      ImageCache.add(fullImageKey, bytes);
    } else if (mounted) {
      setState(() {
        _isLoadingFullImage = false;
      });
    }
  }
  
  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _onBackPressed() {
    _animationController.reverse().then((_) {
      Navigator.of(context).pop();
    });
  }

  Future<void> _shareImage() async {
    try {
      // 获取图片字节数据（优先使用原图，如果没有则使用缩略图）
      Uint8List? imageBytes = _fullImageBytes ?? _thumbnailBytes;
      
      if (imageBytes == null) {
        // 如果没有图片数据，尝试重新加载
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('图片正在加载中，请稍后再试')),
        );
        return;
      }
      
      // 获取临时目录
      final Directory tempDir = await getTemporaryDirectory();
      
      // 创建临时文件名（使用资源ID和时间戳确保唯一性）
      final String fileName = 'shared_image_${widget.asset.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final String filePath = '${tempDir.path}/$fileName';
      
      // 写入临时文件
      final File tempFile = File(filePath);
      await tempFile.writeAsBytes(imageBytes);
      
      // 创建XFile并分享
      final XFile xFile = XFile(filePath);
      
      // 获取图片的创建时间作为分享文案的一部分
      final DateTime? createDate = widget.asset.createDateTime;
      final String shareText = createDate != null 
          ? '分享照片 - 拍摄于 ${createDate.year}年${createDate.month}月${createDate.day}日'
          : '分享照片';
      
      // 分享图片
      await Share.shareXFiles(
        [xFile],
        text: shareText,
      );
      
      // 延迟删除临时文件（给系统足够时间处理分享）
      Future.delayed(const Duration(seconds: 30), () {
        if (tempFile.existsSync()) {
          tempFile.delete().catchError((e) {
            // 忽略删除错误，系统会自动清理临时文件
          });
        }
      });
      
    } catch (e) {
      // 分享失败时显示错误信息
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        _onBackPressed();
        return false; // 阻止默认返回行为，由我们控制动画
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black.withOpacity(0.5),
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          titleTextStyle: const TextStyle(color: Colors.white, fontSize: 18),
          title: const Text('照片预览'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _onBackPressed,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: _shareImage,
              tooltip: '分享图片',
            ),
          ],
        ),
        body: GestureDetector(
          onTap: () {
            // 点击图片区域也可以返回
            _onBackPressed();
          },
          child: Hero(
            tag: 'photo_${widget.asset.id}',
            child: AnimatedBuilder(
              animation: _animation,
              builder: (context, child) {
                return Stack(
                  children: [
                    // 显示图片（优先显示原图，如果原图未加载完成则显示缩略图）
                    if (_fullImageBytes != null || _thumbnailBytes != null)
                      Center(
                        child: InteractiveViewer(
                          minScale: 0.5,
                          maxScale: 3.0,
                          child: Opacity(
                            opacity: _animation.value,
                            child: Image.memory(
                              _fullImageBytes ?? _thumbnailBytes!,
                              fit: BoxFit.contain,
                              width: double.infinity,
                              height: double.infinity,
                              // 如果是缩略图，使用低质量过滤以提高性能
                              filterQuality: _fullImageBytes != null 
                                  ? FilterQuality.high 
                                  : FilterQuality.medium,
                            ),
                          ),
                        ),
                      ),
                    
                    // 加载指示器 - 仅在没有任何图片可显示时显示
                    if (_thumbnailBytes == null && _fullImageBytes == null)
                      const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                      
                    // 原图加载指示器 - 当显示缩略图且原图正在加载时，显示在角落
                    if (_isLoadingFullImage && _thumbnailBytes != null && _fullImageBytes == null)
                      const Positioned(
                        right: 16,
                        bottom: 16,
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}