import 'package:google_maps_flutter/google_maps_flutter.dart' as gmap;
import 'package:photo_manager/photo_manager.dart';

class CountryAlbum {
  final String countryCode;
  final String countryName;
  final List<AssetEntity> assets;
  final AssetEntity cover;
  final gmap.LatLng centroid;

  CountryAlbum({
    required this.countryCode,
    required this.countryName,
    required this.assets,
    required this.cover,
    required this.centroid,
  });
}
