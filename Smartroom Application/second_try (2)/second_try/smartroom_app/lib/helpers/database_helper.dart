import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

// ═══════════════════════════════════════════════════════
//  DATABASE HELPER — SmartRoom SQLite
//  Tables: users, sensor_readings, alerts
// ═══════════════════════════════════════════════════════
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._internal();
  factory DatabaseHelper() => instance;
  DatabaseHelper._internal();

  static Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    final path = join(await getDatabasesPath(), 'smartroom.db');
    return await openDatabase(path, version: 1, onCreate: _onCreate);
  }

  Future<void> _onCreate(Database db, int version) async {
    // ── USERS TABLE ──
    await db.execute('''
      CREATE TABLE users (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        surname         TEXT    NOT NULL,
        first_name      TEXT    NOT NULL,
        mobile_number   TEXT    NOT NULL,
        email           TEXT    NOT NULL UNIQUE,
        username        TEXT    NOT NULL UNIQUE,
        password_hash   TEXT    NOT NULL,
        type_of_room    TEXT    NOT NULL DEFAULT 'Living Room',
        created_at      TEXT    NOT NULL
      )
    ''');

    // ── SENSOR READINGS TABLE ──
    await db.execute('''
      CREATE TABLE sensor_readings (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id     INTEGER NOT NULL,
        temperature REAL    NOT NULL,
        humidity    REAL    NOT NULL,
        light       REAL    NOT NULL,
        timestamp   TEXT    NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id)
      )
    ''');

    // ── ALERTS TABLE ──
    await db.execute('''
      CREATE TABLE alerts (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id     INTEGER NOT NULL,
        alert_id    TEXT    NOT NULL,
        type        TEXT    NOT NULL,
        title       TEXT    NOT NULL,
        highlight   TEXT    NOT NULL,
        description TEXT    NOT NULL,
        time_str    TEXT    NOT NULL,
        is_resolved INTEGER NOT NULL DEFAULT 0,
        created_at  TEXT    NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id)
      )
    ''');
  }

  // ══════════════════════════════════════════
  //  PASSWORD HASHING
  // ══════════════════════════════════════════
  String hashPassword(String password) {
    final bytes = utf8.encode(password);
    return sha256.convert(bytes).toString();
  }

  // ══════════════════════════════════════════
  //  USER — REGISTER
  // ══════════════════════════════════════════
  /// Returns true on success, false if email/username already exists.
  Future<bool> registerUser({
    required String surname,
    required String firstName,
    required String mobileNumber,
    required String email,
    required String username,
    required String password,
    required String typeOfRoom,
  }) async {
    final db = await database;
    try {
      await db.insert('users', {
        'surname': surname,
        'first_name': firstName,
        'mobile_number': mobileNumber,
        'email': email.trim().toLowerCase(),
        'username': username.trim(),
        'password_hash': hashPassword(password),
        'type_of_room': typeOfRoom,
        'created_at': DateTime.now().toIso8601String(),
      });
      return true;
    } catch (_) {
      // UNIQUE constraint failed → duplicate email or username
      return false;
    }
  }

  // ══════════════════════════════════════════
  //  USER — LOGIN
  // ══════════════════════════════════════════
  /// Returns the user row map on success, null on failure.
  Future<Map<String, dynamic>?> loginUser({
    required String emailOrUsername,
    required String password,
  }) async {
    final db = await database;
    final hash = hashPassword(password);
    final input = emailOrUsername.trim();
    final result = await db.query(
      'users',
      where: '(email = ? OR username = ?) AND password_hash = ?',
      whereArgs: [input.toLowerCase(), input, hash],
    );
    return result.isNotEmpty ? result.first : null;
  }

  Future<Map<String, dynamic>?> getUserById(int userId) async {
    final db = await database;
    final result = await db.query(
      'users',
      where: 'id = ?',
      whereArgs: [userId],
    );
    return result.isNotEmpty ? result.first : null;
  }

  // ══════════════════════════════════════════
  //  USER — CHECK EMAIL EXISTS
  // ══════════════════════════════════════════
  Future<bool> emailExists(String email) async {
    final db = await database;
    final result = await db.query(
      'users',
      where: 'email = ?',
      whereArgs: [email.trim().toLowerCase()],
    );
    return result.isNotEmpty;
  }

  // ══════════════════════════════════════════
  //  USER — RESET PASSWORD
  // ══════════════════════════════════════════
  Future<bool> resetPassword({
    required String email,
    required String newPassword,
  }) async {
    final db = await database;
    final count = await db.update(
      'users',
      {'password_hash': hashPassword(newPassword)},
      where: 'email = ?',
      whereArgs: [email.trim().toLowerCase()],
    );
    return count > 0;
  }

  // ══════════════════════════════════════════
  //  USER — UPDATE PROFILE
  // ══════════════════════════════════════════
  Future<bool> updateProfile({
    required int userId,
    required String surname,
    required String firstName,
    required String mobileNumber,
    required String username,
    required String typeOfRoom,
  }) async {
    final db = await database;
    final count = await db.update(
      'users',
      {
        'surname': surname,
        'first_name': firstName,
        'mobile_number': mobileNumber,
        'username': username.trim(),
        'type_of_room': typeOfRoom,
      },
      where: 'id = ?',
      whereArgs: [userId],
    );
    return count > 0;
  }

  // ══════════════════════════════════════════
  //  SENSOR READINGS — INSERT
  // ══════════════════════════════════════════
  Future<void> insertSensorReading({
    required int userId,
    required double temperature,
    required double humidity,
    required double light,
  }) async {
    final db = await database;
    await db.insert('sensor_readings', {
      'user_id': userId,
      'temperature': temperature,
      'humidity': humidity,
      'light': light,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // ══════════════════════════════════════════
  //  SENSOR READINGS — GET RECENT
  // ══════════════════════════════════════════
  Future<List<Map<String, dynamic>>> getRecentReadings(
    int userId, {
    int limit = 720,
  }) async {
    final db = await database;
    return await db.query(
      'sensor_readings',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'timestamp DESC',
      limit: limit,
    );
  }

  // ══════════════════════════════════════════
  //  ALERTS — SAVE / UPSERT
  // ══════════════════════════════════════════
  Future<void> saveAlert({
    required int userId,
    required String alertId,
    required String type,
    required String title,
    required String highlight,
    required String description,
    required String timeStr,
    required bool isResolved,
    required DateTime createdAt,
  }) async {
    final db = await database;

    // Check if this alert_id already exists for the user
    final existing = await db.query(
      'alerts',
      where: 'user_id = ? AND alert_id = ?',
      whereArgs: [userId, alertId],
    );

    if (existing.isNotEmpty) {
      // Update existing
      await db.update(
        'alerts',
        {
          'type': type,
          'highlight': highlight,
          'is_resolved': isResolved ? 1 : 0,
          'time_str': timeStr,
        },
        where: 'user_id = ? AND alert_id = ?',
        whereArgs: [userId, alertId],
      );
    } else {
      // Insert new
      await db.insert('alerts', {
        'user_id': userId,
        'alert_id': alertId,
        'type': type,
        'title': title,
        'highlight': highlight,
        'description': description,
        'time_str': timeStr,
        'is_resolved': isResolved ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      });
    }
  }

  // ══════════════════════════════════════════
  //  ALERTS — GET ALL FOR USER
  // ══════════════════════════════════════════
  Future<List<Map<String, dynamic>>> getAlerts(int userId) async {
    final db = await database;
    return await db.query(
      'alerts',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC',
    );
  }

  // ══════════════════════════════════════════
  //  UTILITY — CLOSE DB
  // ══════════════════════════════════════════
  Future<void> close() async {
    final db = await database;
    db.close();
  }
}
