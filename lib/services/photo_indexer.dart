import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:exif/exif.dart';

class PhotoPoint {
  final String id;
  final double lat;
  final double lng;
  final DateTime? date;

  PhotoPoint({
    required this.id,
    required this.lat,
    required this.lng,
    required this.date,
  });
}

class PhotoIndexModel extends ChangeNotifier {
  final List<PhotoPoint> _points = [];
  int _total = 0;
  String? _error;

  List<PhotoPoint> get points => List.unmodifiable(_points);
  int get total => _total;
  String? get error => _error;

  Future<void> buildIndex() async {
    _points.clear();
    _total = 0;
    _error = null;

    try {
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        filterOption: FilterOptionGroup(
          orders: [OrderOption(type: OrderOptionType.createDate, asc: false)],
        ),
      );

      int totalAssets = 0;
      final List<AssetEntity> allAssets = [];

      for (final album in albums) {
        final count = await album.assetCountAsync;
        totalAssets += count;

        const pageSize = 200;
        int page = 0;
        while (true) {
          final batch = await album.getAssetListPaged(page: page, size: pageSize);
          if (batch.isEmpty) break;
          allAssets.addAll(batch);
          page++;
        }
      }

      _total = totalAssets;

      // 先用系统给的经纬度
      final List<_AssetWithMaybeLL> prelim = [];
      for (final a in allAssets) {
        final lat = a.latitude;
        final lng = a.longitude;
        final has = lat != null &&
            lng != null &&
            lat != 0.0 &&
            lng != 0.0 &&
            !lat.isNaN &&
            !lng.isNaN;
        prelim.add(_AssetWithMaybeLL(
          asset: a,
          lat: has ? lat : null,
          lng: has ? lng : null,
        ));
      }

      // 已有坐标
      final List<PhotoPoint> located = [];
      for (final item in prelim.where((x) => x.lat != null && x.lng != null)) {
        located.add(PhotoPoint(
          id: item.asset.id,
          lat: item.lat!,
          lng: item.lng!,
          date: item.asset.createDateTime,
        ));
      }

      // 对没有坐标的做 EXIF 兜底（只处理最新 300 张避免卡顿/内存压）
      const int exifFallbackLimit = 300;
      final List<_AssetWithMaybeLL> needFallback = prelim
          .where((x) => x.lat == null || x.lng == null)
          .take(exifFallbackLimit)
          .toList();

      if (needFallback.isNotEmpty) {
        debugPrint('开始 EXIF 兜底解析（最多 $exifFallbackLimit 张）...');
      }

      for (final item in needFallback) {
        final ll = await _tryReadLatLngFromExif(item.asset);
        if (ll != null) {
          located.add(PhotoPoint(
            id: item.asset.id,
            lat: ll.$1,
            lng: ll.$2,
            date: item.asset.createDateTime,
          ));
        }
      }

      // 去重
      final seen = <String>{};
      for (final p in located) {
        final key = '${p.id}@${p.lat},${p.lng}';
        if (seen.add(key)) {
          _points.add(p);
        }
      }

      // —— 诊断输出 —— //
      debugPrint('总共读取到图片数量: $_total');
      debugPrint('其中带定位的数量: ${_points.length}');
      if (_points.isEmpty) {
        debugPrint('诊断: 没有任何带经纬度的照片。可能原因：');
        debugPrint('1) 拍照时“位置标签/Location tags”关闭或相机没系统定位权限；');
        if (Platform.isAndroid) {
          debugPrint('2) 机型/系统没把 MediaStore 纬经度回给我们，不过已做 EXIF 兜底；');
        }
        debugPrint('3) 照片来源于微信/下载/截图，通常不带 EXIF GPS；');
      } else {
        for (int i = 0; i < _points.length && i < 5; i++) {
          final p = _points[i];
          debugPrint('第${i + 1}条带定位: id=${p.id}, '
              '(${p.lat.toStringAsFixed(6)}, ${p.lng.toStringAsFixed(6)}), '
              'date=${p.date}');
        }
      }
      // —— 诊断输出 —— //

      notifyListeners();
    } catch (e, st) {
      _error = '构建索引失败: $e';
      debugPrint('构建索引失败: $e\n$st');
      notifyListeners();
    }
  }

  Future<void> rebuild() => buildIndex();

  /// 读取 EXIF GPS（需要 ACCESS_MEDIA_LOCATION 才能拿到带 GPS 的完整 EXIF）
  Future<(double, double)?> _tryReadLatLngFromExif(AssetEntity a) async {
    try {
      final bytes = await a.originBytes;
      if (bytes == null) return null;

      final tags = await readExifFromBytes(bytes);
      if (tags.isEmpty) return null;

      final lat = _parseExifLatLng(
        tags['GPS GPSLatitude'],
        tags['GPS GPSLatitudeRef'],
      );
      final lng = _parseExifLatLng(
        tags['GPS GPSLongitude'],
        tags['GPS GPSLongitudeRef'],
      );

      if (lat != null && lng != null) {
        return (lat, lng);
      }
    } catch (_) {
      // 忽略单张失败
    }
    return null;
  }

  /// 解析 EXIF 的度/分/秒（DMS）字符串
  double? _parseExifLatLng(IfdTag? valueTag, IfdTag? refTag) {
    if (valueTag == null) return null;

    final printable = (valueTag.printable ?? '').trim();
    if (printable.isEmpty) return null;

    // 去掉方括号/多余空白
    final s = printable
        .replaceAll('[', '')
        .replaceAll(']', '')
        .replaceAll('"', '')
        .trim();

    // 拆分成 D/M/S 三段
    final parts = s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.length < 3) return null;

    double parsePart(String token) {
      if (token.contains('/')) {
        final fr = token.split('/');
        final nume = double.tryParse(fr[0].trim());
        final deno = double.tryParse(fr.length > 1 ? fr[1].trim() : '1');
        if (nume == null || deno == null || deno == 0) return double.nan;
        return nume / deno;
      }
      return double.tryParse(token) ?? double.nan;
    }

    final d = parsePart(parts[0]);
    final m = parsePart(parts[1]);
    final s3 = parsePart(parts[2]);
    if (d.isNaN || m.isNaN || s3.isNaN) return null;

    var dec = d + (m / 60.0) + (s3 / 3600.0);

    final ref = (refTag?.printable ?? '').toUpperCase().replaceAll('"', '').trim();
    if (ref == 'S' || ref == 'W') dec = -dec;

    return dec;
  }
}

class _AssetWithMaybeLL {
  final AssetEntity asset;
  final double? lat;
  final double? lng;
  _AssetWithMaybeLL({required this.asset, this.lat, this.lng});
}
