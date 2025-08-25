import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';

import '../services/photo_indexer.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? _controller;

  Set<Marker> _buildMarkers(List<PhotoPoint> points) {
    return points.map((p) {
      return Marker(
        markerId: MarkerId(p.id),
        position: LatLng(p.lat, p.lng),
        infoWindow: InfoWindow(
          title: p.date?.toLocal().toString().split('.').first ?? 'unknown',
          snippet:
          '(${p.lat.toStringAsFixed(5)}, ${p.lng.toStringAsFixed(5)})',
        ),
      );
    }).toSet();
  }

  Future<void> _moveToFirstPoint(List<PhotoPoint> points) async {
    if (_controller == null || points.isEmpty) return;
    final p = points.first;
    await _controller!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(p.lat, p.lng),
          zoom: 12,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PhotoIndexModel>(
      builder: (context, model, _) {
        final markers = _buildMarkers(model.points);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Photo Map Album'),
            actions: [
              IconButton(
                tooltip: '重新索引',
                icon: const Icon(Icons.refresh),
                onPressed: () async {
                  await model.rebuild();
                  if (mounted && model.points.isNotEmpty) {
                    _moveToFirstPoint(model.points);
                  }
                },
              ),
            ],
          ),
          body: Column(
            children: [
              // 顶部状态栏：总数、带定位数、错误
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Text('总数: ${model.total}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 12),
                    Text('带定位: ${model.points.length}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (model.error != null) ...[
                      const Icon(Icons.error_outline, size: 18),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          model.error!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ]
                  ],
                ),
              ),

              // 地图
              Expanded(
                child: GoogleMap(
                  initialCameraPosition: const CameraPosition(
                    target: LatLng(39.9042, 116.4074), // 先给北京
                    zoom: 4,
                  ),
                  markers: markers,
                  onMapCreated: (c) {
                    _controller = c;
                    // 地图创建后，如果有点位就移动到第一个
                    if (mounted && model.points.isNotEmpty) {
                      // 等地图初始化稳定一点再移动
                      Future.delayed(const Duration(milliseconds: 300), () {
                        _moveToFirstPoint(model.points);
                      });
                    }
                  },
                  myLocationEnabled: false, // 这里跟读取照片定位无关
                  myLocationButtonEnabled: false,
                  compassEnabled: true,
                  zoomControlsEnabled: false,
                ),
              ),
            ],
          ),
          floatingActionButton: (model.points.isEmpty)
              ? FloatingActionButton.extended(
            onPressed: () async {
              await model.rebuild();
              if (mounted && model.points.isNotEmpty) {
                _moveToFirstPoint(model.points);
              }
            },
            icon: const Icon(Icons.search),
            label: const Text('重新扫描'),
          )
              : null,
        );
      },
    );
  }
}
