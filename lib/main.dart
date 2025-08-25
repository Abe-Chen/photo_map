import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:photo_manager/photo_manager.dart' as pm;
import 'package:permission_handler/permission_handler.dart';

import 'services/photo_indexer.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const App());
}

/// 你项目里已有的 App 外壳，如果没有就用一个最简单的包起来
class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Photo Map Album',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: '照片定位地图'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final PhotoIndexModel _model = PhotoIndexModel();

  gmaps.GoogleMapController? _mapController;
  final Set<gmaps.Marker> _markers = {};
  bool _mapMyLocationEnabled = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      // 1) 申请相册权限（含 ACCESS_MEDIA_LOCATION）
      final pm.PermissionState ps = await pm.PhotoManager.requestPermissionExtend();

// 兼容 3.x：hasAccess 为 true 时表示“可访问”（含 Limited）；isAuth 为 true 表示“完全授权”
      final bool galleryGranted =
          (ps.isAuth == true) || (ps.hasAccess == true);

// 受限访问下继续索引，但给个温和提示（不阻断）
      if (!galleryGranted) {
        setState(() {
          _loading = false;
          _error = '相册访问权限未授予，请在系统设置中开启。';
        });
        return;
      } else {
        // 如果是受限访问，可以提示一下（不必中断）
        if (ps.isAuth != true && ps.hasAccess == true) {
          debugPrint('相册为“受限访问”，只会索引你授予的那部分照片。');
        }
      }


      // 2) 申请前台定位权限（用于地图“我的位置”小蓝点，可选）
      final status = await Permission.locationWhenInUse.request();
      _mapMyLocationEnabled = status.isGranted;

      // 3) 构建照片索引（含 EXIF 兜底）
      await _model.buildIndex();

      // 4) 把点位转成 Marker
      _rebuildMarkers();

      // 5) 如有点位，移动相机
      if (_model.points.isNotEmpty && _mapController != null) {
        final first = _model.points.first;
        unawaited(_mapController!.animateCamera(
          gmaps.CameraUpdate.newCameraPosition(
            gmaps.CameraPosition(
              target: gmaps.LatLng(first.lat, first.lng),
              zoom: 13,
            ),
          ),
        ));
      }

      setState(() {
        _loading = false;
        _error = _model.error;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '初始化失败：$e';
      });
    }
  }

  void _rebuildMarkers() {
    _markers.clear();
    for (final p in _model.points) {
      _markers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId(p.id),
          position: gmaps.LatLng(p.lat, p.lng),
          infoWindow: gmaps.InfoWindow(
            title: p.date?.toLocal().toString() ?? '无时间信息',
          ),
        ),
      );
    }
    setState(() {});
  }

  Future<void> _onRefresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _model.rebuild();
    _rebuildMarkers();
    setState(() {
      _loading = false;
      _error = _model.error;
    });

    if (_model.points.isNotEmpty && _mapController != null) {
      final first = _model.points.first;
      unawaited(_mapController!.animateCamera(
        gmaps.CameraUpdate.newLatLngZoom(
          gmaps.LatLng(first.lat, first.lng),
          13,
        ),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPoints = _model.points.isNotEmpty;

    // 如果没有点，用一个温和的默认相机位置（北京）
    final initialTarget = hasPoints
        ? gmaps.LatLng(_model.points.first.lat, _model.points.first.lng)
        : const gmaps.LatLng(39.9042, 116.4074);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Stack(
        children: [
          // 地图
          Positioned.fill(
            child: gmaps.GoogleMap(
              initialCameraPosition: gmaps.CameraPosition(
                target: initialTarget,
                zoom: hasPoints ? 12 : 9,
              ),
              myLocationEnabled: _mapMyLocationEnabled,
              myLocationButtonEnabled: true,
              markers: _markers,
              onMapCreated: (c) {
                _mapController = c;
              },
            ),
          ),

          // 顶部信息条
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _loading
                            ? '正在索引照片…'
                            : _error != null
                            ? _error!
                            : '共 ${_model.total} 张照片，含定位 ${_model.points.length} 张',
                        style: const TextStyle(color: Colors.white),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_loading)
                      const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // 无数据时的友好提示
          if (!_loading && _error == null && !hasPoints)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Text(
                  '没有发现带经纬度的照片。\n可能是拍照时关闭了“位置标签”，或图片来自下载/截图。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
        ],
      ),

      // 右下角刷新
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _onRefresh,
        label: const Text('刷新'),
        icon: const Icon(Icons.refresh),
      ),
    );
  }
}
