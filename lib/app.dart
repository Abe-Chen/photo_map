import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:photo_manager/photo_manager.dart';

import 'services/photo_indexer.dart';
import 'screens/map_screen.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PhotoIndexModel()),
      ],
      child: MaterialApp(
        title: 'Photo Map Album',
        theme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          useMaterial3: true,
        ),
        home: const StartupGate(),
      ),
    );
  }
}

class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      // 第一步：按 photo_manager 的方式申请相册读取权限
      final ext = await PhotoManager.requestPermissionExtend();
      final hasGalleryAccess = ext.isAuth || (ext.hasAccess == true);
      if (!hasGalleryAccess) {
        // 没拿到相册权限，直接提示
        setState(() {
          _error = '未获得相册读取权限';
        });
        return;
      }

      // 第二步（关键）：Android 上额外申请“读取媒体位置信息”权限，不然读不到 EXIF 坐标
      if (Platform.isAndroid) {
        final status = await Permission.accessMediaLocation.request();
        if (!status.isGranted) {
          // 不强制报错，但强烈建议用户去系统设置开启
          debugPrint('ACCESS_MEDIA_LOCATION 未授予，可能读不到 EXIF 里的经纬度');
          // 你也可以在这里把 _error 设为可见，给一个按钮跳系统设置
          // setState(() => _error = '未授予“媒体位置信息”权限，可能导致没有定位照片');
        } else {
          debugPrint('ACCESS_MEDIA_LOCATION 已授予');
        }
      }

      // 第三步：构建你的图片索引（你已有的逻辑）
      await context.read<PhotoIndexModel>().buildIndex();

      setState(() => _ready = true);
    } catch (e) {
      setState(() => _error = '初始化失败：$e');
    }
  }


  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    await openAppSettings(); // 打开系统设置页 → 你的App → 权限
                  },
                  child: const Text('去系统设置授予权限'),
                ),

                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () async {
                    await PhotoManager.openSetting();
                  },
                  child: const Text('去系统设置授予权限'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return const MapScreen();
  }
}
