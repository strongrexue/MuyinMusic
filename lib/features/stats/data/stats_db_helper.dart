import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../data/stats_db_constants.dart';

/// 听歌统计数据库 Helper（单例）。
///
/// 使用 sqflite + path 的 getDatabasesPath 打开独立的统计库，
/// 表结构按飞牛音乐统计 schema 精简而来，完整支持所有查询。
class StatsDbHelper {
  StatsDbHelper._internal();

  static final StatsDbHelper instance = StatsDbHelper._internal();

  Database? _db;
  Future<Database>? _opening;

  /// 懒加载打开数据库（并发调用共享同一个 Future，避免重复 open）。
  Future<Database> get database async {
    final db = _db;
    if (db != null && db.isOpen) return db;
    final opening = _opening;
    if (opening != null) return opening;

    final future = _open();
    _opening = future;
    try {
      final opened = await future;
      _db = opened;
      return opened;
    } finally {
      _opening = null;
    }
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, StatsDbConstants.dbName);
    return openDatabase(
      path,
      version: StatsDbConstants.dbVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE ${StatsDbConstants.tableSongs} (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        coverUrl TEXT
      )
    ''');
    batch.execute('''
      CREATE TABLE ${StatsDbConstants.tableSongStats} (
        songId TEXT PRIMARY KEY,
        listenMs INTEGER NOT NULL DEFAULT 0,
        playCount INTEGER NOT NULL DEFAULT 0,
        lastPlayedMs INTEGER NOT NULL DEFAULT 0
      )
    ''');
    batch.execute('''
      CREATE TABLE ${StatsDbConstants.tableListeningDays} (
        dayKey TEXT PRIMARY KEY,
        listenMs INTEGER NOT NULL DEFAULT 0,
        playCount INTEGER NOT NULL DEFAULT 0
      )
    ''');
    batch.execute('''
      CREATE TABLE ${StatsDbConstants.tableAlbumStats} (
        albumName TEXT PRIMARY KEY,
        playCount INTEGER NOT NULL DEFAULT 0,
        lastPlayedMs INTEGER NOT NULL DEFAULT 0
      )
    ''');
    batch.execute('''
      CREATE TABLE ${StatsDbConstants.tablePlaylistStats} (
        playlistId TEXT PRIMARY KEY,
        playCount INTEGER NOT NULL DEFAULT 0,
        lastPlayedMs INTEGER NOT NULL DEFAULT 0
      )
    ''');
    batch.execute('''
      CREATE TABLE ${StatsDbConstants.tableReportEvents} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        dayKey TEXT NOT NULL,
        hour INTEGER NOT NULL,
        songId TEXT NOT NULL,
        songTitle TEXT NOT NULL DEFAULT '',
        artistsJson TEXT NOT NULL DEFAULT '[]',
        albumJson TEXT NOT NULL DEFAULT '{}',
        coverId TEXT NOT NULL DEFAULT '',
        durationMs INTEGER NOT NULL DEFAULT 0,
        playMs INTEGER NOT NULL DEFAULT 0,
        completed INTEGER NOT NULL DEFAULT 0,
        sessionStartMs INTEGER NOT NULL,
        sessionEndMs INTEGER NOT NULL
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_report_events_dayKey ON ${StatsDbConstants.tableReportEvents}(dayKey)',
    );
    batch.execute(
      'CREATE INDEX idx_report_events_songId ON ${StatsDbConstants.tableReportEvents}(songId)',
    );
    await batch.commit(noResult: true);
  }

  /// 当前仅 v1；未来 schema 变更时在此补齐建表/迁移逻辑。
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // 预留：按版本增量 ALTER TABLE / CREATE TABLE。
  }

  /// 关闭数据库（测试或热重载时可主动调用）。
  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db != null && db.isOpen) await db.close();
  }
}
