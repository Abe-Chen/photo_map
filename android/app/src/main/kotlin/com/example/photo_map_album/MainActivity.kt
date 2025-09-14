package com.example.photo_map_album

import android.content.ContentResolver
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import java.io.IOException

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.photo_map_album/exif"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getExifGps" -> {
                    getExifGpsInfo(call, result)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun getExifGpsInfo(call: MethodCall, result: Result) {
        val assetId = call.argument<String>("contentUri") // 实际上是asset.id
        if (assetId == null) {
            result.error("INVALID_ARGUMENT", "Asset ID is required", null)
            return
        }

        try {
            val gpsInfo = getExifGpsInfo(assetId)
            result.success(gpsInfo)
        } catch (e: Exception) {
            Log.e("ExifReader", "GPS读取失败: ${e.message}")
            result.error("GPS_READ_ERROR", "Failed to read GPS data: ${e.message}", null)
        }
    }
    
    private fun getExifGpsInfo(assetId: String): Map<String, Any?> {
        try {
            // 首先尝试从Images表获取
            val imageUri = Uri.withAppendedPath(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, assetId)
            val imageResult = tryGetGpsFromUri(imageUri, "image")
            if (imageResult["latitude"] != null) {
                return imageResult
            }
            
            // 如果是视频，尝试从Video表获取
            val videoUri = Uri.withAppendedPath(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, assetId)
            return tryGetGpsFromUri(videoUri, "video")
            
        } catch (e: Exception) {
            Log.e("MainActivity", "Error reading GPS info for asset: $assetId", e)
            return mapOf(
                "latitude" to null,
                "longitude" to null,
                "hasOriginalAccess" to true
            )
        }
    }
    
    private fun tryGetGpsFromUri(uri: Uri, mediaType: String): Map<String, Any?> {
        try {
            Log.d("ExifReader", "处理$mediaType: URI: $uri")
            
            // Android 10+ 关键：使用 setRequireOriginal 获取未脱敏的原图/视频
            val originalUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    val reqUri = MediaStore.setRequireOriginal(uri)
                    Log.d("ExifReader", "成功获取原始$mediaType URI: $reqUri")
                    reqUri
                } catch (e: SecurityException) {
                    Log.w("ExifReader", "无法获取原始$mediaType 权限，使用普通URI: ${e.message}")
                    uri
                }
            } else {
                uri
            }
            
            if (mediaType == "video") {
                // 对于视频，优先使用MediaMetadataRetriever
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(this, originalUri)
                    val location = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION)
                    if (location != null && location.isNotEmpty()) {
                        // location格式通常是 "+37.5090+127.0243/" 或类似格式
                        val coords = parseLocationString(location)
                        if (coords != null) {
                            Log.d("ExifReader", "成功从视频元数据解析GPS: lat=${coords.first}, lng=${coords.second}")
                            return mapOf(
                                "latitude" to coords.first,
                                "longitude" to coords.second,
                                "hasOriginalAccess" to (originalUri != uri)
                            )
                        }
                    }
                } catch (e: Exception) {
                    Log.w("ExifReader", "视频元数据提取失败，回退到EXIF", e)
                } finally {
                    retriever.release()
                }
            }
            
            // 回退到EXIF解析（对图片和部分MP4有效）
            contentResolver.openInputStream(originalUri)?.use { inputStream ->
                val exif = ExifInterface(inputStream)
                val latLong = FloatArray(2)
                
                if (exif.getLatLong(latLong)) {
                    val gpsInfo = mapOf(
                        "latitude" to latLong[0].toDouble(),
                        "longitude" to latLong[1].toDouble(),
                        "hasOriginalAccess" to (originalUri != uri)
                    )
                    Log.d("ExifReader", "成功从EXIF解析GPS ($mediaType): lat=${latLong[0]}, lng=${latLong[1]}")
                    return gpsInfo
                } else {
                    Log.d("ExifReader", "未在EXIF中找到GPS信息 ($mediaType)")
                    return mapOf("hasOriginalAccess" to (originalUri != uri))
                }
            } ?: return mapOf(
                "hasOriginalAccess" to (originalUri != uri),
                "error" to "Cannot open input stream"
            )
        } catch (e: SecurityException) {
            Log.w("ExifReader", "无权限访问原始$mediaType", e)
            return mapOf(
                "hasOriginalAccess" to false,
                "error" to "Permission denied"
            )
        } catch (e: Exception) {
            Log.e("ExifReader", "读取$mediaType GPS信息失败", e)
            return mapOf(
                "hasOriginalAccess" to true,
                "error" to e.message
            )
        }
    }
    
    private fun parseLocationString(location: String): Pair<Double, Double>? {
        try {
            // 处理常见的location格式: "+37.5090+127.0243/" 或 "+37.5090-127.0243/"
            val cleanLocation = location.replace("/", "").trim()
            val regex = "([+-]?\\d+\\.\\d+)([+-]\\d+\\.\\d+)".toRegex()
            val matchResult = regex.find(cleanLocation)
            
            if (matchResult != null) {
                val lat = matchResult.groupValues[1].toDouble()
                val lng = matchResult.groupValues[2].toDouble()
                return Pair(lat, lng)
            }
        } catch (e: Exception) {
            Log.w("ExifReader", "解析位置字符串失败: $location", e)
        }
        return null
    }


}
