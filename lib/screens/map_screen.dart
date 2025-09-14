import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import '../models/photo_point.dart';
import '../services/photo_indexer.dart';
import '../services/cluster_engine.dart';
import '../services/cluster_renderer.dart';
import '../services/geo_labeler.dart';
import '../services/zoom_level_mapper.dart';
import '../services/map_interaction_handler.dart';
import '../models/photo_index_progress.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? _controller;
  Set<Marker> _markers = {};
  double _currentZoom = 4.0;
  Timer? _debounceTimer;
  
  // 新的聚合引擎组件
  late final ClusterEngine _clusterEngine;
  late final ClusterRenderer _clusterRenderer;
  late final GeoLabeler _geoLabeler;
  late final ZoomLevelMapper _zoomLevelMapper;
  late final MapInteractionHandler _interactionHandler;
  
  // 性能配置参数
  static const int clusterRadiusPx = 60;
  static const int maxGeocodePerIdle = 25;
  static const int markerBatchPerFrame = 8;
  static const int debounceMs = 250;
  
  @override
  void initState() {
    super.initState();
    _initializeComponents();
  }
  
  void _initializeComponents() {
    // 初始化聚合引擎
    _clusterEngine = ClusterEngine(
      config: const ClusterConfig(
        maxZoom: 20,
        minZoom: 0,
        radius: clusterRadiusPx,
        extent: 512,
        rebuildThrottleMs: 500,
      ),
    );
    
    // 初始化地理标签器
    _geoLabeler = GeoLabeler();
    
    // 初始化缩放级别映射器
    _zoomLevelMapper = ZoomLevelMapper();
    
    // 初始化聚合渲染器
    _clusterRenderer = ClusterRenderer(
      geoLabeler: _geoLabeler,
      zoomMapper: _zoomLevelMapper,
    );
    
    // 初始化交互处理器
    _interactionHandler = MapInteractionHandler();
  }
  
  void _initializeClusterEngine(List<PhotoPoint> points) {
    if (points.isEmpty) return;
    _clusterEngine.buildIndex(points);
  }
  
  // 新的marker更新方法
  Future<void> _updateMarkers() async {
    if (_controller == null || !_clusterEngine.isIndexBuilt) return;
    
    try {
      // 获取当前地图边界
      final bounds = await _controller!.getVisibleRegion();
      final bbox = [
        bounds.southwest.longitude, // west
        bounds.southwest.latitude,  // south
        bounds.northeast.longitude, // east
        bounds.northeast.latitude,  // north
      ];
      
      // 获取聚合结果
      final clusters = _clusterEngine.getClusters(bbox, _currentZoom.round());
      
      // 使用ClusterRenderer渲染markers
      final newMarkers = await _clusterRenderer.renderClusters(
        clusters,
        _currentZoom,
        null, // onTap callback
      );
      
      // 更新markers
      setState(() {
        _markers = newMarkers;
      });
    } catch (e) {
      print('Error updating markers: $e');
    }
  }
  
  void _onClusterTap(ClusterItem cluster, List<PhotoPoint> photos) {
    _interactionHandler.handleClusterTap(
      cluster,
      photos,
    );
  }
  
  void _onPhotoTap(PhotoPoint photo) {
    // TODO: 实现单张照片点击逻辑
    print('Photo tapped: ${photo.id}');
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

  /// P0: 视口优先EXIF - 触发视口EXIF解析
  Future<void> _triggerViewportExif(PhotoIndexModel model) async {
    if (_controller == null) return;
    
    try {
      // 获取当前地图边界
      final bounds = await _controller!.getVisibleRegion();
      
      // 创建ViewportBounds对象
      final viewportBounds = ViewportBounds(
        northeast: bounds.northeast,
        southwest: bounds.southwest,
      );
      
      // 调用PhotoIndexModel的enqueueViewport方法
      model.enqueueViewport(viewportBounds);
    } catch (e) {
      debugPrint('触发视口EXIF解析失败: $e');
    }
  }

  // P0: 获取阶段颜色
  Color _getPhaseColor(IndexPhase phase) {
    switch (phase) {
      case IndexPhase.fast:
        return Colors.blue;
      case IndexPhase.viewport:
        return Colors.orange;
      case IndexPhase.background:
        return Colors.green;
      case IndexPhase.idle:
        return Colors.grey;
    }
  }

  // P0: 显示进度详情BottomSheet
  void _showProgressDetails(BuildContext context, PhotoIndexModel model) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        builder: (context, scrollController) => Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题栏
              Row(
                children: [
                  const Text(
                    '索引进度详情',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              
              // 进度概览
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '当前阶段: ${model.progress.phase.displayName}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: model.progress.progressRatio,
                        backgroundColor: Colors.grey[300],
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _getPhaseColor(model.progress.phase),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '进度: ${model.progress.done} / ${model.progress.estimatedTotal} (${(model.progress.progressRatio * 100).toStringAsFixed(1)}%)',
                      ),
                    ],
                  ),
                ),
              ),
              
              const SizedBox(height: 16),
              
              // 详细统计
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: [
                    _buildStatCard('数据来源统计', [
                      'MediaStore直接获取: ${model.detailedStats.mediaLatLngCount}',
                      'EXIF解析新增: ${model.detailedStats.exifParsedCount}',
                      '缓存命中: ${model.detailedStats.cacheHitCount}',
                    ]),
                    
                    _buildStatCard('队列状态', [
                      '视口队列: ${model.queueStatus.viewportQueueSize}',
                      '后台队列: ${model.queueStatus.backgroundQueueSize}',
                      '运行中Worker: ${model.queueStatus.runningWorkers}',
                    ]),
                    
                    _buildStatCard('性能统计', [
                      '最近批次平均耗时: ${model.detailedStats.recentBatchAvgTime.toStringAsFixed(2)}ms',
                      '最近失败数: ${model.detailedStats.recentFailureCount}',
                      '最近跳过数: ${model.detailedStats.recentSkipCount}',
                    ]),
                  ],
                ),
              ),
              
              // 控制按钮
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        if (model.isPaused) {
                          model.resumeIndexing();
                        } else {
                          model.pauseIndexing();
                        }
                      },
                      child: Text(model.isPaused ? '继续' : '暂停'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        model.parseViewportOnly();
                      },
                      child: const Text('仅解析当前视口'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, List<String> stats) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ...stats.map((stat) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(stat),
            )),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _clusterEngine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PhotoIndexModel>(
       builder: (context, model, _) {
         // 初始化聚类
         if (model.points.isNotEmpty && !_clusterEngine.isIndexBuilt) {
           _initializeClusterEngine(model.points);
         }

        return Scaffold(
          appBar: AppBar(
            title: const Text('Photo Map Album'),
            actions: [
              // P0: 实时计数显示
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Center(
                  child: Text(
                    '${model.progress.done} / ~${model.progress.estimatedTotal}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              // P0: 状态Pill
              GestureDetector(
                onTap: () => _showProgressDetails(context, model),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
                  padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                  decoration: BoxDecoration(
                    color: _getPhaseColor(model.progress.phase),
                    borderRadius: BorderRadius.circular(16.0),
                  ),
                  child: Text(
                    model.progress.phase.displayName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '重新索引',
                icon: const Icon(Icons.refresh),
                onPressed: () async {
                  await model.buildIndexFast();
                  if (mounted && model.points.isNotEmpty) {
                    _moveToFirstPoint(model.points);
                  }
                },
              ),
            ],
          ),
          body: Column(
            children: [
              // P0: 顶部线性进度条
              if (model.progress.shouldShowProgress)
                GestureDetector(
                  onTap: () => _showProgressDetails(context, model),
                  child: LinearProgressIndicator(
                    value: model.progress.progressRatio,
                    backgroundColor: Colors.grey[300],
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _getPhaseColor(model.progress.phase),
                    ),
                    minHeight: 3.0,
                  ),
                ),
              
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
                  markers: _markers,
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
                   onCameraIdle: () {
                      // 250ms去抖，避免频繁更新
                      _debounceTimer?.cancel();
                      _debounceTimer = Timer(const Duration(milliseconds: debounceMs), () {
                        if (_clusterEngine.isIndexBuilt) {
                          _updateMarkers();
                        }
                        // P0: 视口优先EXIF - 获取当前地图边界并触发视口EXIF解析
                        _triggerViewportExif(model);
                      });
                    },
                   onCameraMove: (position) {
                     _currentZoom = position.zoom;
                   },
                  myLocationEnabled: false, // 这里跟读取照片定位无关
                  myLocationButtonEnabled: false,
                  compassEnabled: true,
                  zoomControlsEnabled: false,
                ),
              ),
            ],
          ),
          floatingActionButton: (model.points.isEmpty && model.progress.isCompleted)
              ? FloatingActionButton.extended(
            onPressed: () async {
              await model.buildIndexFast();
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
