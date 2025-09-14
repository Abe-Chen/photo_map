import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:google_maps_flutter/google_maps_flutter.dart' show BitmapDescriptor;
import 'package:photo_manager/photo_manager.dart' as pm;
import 'package:permission_handler/permission_handler.dart';

import 'services/photo_indexer.dart';
import 'services/permission_manager.dart';
import 'widgets/ui_utils.dart';
import 'screens/photo_viewer.dart';

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

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  final PhotoIndexModel _model = PhotoIndexModel();
  final PermissionManager _permissionManager = PermissionManager();

  gmaps.GoogleMapController? _mapController;
  final Set<gmaps.Marker> _markers = {};
  bool _mapMyLocationEnabled = false;
  bool _loading = true;
  String? _error;
  bool _permissionGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _model.addListener(_onModelChanged);
    _bootstrap();
  }
  
  void _onModelChanged() {
    setState(() {});
    
    // 如果索引刚完成且有新的点位，自动重建标记
    if (!_model.isIndexing && _model.points.isNotEmpty && _markers.isEmpty) {
      debugPrint('索引完成，自动重建地图标记');
      _rebuildMarkers();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _model.removeListener(_onModelChanged);
    _model.stopChangeNotify(); // 停止媒体库变更监听
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // 应用恢复时进行轻量增量刷新
      _model.rebuildRecent(minutes: 2);
      // 同时检查权限状态
      _checkPermissionsAndRefresh();
    }
  }

  /// 检查权限状态并在需要时刷新
  Future<void> _checkPermissionsAndRefresh() async {
    final status = await _permissionManager.checkCurrentPermissionStatus();
    
    // 如果权限状态发生变化，重新初始化
    if (status.hasRequiredPermissions != _permissionGranted) {
      debugPrint('权限状态变化，重新初始化: ${status.hasRequiredPermissions}');
      await _bootstrap();
    }
  }

  Future<void> _bootstrap() async {
    try {
      setState(() {
        _loading = true;
        _error = null;
      });

      // 1) 使用新的权限管理器申请相册权限
      final bool permissionGranted = await _permissionManager.ensureMediaPermissions();
      _permissionGranted = permissionGranted;
      
      if (!permissionGranted) {
        setState(() {
          _loading = false;
          _error = '相册访问权限未授予，请在系统设置中开启后返回应用。';
        });
        return;
      }

      // 2) 申请前台定位权限（用于地图"我的位置"小蓝点，可选）
      final status = await Permission.locationWhenInUse.request();
      _mapMyLocationEnabled = status.isGranted;

      // 3) 权限获取成功后立即构建照片索引
      await _model.buildIndex();
      
      // 4) 启动媒体库变更监听
      await _model.startChangeNotify();

      // 5) 把点位转成 Marker
      await _rebuildMarkers();

      // 6) 如有点位，移动相机
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

  Future<void> _rebuildMarkers() async {
    debugPrint('=== 开始重建地图标记，共 ${_model.points.length} 个点位 ===');
    _markers.clear();
    
    for (int i = 0; i < _model.points.length; i++) {
      final p = _model.points[i];
      try {
        // 获取照片缩略图
        final thumbnailBytes = await _model.getThumbnail(p.id);
        
        // 如果有缩略图，使用缩略图作为标记；否则使用默认标记
        final BitmapDescriptor icon = thumbnailBytes != null 
            ? await bitmapFromBytes(thumbnailBytes, circle: true, target: 120)
            : BitmapDescriptor.defaultMarker;
        
        _markers.add(
          gmaps.Marker(
            markerId: gmaps.MarkerId(p.id),
            position: gmaps.LatLng(p.lat, p.lng),
            icon: icon,
            onTap: () {
              // 点击标记时打开照片查看器
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => PhotoViewer(asset: p.asset!),
                ),
              );
            },
          ),
        );
        
        // 每处理100个标记输出一次进度
        if ((i + 1) % 100 == 0) {
          debugPrint('已处理 ${i + 1}/${_model.points.length} 个标记');
        }
      } catch (e) {
        debugPrint('处理标记失败 ${p.id}: $e');
        // 即使单个标记失败，也继续处理其他标记
      }
    }
    
    debugPrint('=== 标记重建完成，共生成 ${_markers.length} 个标记 ===');
    setState(() {});
  }

  Future<void> _onRefresh() async {
    // 重新执行完整的初始化流程，包括权限检查
    await _bootstrap();
  }
  
  String _getStatusText() {
    if (_model.isIndexing) {
      if (_model.total > 0) {
        return '正在扫描相册… (${_model.indexedCount}/${_model.total})';
      } else {
        return '正在扫描相册…';
      }
    }
    
    if (_model.lastError != null) {
      return _model.lastError!;
    }
    
    if (_error != null) {
      return _error!;
    }
    
    return '共 ${_model.total} 张照片，含定位 ${_model.points.length} 张';
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _getStatusText(),
                            style: const TextStyle(color: Colors.white),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_model.isIndexing)
                          const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          ),
                      ],
                    ),
                    // 索引进度条
                    if (_model.isIndexing && _model.total > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          children: [
                            LinearProgressIndicator(
                              value: _model.indexedCount / _model.total,
                              backgroundColor: Colors.white.withOpacity(0.3),
                              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${_model.indexedCount} / ${_model.total}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
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
