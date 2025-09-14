import 'package:photo_manager/photo_manager.dart';

/// 照片点位数据模型
class PhotoPoint {
  final String id;
  final double lat;
  final double lng;
  final DateTime? date;
  final AssetEntity asset;

  PhotoPoint({
    required this.id,
    required this.lat,
    required this.lng,
    this.date,
    required this.asset,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PhotoPoint && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() {
    return 'PhotoPoint(id: $id, lat: $lat, lng: $lng, date: $date)';
  }
}