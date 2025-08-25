import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';


class PhotoViewer extends StatefulWidget {
  final List<AssetEntity> assets;
  final int initialIndex;
  const PhotoViewer({super.key, required this.assets, required this.initialIndex});


  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}


class _PhotoViewerState extends State<PhotoViewer> {
  late final PageController _controller;


  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.initialIndex);
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: const TextStyle(color: Colors.white, fontSize: 18),
        title: const Text('预览'),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.assets.length,
        itemBuilder: (context, index) {
          final asset = widget.assets[index];
          return FutureBuilder<Uint8List?>(
            future: asset.originBytes, // 原图（可能较大）
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final bytes = snap.data;
              if (bytes == null) {
                return const Center(child: Text('无法加载', style: TextStyle(color: Colors.white)));
              }
              return InteractiveViewer(
                child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
              );
            },
          );
        },
      ),
    );
  }
}