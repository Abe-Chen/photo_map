import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:google_maps_flutter/google_maps_flutter.dart';

Future<BitmapDescriptor> bitmapFromBytes(Uint8List? bytes,
    {bool circle = false, int target = 160}) async {
  if (bytes == null) return BitmapDescriptor.defaultMarker;
  final codec =
  await ui.instantiateImageCodec(bytes, targetWidth: target, targetHeight: target);
  final frame = await codec.getNextFrame();
  final uiImage = frame.image;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = ui.Paint();

  if (circle) {
    final rect = ui.Rect.fromLTWH(0, 0, target.toDouble(), target.toDouble());
    final r = ui.RRect.fromRectAndRadius(rect, ui.Radius.circular(target / 2));
    canvas.clipRRect(r);
  }

  canvas.drawImage(uiImage, ui.Offset.zero, paint);
  final picture = recorder.endRecording();
  final img = await picture.toImage(target, target);
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  return BitmapDescriptor.fromBytes(byteData!.buffer.asUint8List());
}
