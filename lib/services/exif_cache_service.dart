import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// EXIF缓存数据库服务
/// 用于持久化存储已解析的EXIF坐标信息，避免重复解析
class ExifCacheService {
  static ExifCacheService? _instance;
  static Database? _database;
  
  // 单例模式
  static ExifCacheService get instance {
    _instance ??= ExifCacheService._internal();
    return _instance!;
  }
  
  ExifCacheService._internal();
  
  // 数据库配置
  static const String _databaseName = 'exif_cache.db';
  static const int _databaseVersion = 1;
  static const String _tableName = 'exif_cache';
  
  /// 获取数据库实例
  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }
  
  /// 初始化数据库
  Future<Database> _initDatabase() async {
    final databasesPath = await getDatabasesPath();
    final path = join(databasesPath, _databaseName);
    
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }
  
  /// 创建数据库表
  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_tableName (
        id TEXT PRIMARY KEY,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        created_at INTEGER NOT NULL,
        last_accessed INTEGER NOT NULL
      )
    ''');
    
    // 创建索引以提高查询性能
    await db.execute('CREATE INDEX idx_last_accessed ON $_tableName (last_accessed)');
  }
  
  /// 数据库升级
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // 暂时不需要升级逻辑
  }
  
  /// 缓存EXIF坐标
  /// [id] 资产ID
  /// [latitude] 纬度
  /// [longitude] 经度
  Future<void> cacheExif(String id, double latitude, double longitude) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    await db.insert(
      _tableName,
      {
        'id': id,
        'latitude': latitude,
        'longitude': longitude,
        'created_at': now,
        'last_accessed': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
  
  /// 获取缓存的EXIF坐标
  /// [id] 资产ID
  /// 返回坐标对象，如果不存在则返回null
  Future<ExifCoordinate?> getCachedExif(String id) async {
    final db = await database;
    
    final results = await db.query(
      _tableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    
    if (results.isEmpty) {
      return null;
    }
    
    final row = results.first;
    
    // 更新最后访问时间
    await _updateLastAccessed(db, id);
    
    return ExifCoordinate(
      latitude: row['latitude'] as double,
      longitude: row['longitude'] as double,
    );
  }
  
  /// 批量获取缓存的EXIF坐标
  /// [ids] 资产ID列表
  /// 返回ID到坐标的映射
  Future<Map<String, ExifCoordinate>> batchGetCachedExif(List<String> ids) async {
    if (ids.isEmpty) return {};
    
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    
    final results = await db.query(
      _tableName,
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    
    final Map<String, ExifCoordinate> cache = {};
    final List<String> accessedIds = [];
    
    for (final row in results) {
      final id = row['id'] as String;
      cache[id] = ExifCoordinate(
        latitude: row['latitude'] as double,
        longitude: row['longitude'] as double,
      );
      accessedIds.add(id);
    }
    
    // 批量更新最后访问时间
    if (accessedIds.isNotEmpty) {
      await _batchUpdateLastAccessed(db, accessedIds);
    }
    
    return cache;
  }
  
  /// 检查是否存在缓存
  /// [id] 资产ID
  Future<bool> hasCachedExif(String id) async {
    final db = await database;
    
    final results = await db.query(
      _tableName,
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    
    return results.isNotEmpty;
  }
  
  /// 批量检查缓存存在性
  /// [ids] 资产ID列表
  /// 返回存在缓存的ID集合
  Future<Set<String>> batchHasCachedExif(List<String> ids) async {
    if (ids.isEmpty) return {};
    
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    
    final results = await db.query(
      _tableName,
      columns: ['id'],
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    
    return results.map((row) => row['id'] as String).toSet();
  }
  
  /// 更新最后访问时间
  Future<void> _updateLastAccessed(Database db, String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      _tableName,
      {'last_accessed': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
  
  /// 批量更新最后访问时间
  Future<void> _batchUpdateLastAccessed(Database db, List<String> ids) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final placeholders = List.filled(ids.length, '?').join(',');
    
    await db.update(
      _tableName,
      {'last_accessed': now},
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }
  
  /// 清理过期缓存
  /// [maxAge] 最大缓存时间（毫秒），默认30天
  Future<int> cleanupExpiredCache({int maxAge = 30 * 24 * 60 * 60 * 1000}) async {
    final db = await database;
    final cutoffTime = DateTime.now().millisecondsSinceEpoch - maxAge;
    
    return await db.delete(
      _tableName,
      where: 'last_accessed < ?',
      whereArgs: [cutoffTime],
    );
  }
  
  /// 获取缓存统计信息
  Future<CacheStats> getCacheStats() async {
    final db = await database;
    
    final countResult = await db.rawQuery('SELECT COUNT(*) as count FROM $_tableName');
    final count = countResult.first['count'] as int;
    
    final sizeResult = await db.rawQuery('SELECT page_count * page_size as size FROM pragma_page_count(), pragma_page_size()');
    final size = sizeResult.first['size'] as int;
    
    return CacheStats(entryCount: count, databaseSize: size);
  }
  
  /// 预加载缓存到内存
  /// 启动时调用，将所有缓存数据加载到内存中以提高性能
  Future<Map<String, ExifCoordinate>> preloadCache() async {
    final db = await database;
    
    final results = await db.query(_tableName);
    final Map<String, ExifCoordinate> cache = {};
    
    for (final row in results) {
      final id = row['id'] as String;
      cache[id] = ExifCoordinate(
        latitude: row['latitude'] as double,
        longitude: row['longitude'] as double,
      );
    }
    
    return cache;
  }
  
  /// 获取所有缓存的坐标（用于回退机制）
  Future<List<ExifCoordinate>> getAllCachedCoordinates() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      _tableName,
      columns: ['id', 'latitude', 'longitude'],
      where: 'latitude IS NOT NULL AND longitude IS NOT NULL',
    );
    
    return List.generate(maps.length, (i) {
      return ExifCoordinate(
        latitude: maps[i]['latitude'],
        longitude: maps[i]['longitude'],
      );
    });
  }
  
  /// 关闭数据库连接
  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}

/// EXIF坐标数据类
class ExifCoordinate {
  final double latitude;
  final double longitude;
  
  const ExifCoordinate({
    required this.latitude,
    required this.longitude,
  });
  
  @override
  String toString() => 'ExifCoordinate(lat: $latitude, lng: $longitude)';
  
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ExifCoordinate &&
        other.latitude == latitude &&
        other.longitude == longitude;
  }
  
  @override
  int get hashCode => latitude.hashCode ^ longitude.hashCode;
}

/// 缓存统计信息
class CacheStats {
  final int entryCount;
  final int databaseSize;
  
  const CacheStats({
    required this.entryCount,
    required this.databaseSize,
  });
  
  @override
  String toString() => 'CacheStats(entries: $entryCount, size: ${databaseSize}B)';
}