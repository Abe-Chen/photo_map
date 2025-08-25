import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../services/photo_indexer.dart';
import 'photo_viewer.dart';

class AlbumScreen extends StatefulWidget {
  final String? initialAlbumCode; // null = 全部
  const AlbumScreen({super.key, this.initialAlbumCode});

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  String? _currentCode; // null 表示全部

  @override
  void initState() {
    super.initState();
    _currentCode = widget.initialAlbumCode;
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<PhotoIndexModel>();

    final countries = model.byCountry.values.toList()
      ..sort((a, b) => a.countryName.compareTo(b.countryName));

    final List<AssetEntity> items = _currentCode == null
        ? countries.expand((e) => e.assets).toList()
        : (model.byCountry[_currentCode!]?.assets ?? const <AssetEntity>[]);

    final title = _currentCode == null
        ? '全部图片 (${items.length})'
        : '${model.byCountry[_currentCode!]!.countryName} (${items.length})';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          PopupMenuButton<String?>(
            initialValue: _currentCode,
            itemBuilder: (context) => <PopupMenuEntry<String?>>[
              const PopupMenuItem<String?>(
                value: null,
                child: Text('全部'),
              ),
              ...countries.map(
                    (c) => PopupMenuItem<String?>(
                  value: c.countryCode,
                  child: Text('${c.countryName} (${c.assets.length})'),
                ),
              ),
            ],
            onSelected: (v) => setState(() => _currentCode = v),
          ),
        ],
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final asset = items[index];
          return FutureBuilder<Uint8List?>(
            future: asset.thumbnailDataWithSize(const ThumbnailSize(400, 400)),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const ColoredBox(color: Color(0x11000000));
              }
              return GestureDetector(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PhotoViewer(
                        assets: items,
                        initialIndex: index,
                      ),
                    ),
                  );
                },
                child: Image.memory(snap.data!, fit: BoxFit.cover),
              );
            },
          );
        },
      ),
    );
  }
}
