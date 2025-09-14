import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:device_info_plus/device_info_plus.dart';

class PermissionManager {
  static final PermissionManager _instance = PermissionManager._internal();
  factory PermissionManager() => _instance;
  PermissionManager._internal();

  bool _isAndroid13Plus = false;
  bool _initialized = false;

  /// 初始化权限管理器
  Future<void> initialize() async {
    if (_initialized) return;
    
    if (Platform.isAndroid) {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      _isAndroid13Plus = androidInfo.version.sdkInt >= 33;
    }
    
    _initialized = true;
  }

  /// 确保媒体权限已授予
  /// 返回 true 表示权限已授予，false 表示权限被拒绝
  Future<bool> ensureMediaPermissions() async {
    await initialize();
    
    try {
      // 1. 检查并申请相册权限
      final bool galleryGranted = await _ensureGalleryPermission();
      if (!galleryGranted) {
        debugPrint('相册权限未授予');
        return false;
      }
      
      // 2. 检查并申请媒体位置权限
      final bool locationGranted = await _ensureMediaLocationPermission();
      if (!locationGranted) {
        debugPrint('媒体位置权限未授予，但继续执行（可选权限）');
      }
      
      debugPrint('权限检查完成: 相册=$galleryGranted, 媒体位置=$locationGranted');
      return galleryGranted;
    } catch (e) {
      debugPrint('权限检查失败: $e');
      return false;
    }
  }

  /// 检查并申请相册权限
  Future<bool> _ensureGalleryPermission() async {
    if (Platform.isAndroid) {
      if (_isAndroid13Plus) {
        // Android 13+ 使用 READ_MEDIA_IMAGES
        final status = await Permission.photos.status;
        if (status.isGranted) return true;
        
        final result = await Permission.photos.request();
        return result.isGranted;
      } else {
        // Android 12 及以下使用 READ_EXTERNAL_STORAGE
        final status = await Permission.storage.status;
        if (status.isGranted) return true;
        
        final result = await Permission.storage.request();
        return result.isGranted;
      }
    } else if (Platform.isIOS) {
      // iOS 使用 PhotoManager 的权限系统
      final ps = await PhotoManager.requestPermissionExtend();
      return ps.isAuth || ps.hasAccess;
    }
    
    return false;
  }

  /// 检查并申请媒体位置权限
  Future<bool> _ensureMediaLocationPermission() async {
    if (Platform.isAndroid) {
      // Android 需要 ACCESS_MEDIA_LOCATION 权限来读取 EXIF 位置信息
      final status = await Permission.accessMediaLocation.status;
      if (status.isGranted) return true;
      
      final result = await Permission.accessMediaLocation.request();
      return result.isGranted;
    }
    
    // iOS 不需要额外的媒体位置权限
    return true;
  }

  /// 检查当前权限状态（不申请）
  Future<PermissionStatus> checkCurrentPermissionStatus() async {
    await initialize();
    
    try {
      if (Platform.isAndroid) {
        if (_isAndroid13Plus) {
          final photosStatus = await Permission.photos.status;
          final mediaLocationStatus = await Permission.accessMediaLocation.status;
          
          if (photosStatus.isGranted) {
            return PermissionStatus(
              galleryGranted: true,
              mediaLocationGranted: mediaLocationStatus.isGranted,
            );
          } else {
            return PermissionStatus(
              galleryGranted: false,
              mediaLocationGranted: mediaLocationStatus.isGranted,
            );
          }
        } else {
          final storageStatus = await Permission.storage.status;
          final mediaLocationStatus = await Permission.accessMediaLocation.status;
          
          return PermissionStatus(
            galleryGranted: storageStatus.isGranted,
            mediaLocationGranted: mediaLocationStatus.isGranted,
          );
        }
      } else if (Platform.isIOS) {
        final ps = await PhotoManager.requestPermissionExtend();
        return PermissionStatus(
          galleryGranted: ps.isAuth || ps.hasAccess,
          mediaLocationGranted: true, // iOS 不需要额外权限
        );
      }
    } catch (e) {
      debugPrint('检查权限状态失败: $e');
    }
    
    return PermissionStatus(
      galleryGranted: false,
      mediaLocationGranted: false,
    );
  }

  /// 打开应用设置页面
  Future<bool> openAppSettings() async {
    return await openAppSettings();
  }
}

/// 权限状态类
class PermissionStatus {
  final bool galleryGranted;
  final bool mediaLocationGranted;
  
  const PermissionStatus({
    required this.galleryGranted,
    required this.mediaLocationGranted,
  });
  
  bool get hasRequiredPermissions => galleryGranted;
  bool get hasAllPermissions => galleryGranted && mediaLocationGranted;
  
  @override
  String toString() {
    return 'PermissionStatus(gallery: $galleryGranted, mediaLocation: $mediaLocationGranted)';
  }
}