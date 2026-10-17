import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/database_helper.dart'; // ← SQLite helper

// ═══════════════════════════════════════════════════════
//  GLOBAL USER PROFILE MODEL
// ═══════════════════════════════════════════════════════
class UserProfile {
  int? id; // ← DB primary key, set after login
  String surname;
  String firstName;
  String mobileNumber;
  String email;
  String username;
  String typeOfRoom;

  UserProfile({
    this.id,
    this.surname = '',
    this.firstName = '',
    this.mobileNumber = '',
    this.email = '',
    this.username = '',
    this.typeOfRoom = 'Living Room',
  });

  String get fullName => (firstName.isNotEmpty || surname.isNotEmpty)
      ? '${firstName.trim()} ${surname.trim()}'.trim()
      : 'User';

  String get initials {
    final f = firstName.isNotEmpty ? firstName[0].toUpperCase() : '';
    final s = surname.isNotEmpty ? surname[0].toUpperCase() : '';
    if (f.isNotEmpty && s.isNotEmpty) return '$f$s';
    if (f.isNotEmpty) return f;
    if (email.isNotEmpty) return email[0].toUpperCase();
    return 'U';
  }

  Color get avatarColor {
    final colors = [
      const Color(0xFF1565C0),
      const Color(0xFF6A1B9A),
      const Color(0xFF00695C),
      const Color(0xFFAD1457),
      const Color(0xFF283593),
      const Color(0xFF4E342E),
      const Color(0xFF00838F),
      const Color(0xFF558B2F),
    ];
    final idx =
        (surname + firstName).codeUnits.fold(0, (a, b) => a + b) %
        colors.length;
    return colors[idx];
  }
}

final UserProfile userProfile = UserProfile();

// Global notifier so any widget can toggle dark/light mode
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

const List<String> kRoomTypes = [
  'Living Room',
  'Bedroom',
  'Master Bedroom',
  'Kitchen',
  'Dining Room',
  'Bathroom',
  'Home Office',
  'Study Room',
  'Garage',
  'Basement',
  'Attic',
  'Laundry Room',
  'Guest Room',
  'Nursery',
  'Playroom',
  'Home Theater',
  'Library',
  'Gym / Fitness Room',
  'Hallway',
  'Balcony / Patio',
];

// ═══════════════════════════════════════════════════════
//  GLOBAL ALERT MANAGER
// ═══════════════════════════════════════════════════════
class AlertItem {
  final String id;
  String type; // "Critical", "Warning", "Resolved"
  final IconData icon;
  final Color color;
  final String title;
  final String highlight;
  final String desc;
  final String time;
  final List<String> actions;
  bool isResolved;
  DateTime createdAt;

  AlertItem({
    required this.id,
    required this.type,
    required this.icon,
    required this.color,
    required this.title,
    required this.highlight,
    required this.desc,
    required this.time,
    required this.actions,
    this.isResolved = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}

class AlertManager {
  static final AlertManager _instance = AlertManager._internal();
  factory AlertManager() => _instance;
  AlertManager._internal();

  final List<AlertItem> _alerts = [];
  final StreamController<List<AlertItem>> _controller =
      StreamController<List<AlertItem>>.broadcast();

  Stream<List<AlertItem>> get stream => _controller.stream;
  List<AlertItem> get alerts => List.unmodifiable(_alerts);

  final Set<String> _activeAlertIds = {};

  void updateFromSensorData({
    required double temperature,
    required double humidity,
    required double light,
    required bool hasData,
    required bool pushNotifEnabled,
  }) {
    if (!hasData) return;

    final now = DateTime.now();
    final h = now.hour;
    final m = now.minute.toString().padLeft(2, '0');
    final ampm = h >= 12 ? 'PM' : 'AM';
    final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    final timeStr = '$h12:$m $ampm';

    bool changed = false;

    // ── TEMPERATURE ──
    if (temperature > 31) {
      if (!_activeAlertIds.contains('temp_critical')) {
        _alerts.removeWhere(
          (a) => a.id == 'temp_critical' || a.id == 'temp_stabilized',
        );
        final alert = AlertItem(
          id: 'temp_critical',
          type: 'Critical',
          icon: Icons.error_outline,
          color: Colors.red,
          title: 'Critical Temperature',
          highlight: '${temperature.toStringAsFixed(1)}°C',
          desc: 'Exceeds safety threshold for electronics.',
          time: timeStr,
          actions: ['Turn on AC', 'Activate Fan'],
        );
        _alerts.insert(0, alert);
        _activeAlertIds.add('temp_critical');
        _activeAlertIds.remove('temp_stabilized');
        changed = true;
        _persistAlert(alert);
        if (pushNotifEnabled) {
          NotificationService.instance.showNotification(
            id: 1,
            title: '🌡️ Critical Temperature Alert',
            body:
                'Room temperature is ${temperature.toStringAsFixed(1)}°C — exceeds safety threshold!',
          );
        }
      } else {
        final idx = _alerts.indexWhere((a) => a.id == 'temp_critical');
        if (idx != -1) {
          _alerts[idx] = AlertItem(
            id: 'temp_critical',
            type: 'Critical',
            icon: Icons.error_outline,
            color: Colors.red,
            title: 'Critical Temperature',
            highlight: '${temperature.toStringAsFixed(1)}°C',
            desc: 'Exceeds safety threshold for electronics.',
            time: timeStr,
            actions: ['Turn on AC', 'Activate Fan'],
            isResolved: _alerts[idx].isResolved,
            createdAt: _alerts[idx].createdAt,
          );
          _persistAlert(_alerts[idx]);
          changed = true;
        }
      }
    } else if (temperature >= 24 && temperature <= 31) {
      if (_activeAlertIds.contains('temp_critical')) {
        final idx = _alerts.indexWhere((a) => a.id == 'temp_critical');
        if (idx != -1 && !_alerts[idx].isResolved) {
          _alerts[idx].isResolved = true;
          _alerts[idx].type = 'Resolved';
          _persistAlert(_alerts[idx]);
        }
        _activeAlertIds.remove('temp_critical');
        changed = true;
      }
      if (!_activeAlertIds.contains('temp_stabilized')) {
        _alerts.removeWhere((a) => a.id == 'temp_stabilized');
        final alert = AlertItem(
          id: 'temp_stabilized',
          type: 'Resolved',
          icon: Icons.check_circle_outline,
          color: Colors.green,
          title: 'Temperature Stabilized',
          highlight: '${temperature.toStringAsFixed(1)}°C',
          desc: 'Environment returned to target range.',
          time: timeStr,
          actions: ['View History'],
          isResolved: true,
        );
        _alerts.add(alert);
        _activeAlertIds.add('temp_stabilized');
        _persistAlert(alert);
        changed = true;
      }
    } else {
      _activeAlertIds.remove('temp_critical');
      _activeAlertIds.remove('temp_stabilized');
    }

    // ── HUMIDITY ──
    if (humidity > 65) {
      if (!_activeAlertIds.contains('hum_high')) {
        _alerts.removeWhere((a) => a.id == 'hum_high');
        final alert = AlertItem(
          id: 'hum_high',
          type: 'Warning',
          icon: Icons.warning_amber_outlined,
          color: Colors.orange,
          title: 'High Humidity',
          highlight: '${humidity.toStringAsFixed(0)}%',
          desc: 'Sudden spike detected near window area.',
          time: timeStr,
          actions: ['Dehumidify', 'Close Window'],
        );
        _alerts.insert(0, alert);
        _activeAlertIds.add('hum_high');
        _persistAlert(alert);
        changed = true;
        if (pushNotifEnabled) {
          NotificationService.instance.showNotification(
            id: 2,
            title: '💧 High Humidity Warning',
            body:
                'Humidity at ${humidity.toStringAsFixed(0)}% — consider dehumidifying.',
          );
        }
      } else {
        final idx = _alerts.indexWhere((a) => a.id == 'hum_high');
        if (idx != -1) {
          final prev = _alerts[idx];
          if (!prev.isResolved) {
            _alerts[idx] = AlertItem(
              id: 'hum_high',
              type: 'Warning',
              icon: Icons.warning_amber_outlined,
              color: Colors.orange,
              title: 'High Humidity',
              highlight: '${humidity.toStringAsFixed(0)}%',
              desc: 'Sudden spike detected near window area.',
              time: timeStr,
              actions: ['Dehumidify', 'Close Window'],
              createdAt: prev.createdAt,
            );
            _persistAlert(_alerts[idx]);
            changed = true;
          }
        }
      }
    } else {
      if (_activeAlertIds.contains('hum_high')) {
        final idx = _alerts.indexWhere((a) => a.id == 'hum_high');
        if (idx != -1 && !_alerts[idx].isResolved) {
          _alerts[idx].type = 'Resolved';
          _alerts[idx].isResolved = true;
          _persistAlert(_alerts[idx]);
        }
        _activeAlertIds.remove('hum_high');
        changed = true;
      }
    }

    // ── COMBINED HIGH TEMP + HIGH HUMIDITY (CRITICAL) ──
    if (temperature > 31 && humidity > 65) {
      if (!_activeAlertIds.contains('temp_hum_critical')) {
        _alerts.removeWhere((a) => a.id == 'temp_hum_critical');
        final alert = AlertItem(
          id: 'temp_hum_critical',
          type: 'Critical',
          icon: Icons.warning_rounded,
          color: Colors.deepOrange,
          title: 'Critical Heat & Humidity',
          highlight:
              '${temperature.toStringAsFixed(1)}°C / ${humidity.toStringAsFixed(0)}%',
          desc:
              'Simultaneous high temperature and humidity detected — risk of heat stress and equipment damage.',
          time: timeStr,
          actions: ['Turn on AC', 'Dehumidify', 'Activate Fan'],
        );
        _alerts.insert(0, alert);
        _activeAlertIds.add('temp_hum_critical');
        changed = true;
        _persistAlert(alert);
        if (pushNotifEnabled) {
          NotificationService.instance.showNotification(
            id: 4,
            title: '🔥💧 Critical Heat & Humidity Alert',
            body:
                'Temp ${temperature.toStringAsFixed(1)}°C + Humidity ${humidity.toStringAsFixed(0)}% — take action immediately!',
          );
        }
      } else {
        final idx = _alerts.indexWhere((a) => a.id == 'temp_hum_critical');
        if (idx != -1 && !_alerts[idx].isResolved) {
          _alerts[idx] = AlertItem(
            id: 'temp_hum_critical',
            type: 'Critical',
            icon: Icons.warning_rounded,
            color: Colors.deepOrange,
            title: 'Critical Heat & Humidity',
            highlight:
                '${temperature.toStringAsFixed(1)}°C / ${humidity.toStringAsFixed(0)}%',
            desc:
                'Simultaneous high temperature and humidity detected — risk of heat stress and equipment damage.',
            time: timeStr,
            actions: ['Turn on AC', 'Dehumidify', 'Activate Fan'],
            isResolved: _alerts[idx].isResolved,
            createdAt: _alerts[idx].createdAt,
          );
          _persistAlert(_alerts[idx]);
          changed = true;
        }
      }
    } else {
      if (_activeAlertIds.contains('temp_hum_critical')) {
        final idx = _alerts.indexWhere((a) => a.id == 'temp_hum_critical');
        if (idx != -1 && !_alerts[idx].isResolved) {
          _alerts[idx].isResolved = true;
          _alerts[idx].type = 'Resolved';
          _persistAlert(_alerts[idx]);
        }
        _activeAlertIds.remove('temp_hum_critical');
        changed = true;
      }
    }

    if (_alerts.length > 50) _alerts.removeLast();

    if (changed) _controller.add(List.unmodifiable(_alerts));
  }

  void resolveAlert(String id) {
    final idx = _alerts.indexWhere((a) => a.id == id);
    if (idx != -1) {
      _alerts[idx].isResolved = true;
      _alerts[idx].type = 'Resolved';
      _activeAlertIds.remove(id);
      _persistAlert(_alerts[idx]);
      _controller.add(List.unmodifiable(_alerts));
    }
  }

  // Persist to SQLite (fire-and-forget)
  void _persistAlert(AlertItem a) {
    if (userProfile.id == null) return;
    DatabaseHelper.instance.saveAlert(
      userId: userProfile.id!,
      alertId: a.id,
      type: a.type,
      title: a.title,
      highlight: a.highlight,
      description: a.desc,
      timeStr: a.time,
      isResolved: a.isResolved,
      createdAt: a.createdAt,
    );
  }

  void dispose() {
    _controller.close();
  }
}

final AlertManager alertManager = AlertManager();

// ═══════════════════════════════════════════════════════
//  NOTIFICATION SERVICE
// ═══════════════════════════════════════════════════════
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(android: android, iOS: ios);
    await _plugin.initialize(settings);
  }

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'smartroom_channel',
      'SmartRoom Alerts',
      channelDescription: 'Live room condition alerts from SmartRoom',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    await _plugin.show(id, title, body, details);
  }
}

// ═══════════════════════════════════════════════════════
//  BLUETOOTH SERVICE
// ═══════════════════════════════════════════════════════
class BtService {
  BluetoothConnection? _connection;
  final StreamController<String> _dataController =
      StreamController<String>.broadcast();
  String _buffer = '';

  bool get isConnected => _connection?.isConnected ?? false;
  Stream<String> get dataStream => _dataController.stream;

  Future<void> connectTo(BluetoothDevice device) async {
    await Permission.bluetoothConnect.request();
    await Permission.bluetoothScan.request();
    await _safeDisconnect();
    _buffer = '';

    _connection = await BluetoothConnection.toAddress(device.address);
    _connection!.input!.listen(
      (Uint8List data) {
        _buffer += utf8.decode(data);
        final lines = _buffer.split('\n');
        _buffer = lines.removeLast();
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty) _dataController.add(trimmed);
        }
      },
      onDone: () => _dataController.add('DISCONNECTED'),
      onError: (_) => _dataController.add('DISCONNECTED'),
      cancelOnError: true,
    );
  }

  void send(String command) {
    if (isConnected) {
      try {
        _connection!.output.add(Uint8List.fromList(utf8.encode('$command\n')));
      } catch (_) {}
    }
  }

  Future<void> _safeDisconnect() async {
    try {
      await _connection?.finish();
    } catch (_) {
      try {
        _connection?.dispose();
      } catch (_) {}
    }
    _connection = null;
  }

  Future<void> disconnect() async => await _safeDisconnect();

  void dispose() {
    _safeDisconnect();
    _dataController.close();
  }
}

// ═══════════════════════════════════════════════════════
//  SENSOR DATA MODEL
// ═══════════════════════════════════════════════════════
class SensorData {
  final double temperature;
  final double humidity;
  final double light;
  final DateTime timestamp;

  SensorData({
    required this.temperature,
    required this.humidity,
    required this.light,
    required this.timestamp,
  });
}

// ═══════════════════════════════════════════════════════
//  AUTO AVATAR WIDGET
// ═══════════════════════════════════════════════════════
class AutoAvatar extends StatelessWidget {
  final double radius;
  final UserProfile profile;
  const AutoAvatar({super.key, required this.radius, required this.profile});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: profile.avatarColor,
      child: Text(
        profile.initials,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: radius * 0.7,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  ANIMATED PARTICLE BACKGROUND
// ═══════════════════════════════════════════════════════

class _Particle {
  double x, y, vx, vy, size, opacity, life, maxLife;
  bool isSnow;

  _Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
    required this.opacity,
    required this.life,
    required this.maxLife,
    required this.isSnow,
  });
}

class AnimatedParticleBackground extends StatefulWidget {
  final Widget child;
  final bool isDark;

  const AnimatedParticleBackground({
    super.key,
    required this.child,
    required this.isDark,
  });

  @override
  State<AnimatedParticleBackground> createState() =>
      _AnimatedParticleBackgroundState();
}

class _AnimatedParticleBackgroundState extends State<AnimatedParticleBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<_Particle> _particles = [];
  final math.Random _rng = math.Random();
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..addListener(_tick)
          ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _tick() {
    if (_size == Size.zero) return;
    const dt = 0.016;

    if (_particles.length < 80) {
      final isSnow = _rng.nextBool();

      if (isSnow) {
        _particles.add(
          _Particle(
            x: _rng.nextDouble() * _size.width,
            y: -10,
            vx: (_rng.nextDouble() - 0.5) * 30,
            vy: 20 + _rng.nextDouble() * 40,
            size: 2 + _rng.nextDouble() * 4,
            opacity: 0.4 + _rng.nextDouble() * 0.6,
            life: 0,
            maxLife: (_size.height + 20) / (20 + _rng.nextDouble() * 40),
            isSnow: true,
          ),
        );
      } else {
        final speed = (_size.height + 20) / (3.0 + _rng.nextDouble() * 4.0);
        _particles.add(
          _Particle(
            x: _rng.nextDouble() * _size.width,
            y: _size.height + 10,
            vx: (_rng.nextDouble() - 0.5) * 40,
            vy: -speed,
            size: 1.5 + _rng.nextDouble() * 3.5,
            opacity: 0.7 + _rng.nextDouble() * 0.3,
            life: 0,
            maxLife: (_size.height + 20) / speed + 0.5,
            isSnow: false,
          ),
        );
      }
    }

    for (int i = _particles.length - 1; i >= 0; i--) {
      final p = _particles[i];
      p.life += dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;

      if (p.isSnow) {
        p.vx += math.sin(p.life * 2.0) * 0.3;
        if (p.y > _size.height + 20) _particles.removeAt(i);
      } else {
        p.vx += math.sin(p.life * 1.5) * 0.5;
        if (p.life > p.maxLife || p.y < -20) _particles.removeAt(i);
      }
    }

    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        _size = Size(constraints.maxWidth, constraints.maxHeight);
        final isDark = widget.isDark;
        return Stack(
          children: [
            // Gradient background
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? [
                          const Color(0xFF0D1117),
                          const Color(0xFF161B22),
                          const Color(0xFF0D1117),
                        ]
                      : [
                          const Color(0xFFE8F4FD),
                          const Color(0xFFF0F8FF),
                          const Color(0xFFE8F4FD),
                        ],
                ),
              ),
            ),
            // Particles
            CustomPaint(
              painter: _ParticlePainter(
                particles: List.from(_particles),
                isDark: isDark,
              ),
              size: Size(constraints.maxWidth, constraints.maxHeight),
            ),
            widget.child,
          ],
        );
      },
    );
  }
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final bool isDark;
  const _ParticlePainter({required this.particles, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final progress = p.life / p.maxLife.clamp(0.01, double.infinity);
      final opacity = p.opacity * (1 - progress * 0.5);
      if (p.isSnow) {
        _drawSnowflake(canvas, p, opacity);
      } else {
        _drawSpark(canvas, p, opacity, progress);
      }
    }
  }

  void _drawSnowflake(Canvas canvas, _Particle p, double opacity) {
    final snowColor = isDark
        ? Color.fromRGBO(180, 210, 255, opacity)
        : Color.fromRGBO(100, 150, 220, opacity * 0.5);

    final paint = Paint()
      ..color = snowColor
      ..strokeWidth = p.size * 0.25
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final armCount = 6;
    final armLength = p.size;

    for (int i = 0; i < armCount; i++) {
      final angle = (i / armCount) * 2 * math.pi;
      final endX = p.x + math.cos(angle) * armLength;
      final endY = p.y + math.sin(angle) * armLength;
      canvas.drawLine(Offset(p.x, p.y), Offset(endX, endY), paint);

      final branchLen = armLength * 0.4;
      final midX = p.x + math.cos(angle) * armLength * 0.5;
      final midY = p.y + math.sin(angle) * armLength * 0.5;
      for (final branchAngle in [angle + math.pi / 4, angle - math.pi / 4]) {
        canvas.drawLine(
          Offset(midX, midY),
          Offset(
            midX + math.cos(branchAngle) * branchLen,
            midY + math.sin(branchAngle) * branchLen,
          ),
          paint,
        );
      }
    }

    canvas.drawCircle(
      Offset(p.x, p.y),
      p.size * 0.2,
      Paint()..color = snowColor,
    );
  }

  void _drawSpark(Canvas canvas, _Particle p, double opacity, double progress) {
    final Color sparkColor;
    if (isDark) {
      if (progress < 0.3) {
        sparkColor = Color.fromRGBO(255, 220, 80, opacity);
      } else if (progress < 0.6) {
        sparkColor = Color.fromRGBO(255, 140, 30, opacity);
      } else {
        sparkColor = Color.fromRGBO(220, 60, 10, opacity);
      }
    } else {
      if (progress < 0.3) {
        sparkColor = Color.fromRGBO(255, 180, 60, opacity * 0.7);
      } else if (progress < 0.6) {
        sparkColor = Color.fromRGBO(240, 120, 40, opacity * 0.6);
      } else {
        sparkColor = Color.fromRGBO(200, 70, 20, opacity * 0.4);
      }
    }

    final glowPaint = Paint()
      ..color = sparkColor.withValues(alpha: opacity * 0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(Offset(p.x, p.y), p.size * 2.5, glowPaint);

    canvas.drawCircle(Offset(p.x, p.y), p.size, Paint()..color = sparkColor);

    if (p.vy.abs() > 5) {
      final trailLength = math.min(p.size * 4, 12.0);
      final angle = math.atan2(p.vy, p.vx);
      canvas.drawLine(
        Offset(p.x, p.y),
        Offset(
          p.x - math.cos(angle) * trailLength,
          p.y - math.sin(angle) * trailLength,
        ),
        Paint()
          ..color = sparkColor.withValues(alpha: opacity * 0.4)
          ..strokeWidth = p.size * 0.6
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => true;
}

// ═══════════════════════════════════════════════════════
//  SESSION PERSISTENCE HELPERS
// ═══════════════════════════════════════════════════════
const String _kSessionUserId = 'session_user_id';

Future<void> saveSession(int userId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_kSessionUserId, userId);
}

Future<void> clearSession() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kSessionUserId);
}

Future<int?> getSavedSession() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getInt(_kSessionUserId);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();

  // ── Restore session if user previously logged in ──
  Widget home = const LoginPage();
  final savedUserId = await getSavedSession();
  if (savedUserId != null) {
    final userData = await DatabaseHelper.instance.getUserById(savedUserId);
    if (userData != null) {
      userProfile.id = userData['id'] as int;
      userProfile.surname = userData['surname'] as String;
      userProfile.firstName = userData['first_name'] as String;
      userProfile.mobileNumber = userData['mobile_number'] as String;
      userProfile.email = userData['email'] as String;
      userProfile.username = userData['username'] as String;
      userProfile.typeOfRoom = userData['type_of_room'] as String;
      home = const SmartRoomDashboard();
    }
  }

  runApp(SmartRoomApp(home: home));
}

class SmartRoomApp extends StatelessWidget {
  final Widget home;
  const SmartRoomApp({super.key, required this.home});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, mode, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.blue,
          brightness: Brightness.light,
          scaffoldBackgroundColor: Colors.transparent,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.blue,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Colors.transparent,
        ),
        home: home,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  LOGIN PAGE
// ═══════════════════════════════════════════════════════
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passController = TextEditingController();
  bool _isObscure = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    final userData = await DatabaseHelper.instance.loginUser(
      emailOrUsername: _emailController.text.trim(),
      password: _passController.text,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (userData != null) {
      // Load into global profile
      userProfile.id = userData['id'] as int;
      userProfile.surname = userData['surname'] as String;
      userProfile.firstName = userData['first_name'] as String;
      userProfile.mobileNumber = userData['mobile_number'] as String;
      userProfile.email = userData['email'] as String;
      userProfile.username = userData['username'] as String;
      userProfile.typeOfRoom = userData['type_of_room'] as String;

      // ── Persist session so app reopens to dashboard ──
      await saveSession(userProfile.id!);

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const SmartRoomDashboard()),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Invalid email/username or password!"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // ── Login page is always light mode ──
    final lightTheme = Theme.of(context).copyWith(brightness: Brightness.light);
    return Theme(
      data: lightTheme,
      child: Builder(
        builder: (context) {
          final isDark = false; // always light on login
          return AnimatedParticleBackground(
            isDark: isDark,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(28.0),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.onSurface,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.bolt,
                                color: Theme.of(context).colorScheme.surface,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              "SmartRoom",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 20,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 40),
                        const Text(
                          "Welcome",
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          "Sign in to your account",
                          style: TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: 32),
                        TextFormField(
                          controller: _emailController,
                          decoration: InputDecoration(
                            labelText: "Email or Username",
                            prefixIcon: const Icon(Icons.person_outline),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            filled: true,
                            fillColor: Theme.of(context).colorScheme.surface,
                          ),
                          validator: (v) => v!.isEmpty
                              ? "Enter your email or username"
                              : null,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _passController,
                          obscureText: _isObscure,
                          decoration: InputDecoration(
                            labelText: "Password",
                            prefixIcon: const Icon(Icons.lock_outline),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            filled: true,
                            fillColor: Theme.of(context).colorScheme.surface,
                            suffixIcon: IconButton(
                              icon: Icon(
                                _isObscure
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                              onPressed: () =>
                                  setState(() => _isObscure = !_isObscure),
                            ),
                          ),
                          validator: (v) =>
                              v!.isEmpty ? "Enter your password" : null,
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _login,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: _isLoading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text(
                                    "LOGIN",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Center(
                          child: TextButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const ForgotPasswordPage(),
                              ),
                            ),
                            child: const Text(
                              "Forgot Password?",
                              style: TextStyle(color: Colors.blue),
                            ),
                          ),
                        ),
                        Center(
                          child: TextButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const CreateAccountPage(),
                              ),
                            ),
                            child: const Text(
                              "Don't have an account? Create one",
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  FORGOT PASSWORD PAGE
// ═══════════════════════════════════════════════════════
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});
  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _newPassController = TextEditingController();
  final _confirmPassController = TextEditingController();
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _emailVerified = false;
  bool _resetSuccess = false;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _newPassController.dispose();
    _confirmPassController.dispose();
    super.dispose();
  }

  Future<void> _verifyEmail() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    final exists = await DatabaseHelper.instance.emailExists(
      _emailController.text.trim(),
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (exists) {
      setState(() => _emailVerified = true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("No account found with that email."),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _resetPassword() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    final success = await DatabaseHelper.instance.resetPassword(
      email: _emailController.text.trim(),
      newPassword: _newPassController.text,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (success) {
      setState(() => _resetSuccess = true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Failed to reset password. Try again."),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lightTheme = Theme.of(context).copyWith(brightness: Brightness.light);
    return Theme(
      data: lightTheme,
      child: Builder(
        builder: (context) {
          return AnimatedParticleBackground(
            isDark: false,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                title: const Text("Forgot Password"),
                backgroundColor: Colors.transparent,
                elevation: 0,
              ),
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(28.0),
                  child: _resetSuccess ? _buildSuccessView() : _buildFormView(),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSuccessView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle_outline, color: Colors.green, size: 72),
        const SizedBox(height: 20),
        const Text(
          "Password Reset!",
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          "Your password has been updated successfully.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              "BACK TO LOGIN",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFormView() {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lock_reset, size: 64, color: Colors.blue),
          const SizedBox(height: 16),
          const Text(
            "Reset Password",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            "Enter your registered email to continue.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 32),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            enabled: !_emailVerified,
            decoration: InputDecoration(
              labelText: "Email Address",
              prefixIcon: const Icon(Icons.email_outlined),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return "Enter your email";
              if (!v.contains('@')) return "Enter a valid email";
              return null;
            },
          ),
          if (!_emailVerified) ...[
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _verifyEmail,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        "VERIFY EMAIL",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            TextFormField(
              controller: _newPassController,
              obscureText: _obscureNew,
              decoration: InputDecoration(
                labelText: "New Password",
                prefixIcon: const Icon(Icons.lock_outline),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureNew ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _obscureNew = !_obscureNew),
                ),
              ),
              validator: (v) =>
                  v == null || v.length < 5 ? "Minimum 5 characters" : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _confirmPassController,
              obscureText: _obscureConfirm,
              decoration: InputDecoration(
                labelText: "Confirm New Password",
                prefixIcon: const Icon(Icons.lock_outline),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureConfirm ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
              validator: (v) => v != _newPassController.text
                  ? "Passwords do not match"
                  : null,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _resetPassword,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        "RESET PASSWORD",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  CREATE ACCOUNT PAGE
// ═══════════════════════════════════════════════════════
class CreateAccountPage extends StatefulWidget {
  const CreateAccountPage({super.key});
  @override
  State<CreateAccountPage> createState() => _CreateAccountPageState();
}

class _CreateAccountPageState extends State<CreateAccountPage> {
  final _formKey = GlobalKey<FormState>();
  final _surnameController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _mobileController = TextEditingController();
  final _emailController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passController = TextEditingController();
  final _confirmPassController = TextEditingController();
  String _selectedRoom = kRoomTypes.first;
  bool _obscurePass = true;
  bool _obscureConfirm = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _surnameController.dispose();
    _firstNameController.dispose();
    _mobileController.dispose();
    _emailController.dispose();
    _usernameController.dispose();
    _passController.dispose();
    _confirmPassController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    final success = await DatabaseHelper.instance.registerUser(
      surname: _surnameController.text.trim(),
      firstName: _firstNameController.text.trim(),
      mobileNumber: _mobileController.text.trim(),
      email: _emailController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passController.text,
      typeOfRoom: _selectedRoom,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Account created! Login with: ${_emailController.text.trim()}",
          ),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Email or username already exists!"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  InputDecoration _fieldDecoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      filled: true,
      fillColor: Theme.of(context).colorScheme.surface,
    );
  }

  @override
  Widget build(BuildContext context) {
    final lightTheme = Theme.of(context).copyWith(brightness: Brightness.light);
    return Theme(
      data: lightTheme,
      child: Builder(
        builder: (context) {
          return AnimatedParticleBackground(
            isDark: false,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                title: const Text(
                  "Create Account",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                backgroundColor: Colors.transparent,
                elevation: 0,
              ),
              body: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24.0),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Column(
                            children: [
                              ValueListenableBuilder<ThemeMode>(
                                valueListenable: themeNotifier,
                                builder: (_, __, ___) => AutoAvatar(
                                  radius: 40,
                                  profile: UserProfile(
                                    firstName: _firstNameController.text,
                                    surname: _surnameController.text,
                                    email: _emailController.text,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        _sectionLabel("PERSONAL INFORMATION"),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _surnameController,
                          textCapitalization: TextCapitalization.words,
                          decoration: _fieldDecoration(
                            "Surname",
                            Icons.person_outline,
                          ),
                          onChanged: (_) => setState(() {}),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? "Enter your surname"
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _firstNameController,
                          textCapitalization: TextCapitalization.words,
                          decoration: _fieldDecoration(
                            "First Name",
                            Icons.badge_outlined,
                          ),
                          onChanged: (_) => setState(() {}),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? "Enter your first name"
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _mobileController,
                          keyboardType: TextInputType.phone,
                          decoration: _fieldDecoration(
                            "Mobile Number (09XXXXXXXXX)",
                            Icons.phone_outlined,
                          ),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) {
                              return "Mobile number is required";
                            }
                            final digits = v.trim().replaceAll(
                              RegExp(r'\s'),
                              '',
                            );
                            if (!RegExp(r'^09\d{9}$').hasMatch(digits)) {
                              return "Enter a valid PH number (e.g. 09XXXXXXXXX)";
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 24),
                        _sectionLabel("ACCOUNT DETAILS"),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: _fieldDecoration(
                            "Email Address",
                            Icons.email_outlined,
                          ),
                          onChanged: (_) => setState(() {}),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) {
                              return "Enter your email address";
                            }
                            if (!v.contains('@') || !v.contains('.')) {
                              return "Enter a valid email address";
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _usernameController,
                          decoration: _fieldDecoration(
                            "Username",
                            Icons.alternate_email,
                          ),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? "Choose a username"
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _passController,
                          obscureText: _obscurePass,
                          decoration: InputDecoration(
                            labelText: "Password",
                            prefixIcon: const Icon(Icons.lock_outline),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            filled: true,
                            fillColor: Theme.of(context).colorScheme.surface,
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePass
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                              onPressed: () =>
                                  setState(() => _obscurePass = !_obscurePass),
                            ),
                          ),
                          validator: (v) => v == null || v.length < 5
                              ? "Minimum 5 characters"
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _confirmPassController,
                          obscureText: _obscureConfirm,
                          decoration: InputDecoration(
                            labelText: "Confirm Password",
                            prefixIcon: const Icon(Icons.lock_outline),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            filled: true,
                            fillColor: Theme.of(context).colorScheme.surface,
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureConfirm
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                              onPressed: () => setState(
                                () => _obscureConfirm = !_obscureConfirm,
                              ),
                            ),
                          ),
                          validator: (v) => v != _passController.text
                              ? "Passwords do not match"
                              : null,
                        ),
                        const SizedBox(height: 24),
                        _sectionLabel("ROOM CONFIGURATION"),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          initialValue: _selectedRoom,
                          decoration: InputDecoration(
                            labelText: "Type of Room",
                            prefixIcon: const Icon(Icons.meeting_room_outlined),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            filled: true,
                            fillColor: Theme.of(context).colorScheme.surface,
                          ),
                          items: kRoomTypes
                              .map(
                                (r) =>
                                    DropdownMenuItem(value: r, child: Text(r)),
                              )
                              .toList(),
                          onChanged: (v) => setState(() => _selectedRoom = v!),
                          validator: (v) => v == null || v.isEmpty
                              ? "Select a room type"
                              : null,
                        ),
                        const SizedBox(height: 32),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _register,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: _isLoading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text(
                                    "CREATE ACCOUNT",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _sectionLabel(String t) => Text(
    t,
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.bold,
      color: Colors.grey,
      letterSpacing: 1.2,
    ),
  );
}

// ═══════════════════════════════════════════════════════
//  MAIN DASHBOARD SHELL
// ═══════════════════════════════════════════════════════
class SmartRoomDashboard extends StatefulWidget {
  const SmartRoomDashboard({super.key});
  @override
  State<SmartRoomDashboard> createState() => _SmartRoomDashboardState();
}

class _SmartRoomDashboardState extends State<SmartRoomDashboard> {
  int _currentIndex = 0;

  final BtService _btService = BtService();
  bool _btConnected = false;
  bool _btConnecting = false;
  StreamSubscription<String>? _btSub;

  double _temperature = 0;
  double _humidity = 0;
  double _light = 0;
  bool _hasData = false;
  bool _pushNotif = true;

  final List<SensorData> _historyLog = [];

  @override
  void initState() {
    super.initState();
    _loadHistoryFromDB();
  }

  /// Load past sensor readings from SQLite on startup
  Future<void> _loadHistoryFromDB() async {
    if (userProfile.id == null) return;
    final rows = await DatabaseHelper.instance.getRecentReadings(
      userProfile.id!,
    );
    final loaded = rows.map((r) {
      return SensorData(
        temperature: (r['temperature'] as num).toDouble(),
        humidity: (r['humidity'] as num).toDouble(),
        light: (r['light'] as num).toDouble(),
        timestamp: DateTime.parse(r['timestamp'] as String),
      );
    }).toList();
    if (mounted) {
      setState(() {
        _historyLog.addAll(loaded);
      });
    }
  }

  @override
  void dispose() {
    _btSub?.cancel();
    _btService.dispose();
    super.dispose();
  }

  void _parseData(String raw) {
    if (raw == 'DISCONNECTED') {
      if (mounted) setState(() => _btConnected = false);
      return;
    }
    final cleaned = raw.trim();
    try {
      final parts = cleaned.split(',');
      double? temp, hum, light;
      for (final p in parts) {
        if (p.startsWith('TEMP:')) {
          temp = double.tryParse(p.substring(5).trim());
        }
        if (p.startsWith('HUM:')) hum = double.tryParse(p.substring(4).trim());
        if (p.startsWith('LIGHT:')) {
          light = double.tryParse(p.substring(6).trim());
        }
      }
      if (mounted && (temp != null || hum != null)) {
        setState(() {
          if (temp != null) _temperature = temp;
          if (hum != null) _humidity = hum;
          if (light != null) _light = light;
          _hasData = true;

          final now = DateTime.now();
          final hourKey = DateTime(now.year, now.month, now.day, now.hour);
          final existingIdx = _historyLog.indexWhere((d) {
            final dk = DateTime(
              d.timestamp.year,
              d.timestamp.month,
              d.timestamp.day,
              d.timestamp.hour,
            );
            return dk == hourKey;
          });
          final newEntry = SensorData(
            temperature: _temperature,
            humidity: _humidity,
            light: _light,
            timestamp: now,
          );
          if (existingIdx == -1) {
            _historyLog.insert(0, newEntry);
            // ── SAVE TO SQLITE ──
            if (userProfile.id != null) {
              DatabaseHelper.instance.insertSensorReading(
                userId: userProfile.id!,
                temperature: _temperature,
                humidity: _humidity,
                light: _light,
              );
            }
          } else {
            _historyLog[existingIdx] = newEntry;
          }
          if (_historyLog.length > 720) _historyLog.removeLast();
        });

        alertManager.updateFromSensorData(
          temperature: _temperature,
          humidity: _humidity,
          light: _light,
          hasData: _hasData,
          pushNotifEnabled: _pushNotif,
        );
      }
    } catch (_) {}
  }

  Future<void> _showBluetoothDevices() async {
    if (_btConnected) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text("Bluetooth"),
          content: const Text("Disconnect from ESP32?"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                "Disconnect",
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      );
      if (confirm == true) {
        await _btSub?.cancel();
        _btSub = null;
        await _btService.disconnect();
        if (mounted) {
          setState(() {
            _btConnected = false;
            _hasData = false;
          });
        }
      }
      return;
    }

    final btState = await FlutterBluetoothSerial.instance.state;
    if (btState != BluetoothState.STATE_ON) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Bluetooth is off. Please enable Bluetooth and try again.",
          ),
          backgroundColor: Colors.orange,
        ),
      );
      await FlutterBluetoothSerial.instance.requestEnable();
      return;
    }

    List<BluetoothDevice> devices = [];
    try {
      devices = await FlutterBluetoothSerial.instance.getBondedDevices();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Bluetooth error: $e"),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (!mounted) return;
    if (devices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "No paired devices found. Pair your ESP32 in phone Settings first.",
          ),
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              "Select ESP32 Device",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          const Divider(height: 1),
          ...devices.map(
            (d) => ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xFFE3F2FD),
                child: Icon(Icons.bluetooth, color: Colors.blue),
              ),
              title: Text(d.name ?? "Unknown Device"),
              subtitle: Text(d.address),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(context);
                _connectToDevice(d);
              },
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_btConnecting) return;
    if (mounted) setState(() => _btConnecting = true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Connecting to ${device.name ?? device.address}…"),
        ),
      );
    }
    try {
      await _btService.connectTo(device);
      await _btSub?.cancel();
      _btSub = _btService.dataStream.listen(_parseData);
      if (mounted) {
        setState(() {
          _btConnected = true;
          _btConnecting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("✓ Connected to ${device.name ?? device.address}"),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _btConnected = false;
          _btConnecting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Connection failed: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      HomeScreen(
        btConnected: _btConnected,
        hasData: _hasData,
        temperature: _temperature,
        humidity: _humidity,
        light: _light,
        onBtTap: _showBluetoothDevices,
        historyLog: _historyLog,
      ),
      TrendsScreen(historyLog: _historyLog, hasData: _hasData),
      AlertsScreen(
        temperature: _temperature,
        humidity: _humidity,
        light: _light,
        hasData: _hasData,
      ),
      HistoryScreen(historyLog: _historyLog),
      ProfileScreen(
        onProfileUpdated: () => setState(() {}),
        pushNotif: _pushNotif,
        onPushNotifChanged: (v) => setState(() => _pushNotif = v),
      ),
    ];

    final activeAlertCount = alertManager.alerts
        .where((a) => a.type == 'Critical' || a.type == 'Warning')
        .length;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedParticleBackground(
      isDark: isDark,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: screens[_currentIndex],
        bottomNavigationBar: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          selectedItemColor: Colors.blue,
          unselectedItemColor: Colors.grey,
          showUnselectedLabels: true,
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.grid_view),
              label: "Home",
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.show_chart),
              label: "Trends",
            ),
            BottomNavigationBarItem(
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.notifications_none),
                  if (activeAlertCount > 0)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
              label: "Alerts",
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.history),
              label: "Logs",
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.settings_outlined),
              label: "Profile",
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  SCREEN 1 — HOME
// ═══════════════════════════════════════════════════════
class HomeScreen extends StatelessWidget {
  final bool btConnected, hasData;
  final double temperature, humidity, light;
  final VoidCallback onBtTap;
  final List<SensorData> historyLog;

  const HomeScreen({
    super.key,
    required this.btConnected,
    required this.hasData,
    required this.temperature,
    required this.humidity,
    required this.light,
    required this.onBtTap,
    required this.historyLog,
  });

  String get _tempStatus {
    if (temperature < 18) return "Cold";
    if (temperature <= 26) return "Normal";
    if (temperature <= 30) return "Warm";
    return "Hot";
  }

  Color get _tempColor {
    if (temperature < 18) return Colors.blue;
    if (temperature <= 26) return const Color(0xFF4CAF50);
    if (temperature <= 30) return Colors.orange;
    return Colors.red;
  }

  String get _humStatus {
    if (humidity < 30) return "Dry";
    if (humidity <= 60) return "Optimal";
    return "Humid";
  }

  Color get _humColor {
    if (humidity < 30) return Colors.orange;
    if (humidity <= 60) return Colors.blue;
    return Colors.purple;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.bolt, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            const Text(
              "SmartRoom",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          Stack(
            children: [
              GestureDetector(
                onTap: onBtTap,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: AutoAvatar(radius: 18, profile: userProfile),
                ),
              ),
              Positioned(
                right: 14,
                bottom: 2,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: btConnected ? Colors.green : Colors.grey,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Welcome back, ${userProfile.username.isNotEmpty ? userProfile.username : 'User'}",
              style: const TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  userProfile.typeOfRoom,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: const Text(
                    "All Systems Normal",
                    style: TextStyle(
                      color: Colors.green,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "REAL-TIME SENSORS",
                  style: TextStyle(
                    letterSpacing: 1.2,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                GestureDetector(
                  onTap: onBtTap,
                  child: Row(
                    children: [
                      Icon(
                        Icons.sync,
                        size: 14,
                        color: btConnected ? Colors.blue : Colors.grey,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        btConnected ? "DISCONNECT" : "CONNECT",
                        style: TextStyle(
                          fontSize: 12,
                          color: btConnected ? Colors.blue : Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: _SensorCard(
                    icon: Icons.thermostat,
                    iconBgColor: Colors.orange,
                    label: "Temperature",
                    value: hasData
                        ? "${temperature.toStringAsFixed(1)}°C"
                        : "--°C",
                    status: hasData ? _tempStatus : "No Data",
                    statusColor: hasData ? _tempColor : Colors.grey,
                    showGraph: hasData,
                    timestamp: hasData ? "JUST NOW" : "",
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SensorCard(
                    icon: Icons.water_drop,
                    iconBgColor: Colors.blue,
                    label: "Humidity",
                    value: hasData ? "${humidity.toStringAsFixed(0)}%" : "--%",
                    status: hasData ? _humStatus : "No Data",
                    statusColor: hasData ? _humColor : Colors.grey,
                    showGraph: hasData,
                    timestamp: hasData ? "JUST NOW" : "",
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // ── Efficiency Insights ──
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.blue.shade900.withValues(alpha: 0.4)
                    : const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark ? Colors.blue.shade700 : Colors.blue.shade100,
                ),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.blue.shade800
                              : const Color(0xFFBBDEFB),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.north_east,
                          size: 16,
                          color: Colors.blue,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          "Efficiency Insights",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    hasData
                        ? "Energy usage is 12% lower than last week. Maintaining ${temperature.toStringAsFixed(1)}°C has significantly improved your HVAC efficiency."
                        : "Connect to your ESP32 via Bluetooth to see live efficiency insights.",
                    style: TextStyle(
                      height: 1.5,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () {
                        final dashboardState = context
                            .findAncestorStateOfType<
                              _SmartRoomDashboardState
                            >();
                        if (dashboardState != null) {
                          dashboardState.setState(
                            () => dashboardState._currentIndex = 1,
                          );
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: isDark ? Colors.blue.shade300 : Colors.blue,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        "View Analytics",
                        style: TextStyle(
                          color: isDark ? Colors.blue.shade300 : Colors.blue,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SensorCard extends StatelessWidget {
  final IconData icon;
  final Color iconBgColor;
  final String label, value, status, timestamp;
  final Color statusColor;
  final bool showGraph;

  const _SensorCard({
    required this.icon,
    required this.iconBgColor,
    required this.label,
    required this.value,
    required this.status,
    required this.timestamp,
    required this.statusColor,
    required this.showGraph,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: iconBgColor,
                child: Icon(icon, color: Colors.white, size: 18),
              ),
              if (timestamp.isNotEmpty)
                Text(
                  timestamp,
                  style: const TextStyle(
                    fontSize: 9,
                    color: Colors.grey,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          Text(
            value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (showGraph)
            CustomPaint(
              size: const Size(double.infinity, 30),
              painter: _MiniGraphPainter(),
            ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: statusColor.withValues(alpha: 0.3)),
            ),
            child: Text(
              status,
              style: TextStyle(
                color: statusColor,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniGraphPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();
    final pts = [0.1, 0.4, 0.3, 0.5, 0.45, 0.6, 0.55];
    path.moveTo(0, size.height * (1 - pts[0]));
    for (int i = 1; i < pts.length; i++) {
      path.lineTo(
        size.width * i / (pts.length - 1),
        size.height * (1 - pts[i]),
      );
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_) => false;
}

// ═══════════════════════════════════════════════════════
//  SCREEN 2 — TRENDS (ANALYTICS)
// ═══════════════════════════════════════════════════════
class TrendsScreen extends StatefulWidget {
  final List<SensorData> historyLog;
  final bool hasData;
  const TrendsScreen({
    super.key,
    required this.historyLog,
    required this.hasData,
  });

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen>
    with SingleTickerProviderStateMixin {
  String _period = "24H";
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  DateTime? _customStart;
  DateTime? _customEnd;

  List<SensorData> get _filtered {
    if (widget.historyLog.isEmpty) return [];
    final now = DateTime.now();
    if (_period == "Custom" && _customStart != null && _customEnd != null) {
      final end = _customEnd!.add(const Duration(days: 1));
      return widget.historyLog
          .where(
            (d) =>
                d.timestamp.isAfter(_customStart!) && d.timestamp.isBefore(end),
          )
          .toList();
    }
    final dur = _period == "7D"
        ? const Duration(days: 7)
        : _period == "Monthly"
        ? const Duration(days: 30)
        : const Duration(hours: 24);
    return widget.historyLog
        .where((d) => now.difference(d.timestamp) <= dur)
        .toList();
  }

  double _avg(List<double> v) =>
      v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
  double _min(List<double> v) =>
      v.isEmpty ? 0 : v.reduce((a, b) => a < b ? a : b);
  double _max(List<double> v) =>
      v.isEmpty ? 0 : v.reduce((a, b) => a > b ? a : b);

  @override
  Widget build(BuildContext context) {
    final data = _filtered;
    final temps = data.map((d) => d.temperature).toList();
    final hums = data.map((d) => d.humidity).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        title: const Text(
          "Analytics & Trends",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "SELECT PERIOD",
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: ["24H", "7D", "Monthly", "Custom"].map((p) {
                  final sel = _period == p;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () async {
                        if (p == "Custom") {
                          final picked = await showDateRangePicker(
                            context: context,
                            firstDate: DateTime.now().subtract(
                              const Duration(days: 365),
                            ),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) {
                            setState(() {
                              _period = p;
                              _customStart = picked.start;
                              _customEnd = picked.end;
                            });
                          }
                          return;
                        }
                        setState(() => _period = p);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: sel
                              ? Theme.of(context).colorScheme.surface
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: sel
                              ? [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.08),
                                    blurRadius: 4,
                                  ),
                                ]
                              : [],
                        ),
                        child: Text(
                          p,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: sel
                                ? Theme.of(context).colorScheme.onSurface
                                : Colors.grey,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 16),

            if (!widget.hasData)
              Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.bluetooth_disabled,
                        size: 48,
                        color: Colors.grey,
                      ),
                      SizedBox(height: 12),
                      Text(
                        "Connect ESP32 to see trend charts",
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: _AnalyticsSummaryCard(
                      label: "Avg Temp",
                      value: temps.isEmpty
                          ? "--"
                          : "${_avg(temps).toStringAsFixed(1)}°C",
                      icon: Icons.thermostat,
                      color: Colors.orange,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _AnalyticsSummaryCard(
                      label: "Avg Humidity",
                      value: hums.isEmpty
                          ? "--"
                          : "${_avg(hums).toStringAsFixed(0)}%",
                      icon: Icons.water_drop,
                      color: Colors.blue,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _TrendCard(
                icon: Icons.thermostat,
                iconColor: Colors.orange,
                label: "Temperature",
                currentValue: temps.isNotEmpty
                    ? "${temps.first.toStringAsFixed(1)}°C"
                    : "--",
                min: temps.isEmpty
                    ? "--"
                    : "${_min(temps).toStringAsFixed(0)}°C",
                max: temps.isEmpty
                    ? "--"
                    : "${_max(temps).toStringAsFixed(0)}°C",
                avg: temps.isEmpty
                    ? "--"
                    : "${_avg(temps).toStringAsFixed(1)}°C",
                chartColor: Colors.orange,
                values: temps,
              ),
              const SizedBox(height: 12),
              _TrendCard(
                icon: Icons.water_drop,
                iconColor: Colors.blue,
                label: "Humidity",
                currentValue: hums.isNotEmpty
                    ? "${hums.first.toStringAsFixed(0)}%"
                    : "--",
                min: hums.isEmpty ? "--" : "${_min(hums).toStringAsFixed(0)}%",
                max: hums.isEmpty ? "--" : "${_max(hums).toStringAsFixed(0)}%",
                avg: hums.isEmpty ? "--" : "${_avg(hums).toStringAsFixed(1)}%",
                chartColor: Colors.blue,
                values: hums,
              ),
              const SizedBox(height: 16),
              _AnalyticsInsightCard(
                temps: temps,
                hums: hums,
                count: data.length,
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const CircleAvatar(
                      radius: 5,
                      backgroundColor: Colors.green,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: TextStyle(
                            height: 1.5,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          children: [
                            const TextSpan(
                              text: "Summary: ",
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            TextSpan(
                              text: data.length < 3
                                  ? "Not enough data yet. Keep ESP32 connected to build history."
                                  : "Environmental conditions recorded across ${data.length} data points. ${temps.isNotEmpty && _avg(temps) > 28 ? 'Temperature trending high — check ventilation.' : 'Temperature within normal range.'}",
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AnalyticsSummaryCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _AnalyticsSummaryCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: color,
            ),
          ),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class _AnalyticsInsightCard extends StatelessWidget {
  final List<double> temps, hums;
  final int count;
  const _AnalyticsInsightCard({
    required this.temps,
    required this.hums,
    required this.count,
  });

  double _avg(List<double> v) =>
      v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;

  @override
  Widget build(BuildContext context) {
    final avgTemp = _avg(temps);
    final avgHum = _avg(hums);

    final insights = <String>[];
    if (avgTemp > 28) {
      insights.add(
        "⚠️ Temperature averaging ${avgTemp.toStringAsFixed(1)}°C — above comfort zone.",
      );
    }
    if (avgTemp >= 20 && avgTemp <= 26) {
      insights.add(
        "✅ Temperature averaging ${avgTemp.toStringAsFixed(1)}°C — ideal range.",
      );
    }
    if (avgHum > 60) {
      insights.add(
        "💧 Humidity averaging ${avgHum.toStringAsFixed(0)}% — consider dehumidification.",
      );
    }
    if (avgHum >= 30 && avgHum <= 60) {
      insights.add(
        "✅ Humidity at ${avgHum.toStringAsFixed(0)}% — optimal level.",
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.insights, color: Colors.purple, size: 18),
              const SizedBox(width: 8),
              Text(
                "Insights",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                "$count readings",
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (insights.isEmpty)
            Text(
              "Keep monitoring — insights appear after more data is collected.",
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
                fontSize: 13,
              ),
            )
          else
            ...insights.map(
              (s) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  s,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TrendCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor, chartColor;
  final String label, currentValue, min, max, avg;
  final List<double> values;

  const _TrendCard({
    required this.icon,
    required this.iconColor,
    required this.chartColor,
    required this.label,
    required this.currentValue,
    required this.min,
    required this.max,
    required this.avg,
    required this.values,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 18),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  color: Colors.grey,
                ),
              ),
              const Spacer(),
            ],
          ),
          Text(
            currentValue,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 60,
            child: CustomPaint(
              size: const Size(double.infinity, 60),
              painter: _AreaChartPainter(values: values, color: chartColor),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _StatCell("MIN", min),
              Container(
                width: 1,
                height: 30,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              _StatCell("MAX", max),
              Container(
                width: 1,
                height: 30,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              _StatCell("AVG", avg),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final String label, value;
  const _StatCell(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: Colors.grey,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
      ],
    );
  }
}

class _AreaChartPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  const _AreaChartPainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) {
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        Paint()
          ..color = Colors.grey.shade300
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
      return;
    }
    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final range = (maxV - minV).clamp(1.0, double.infinity);
    double x(int i) => size.width * i / (values.length - 1);
    double y(double v) =>
        size.height -
        (size.height * 0.8 * (v - minV) / range) -
        size.height * 0.1;

    final fillPath = Path()
      ..moveTo(x(0), size.height)
      ..lineTo(x(0), y(values[0]));
    final linePath = Path()..moveTo(x(0), y(values[0]));

    // Use cubic bezier curves so the line faithfully tracks each data point
    // while staying smooth rather than jagged straight lines.
    for (int i = 1; i < values.length; i++) {
      final x0 = x(i - 1);
      final y0 = y(values[i - 1]);
      final x1 = x(i);
      final y1 = y(values[i]);
      final cpX = (x0 + x1) / 2;
      linePath.cubicTo(cpX, y0, cpX, y1, x1, y1);
      fillPath.cubicTo(cpX, y0, cpX, y1, x1, y1);
    }
    fillPath
      ..lineTo(x(values.length - 1), size.height)
      ..close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.2), color.withValues(alpha: 0.0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      linePath,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_) => true;
}

// ═══════════════════════════════════════════════════════
//  SCREEN 3 — ALERTS
// ═══════════════════════════════════════════════════════
class AlertsScreen extends StatefulWidget {
  final double temperature, humidity, light;
  final bool hasData;
  const AlertsScreen({
    super.key,
    required this.temperature,
    required this.humidity,
    required this.light,
    required this.hasData,
  });

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  String _filter = "All";

  List<AlertItem> get _allAlerts => alertManager.alerts.toList();

  List<AlertItem> get _filtered {
    switch (_filter) {
      case "Critical":
        return _allAlerts.where((a) => a.type == 'Critical').toList();
      case "Warnings":
        return _allAlerts.where((a) => a.type == 'Warning').toList();
      case "Resolved":
        return _allAlerts.where((a) => a.type == 'Resolved').toList();
      default:
        return _allAlerts;
    }
  }

  void _handleAction(AlertItem alert, String action) {
    alertManager.resolveAlert(alert.id);
    if (mounted) setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("✓ Action taken: $action"),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allAlerts = _allAlerts;
    final critCount = allAlerts.where((a) => a.type == 'Critical').length;
    final warnCount = allAlerts.where((a) => a.type == 'Warning').length;
    final filtered = _filtered;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        title: const Text(
          "Alerts & Recommendations",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ),
      body: StreamBuilder<List<AlertItem>>(
        stream: alertManager.stream,
        builder: (context, snapshot) {
          final allA = alertManager.alerts.toList();
          final critC = allA.where((a) => a.type == 'Critical').length;
          final warnC = allA.where((a) => a.type == 'Warning').length;
          final List<AlertItem> filteredA;
          switch (_filter) {
            case "Critical":
              filteredA = allA.where((a) => a.type == 'Critical').toList();
              break;
            case "Warnings":
              filteredA = allA.where((a) => a.type == 'Warning').toList();
              break;
            case "Resolved":
              filteredA = allA.where((a) => a.type == 'Resolved').toList();
              break;
            default:
              filteredA = allA;
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _filterChip("All", allA.length),
                      _filterChip("Critical", critC),
                      _filterChip("Warnings", warnC),
                      _filterChip(
                        "Resolved",
                        allA.where((a) => a.type == 'Resolved').length,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "System Status",
                              style: TextStyle(
                                color: Colors.blue,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              widget.hasData
                                  ? "${critC + warnC} active alerts require attention"
                                  : "Connect ESP32 to monitor alerts",
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.hasData) ...[
                        _StatusBadge(
                          "$critC\nCRIT",
                          Colors.red.shade50,
                          Colors.red,
                        ),
                        const SizedBox(width: 8),
                        _StatusBadge(
                          "$warnC\nWARN",
                          Colors.orange.shade50,
                          Colors.orange,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (!widget.hasData)
                  Container(
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Center(
                      child: Column(
                        children: [
                          Icon(
                            Icons.bluetooth_disabled,
                            size: 48,
                            color: Colors.grey,
                          ),
                          SizedBox(height: 12),
                          Text(
                            "No alerts yet. Connect ESP32 to monitor.",
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  )
                else ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "RECENT NOTIFICATIONS",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                          letterSpacing: 1.2,
                        ),
                      ),
                      Text(
                        "${filteredA.length} items",
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.blue,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (filteredA.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Center(
                        child: Text(
                          "No ${_filter == 'All' ? '' : _filter.toLowerCase()} alerts in this category.",
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  else
                    ...filteredA.map(
                      (a) => _AlertCard(
                        alert: a,
                        onAction: (action) => _handleAction(a, action),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.wb_sunny_outlined,
                          color: Colors.orange,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "Energy Saving Tip",
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "Reducing temperature by just 1°C can decrease energy consumption by up to 6% per hour.",
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.4,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _filterChip(String label, int count) {
    final sel = _filter == label;
    return GestureDetector(
      onTap: () => setState(() => _filter = label),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: sel ? Colors.blue : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: sel ? Colors.blue : Theme.of(context).colorScheme.outline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: sel ? Colors.white : Colors.grey,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: sel
                      ? Colors.white.withValues(alpha: 0.3)
                      : Colors.blue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  "$count",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: sel ? Colors.white : Colors.blue,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String text;
  final Color bg, fg;
  const _StatusBadge(this.text, this.bg, this.fg);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: fg,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          height: 1.3,
        ),
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  final AlertItem alert;
  final void Function(String action) onAction;
  const _AlertCard({required this.alert, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final Color c = alert.isResolved ? Colors.green : alert.color;
    final bool isCritical = alert.type == "Critical";
    final bool isResolved = alert.isResolved || alert.type == "Resolved";

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isCritical ? c : Theme.of(context).colorScheme.outlineVariant,
          width: isCritical ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isResolved ? Icons.check_circle_outline : alert.icon,
                color: c,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    children: [
                      TextSpan(text: "${alert.title}: "),
                      TextSpan(
                        text: alert.highlight,
                        style: TextStyle(color: c),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  isResolved ? "Resolved" : alert.type,
                  style: TextStyle(
                    color: c,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '"${alert.desc}"',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.access_time, size: 12, color: Colors.grey),
              const SizedBox(width: 4),
              Text(
                alert.time,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (!isResolved)
            Wrap(
              spacing: 8,
              children: alert.actions
                  .map(
                    (a) => OutlinedButton(
                      onPressed: () => onAction(a),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      child: Text(a, style: const TextStyle(fontSize: 12)),
                    ),
                  )
                  .toList(),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check, size: 12, color: Colors.green),
                  SizedBox(width: 4),
                  Text(
                    "Action taken — resolved",
                    style: TextStyle(color: Colors.green, fontSize: 12),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  SCREEN 4 — HISTORY LOGS
// ═══════════════════════════════════════════════════════
class HistoryScreen extends StatefulWidget {
  final List<SensorData> historyLog;
  const HistoryScreen({super.key, required this.historyLog});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _period = "Today";
  DateTime? _customDate;

  List<SensorData> get _filtered {
    if (widget.historyLog.isEmpty) return [];
    final now = DateTime.now();
    List<SensorData> raw;
    switch (_period) {
      case "Yesterday":
        final yStart = DateTime(now.year, now.month, now.day - 1);
        final yEnd = DateTime(now.year, now.month, now.day);
        raw = widget.historyLog
            .where(
              (d) => d.timestamp.isAfter(yStart) && d.timestamp.isBefore(yEnd),
            )
            .toList();
        break;
      case "Last 7 Days":
        raw = widget.historyLog
            .where((d) => now.difference(d.timestamp).inDays < 7)
            .toList();
        break;
      case "Last Month":
        raw = widget.historyLog
            .where((d) => now.difference(d.timestamp).inDays < 30)
            .toList();
        break;
      case "Custom":
        if (_customDate != null) {
          final dayStart = DateTime(
            _customDate!.year,
            _customDate!.month,
            _customDate!.day,
          );
          final dayEnd = dayStart.add(const Duration(days: 1));
          raw = widget.historyLog
              .where(
                (d) =>
                    d.timestamp.isAfter(dayStart) &&
                    d.timestamp.isBefore(dayEnd),
              )
              .toList();
        } else {
          raw = [];
        }
        break;
      default:
        final todayStart = DateTime(now.year, now.month, now.day);
        raw = widget.historyLog
            .where((d) => d.timestamp.isAfter(todayStart))
            .toList();
    }
    final Map<String, SensorData> hourBuckets = {};
    for (final d in raw) {
      final key =
          '${d.timestamp.year}-${d.timestamp.month}-${d.timestamp.day}-${d.timestamp.hour}';
      hourBuckets.putIfAbsent(key, () => d);
    }
    final result = hourBuckets.values.toList();
    result.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return result;
  }

  double _avg(List<double> v) =>
      v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;

  Future<void> _jumpToDate(BuildContext ctx) async {
    final picked = await showDatePicker(
      context: ctx,
      initialDate: DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
      helpText: 'JUMP TO DATE',
    );
    if (picked == null) return;
    final dayStart = DateTime(picked.year, picked.month, picked.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final dayData = widget.historyLog
        .where(
          (d) => d.timestamp.isAfter(dayStart) && d.timestamp.isBefore(dayEnd),
        )
        .toList();
    if (!mounted) return;
    if (dayData.isEmpty) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text('No data found for ${_fmtDate(picked)}'),
          backgroundColor: Colors.orange,
        ),
      );
    } else {
      setState(() {
        _period = "Custom";
        _customDate = picked;
      });
    }
  }

  Future<void> _showDownloadDialog(BuildContext ctx) async {
    DateTimeRange? picked = await showDateRangePicker(
      context: ctx,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
      helpText: 'SELECT DATE RANGE TO DOWNLOAD',
    );
    if (picked == null || !mounted) return;
    final rangeData = widget.historyLog.where((d) {
      return d.timestamp.isAfter(picked.start) &&
          d.timestamp.isBefore(picked.end.add(const Duration(days: 1)));
    }).toList();
    if (!mounted) return;
    if (rangeData.isEmpty) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(
          content: Text('No data in selected range.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final buffer = StringBuffer();
    buffer.writeln('Date,Time,Temperature (°C),Humidity (%)');
    for (final d in rangeData.reversed) {
      buffer.writeln(
        '${_fmtDate(d.timestamp)},${_fmt(d.timestamp)},${d.temperature.toStringAsFixed(1)},${d.humidity.toStringAsFixed(0)}',
      );
    }
    final csv = buffer.toString();
    if (!mounted) return;
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Download Data'),
        content: SizedBox(
          width: double.maxFinite,
          height: 200,
          child: SingleChildScrollView(
            child: Text(
              csv,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(ctx).showSnackBar(
                SnackBar(
                  content: Text(
                    'CSV with ${rangeData.length} records ready. Integrate file_picker to save.',
                  ),
                  backgroundColor: Colors.green,
                ),
              );
            },
            icon: const Icon(Icons.download, size: 16),
            label: const Text('Export CSV'),
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime dt) {
    final h = dt.hour, m = dt.minute.toString().padLeft(2, '0');
    final ampm = h >= 12 ? "PM" : "AM";
    final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return "$h12:$m $ampm";
  }

  String _fmtDate(DateTime dt) {
    const months = [
      "JAN",
      "FEB",
      "MAR",
      "APR",
      "MAY",
      "JUN",
      "JUL",
      "AUG",
      "SEP",
      "OCT",
      "NOV",
      "DEC",
    ];
    return "${months[dt.month - 1]} ${dt.day}";
  }

  @override
  Widget build(BuildContext context) {
    final data = _filtered;
    final temps = data.map((d) => d.temperature).toList();
    final hums = data.map((d) => d.humidity).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        title: const Text(
          "History Logs",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: "Download Data",
            onPressed: () => _showDownloadDialog(context),
          ),
          IconButton(
            icon: const Icon(Icons.calendar_month_outlined),
            tooltip: "Jump to Date",
            onPressed: () => _jumpToDate(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "VIEWING DATA",
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      data.isEmpty
                          ? "No records"
                          : "${_fmtDate(data.last.timestamp)} - ${_fmtDate(data.first.timestamp)}, ${data.first.timestamp.year}",
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    "${data.length} Records",
                    style: const TextStyle(
                      color: Colors.blue,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: ["Today", "Yesterday", "Last 7 Days", "Last Month"]
                    .map((p) {
                      final sel = _period == p;
                      return GestureDetector(
                        onTap: () => setState(() => _period = p),
                        child: Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: sel
                                ? Colors.blue
                                : Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: sel
                                  ? Colors.blue
                                  : Theme.of(context).colorScheme.outline,
                            ),
                          ),
                          child: Text(
                            p,
                            style: TextStyle(
                              color: sel ? Colors.white : Colors.grey,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      );
                    })
                    .toList(),
              ),
            ),
            const SizedBox(height: 16),
            if (data.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _AvgCell("AVG TEMP", "${_avg(temps).toStringAsFixed(1)}°C"),
                    Container(
                      width: 1,
                      height: 40,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    _AvgCell("AVG HUMID", "${_avg(hums).toStringAsFixed(0)}%"),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: const [
                Icon(Icons.filter_list, size: 14, color: Colors.grey),
                SizedBox(width: 4),
                Text(
                  "HISTORICAL TIMELINE",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (data.isEmpty)
              Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Center(
                  child: Column(
                    children: [
                      Icon(Icons.history, size: 48, color: Colors.grey),
                      SizedBox(height: 12),
                      Text(
                        "No history yet. Connect ESP32 to start logging.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              )
            else
              ...data.take(20).map((d) {
                final isAnomaly = d.temperature > 30 || d.humidity > 65;
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isAnomaly
                          ? Colors.red.shade200
                          : Colors.blue.shade100,
                      width: isAnomaly ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 70,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _fmt(d.timestamp),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            Text(
                              _fmtDate(d.timestamp),
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 36,
                        color: Theme.of(context).colorScheme.outlineVariant,
                        margin: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      Expanded(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _LogCell(
                              Icons.thermostat,
                              "TEMP",
                              "${d.temperature.toStringAsFixed(1)}°C",
                            ),
                            _LogCell(
                              Icons.water_drop,
                              "HUMID",
                              "${d.humidity.toStringAsFixed(0)}%",
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right,
                        color: Colors.grey,
                        size: 18,
                      ),
                    ],
                  ),
                );
              }),
            if (data.length > 20)
              Center(
                child: TextButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.north_east, size: 14),
                  label: const Text("Load Older Records"),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AvgCell extends StatelessWidget {
  final String label, value;
  const _AvgCell(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: Colors.blue,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ],
    );
  }
}

class _LogCell extends StatelessWidget {
  final IconData icon;
  final String label, value;
  const _LogCell(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 10, color: Colors.grey),
            const SizedBox(width: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 9, color: Colors.grey),
            ),
          ],
        ),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════
//  SCREEN 5 — PROFILE SETTINGS
// ═══════════════════════════════════════════════════════
class ProfileScreen extends StatefulWidget {
  final VoidCallback? onProfileUpdated;
  final bool pushNotif;
  final ValueChanged<bool> onPushNotifChanged;

  const ProfileScreen({
    super.key,
    this.onProfileUpdated,
    required this.pushNotif,
    required this.onPushNotifChanged,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _surnameCtrl;
  late TextEditingController _firstNameCtrl;
  late TextEditingController _mobileCtrl;
  late TextEditingController _emailCtrl;
  late TextEditingController _usernameCtrl;
  late String _selectedRoom;

  bool get _darkMode => themeNotifier.value == ThemeMode.dark;
  bool _autoFan = true;
  bool _isEditing = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _initControllers();
  }

  void _initControllers() {
    _surnameCtrl = TextEditingController(text: userProfile.surname);
    _firstNameCtrl = TextEditingController(text: userProfile.firstName);
    _mobileCtrl = TextEditingController(text: userProfile.mobileNumber);
    _emailCtrl = TextEditingController(text: userProfile.email);
    _usernameCtrl = TextEditingController(text: userProfile.username);
    _selectedRoom = userProfile.typeOfRoom;
  }

  @override
  void dispose() {
    _surnameCtrl.dispose();
    _firstNameCtrl.dispose();
    _mobileCtrl.dispose();
    _emailCtrl.dispose();
    _usernameCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveChanges() async {
    if (!_formKey.currentState!.validate()) return;
    if (userProfile.id == null) return;

    setState(() => _isSaving = true);

    final success = await DatabaseHelper.instance.updateProfile(
      userId: userProfile.id!,
      surname: _surnameCtrl.text.trim(),
      firstName: _firstNameCtrl.text.trim(),
      mobileNumber: _mobileCtrl.text.trim(),
      username: _usernameCtrl.text.trim(),
      typeOfRoom: _selectedRoom,
    );

    if (!mounted) return;
    setState(() => _isSaving = false);

    if (success) {
      // Update in-memory profile
      userProfile.surname = _surnameCtrl.text.trim();
      userProfile.firstName = _firstNameCtrl.text.trim();
      userProfile.mobileNumber = _mobileCtrl.text.trim();
      userProfile.username = _usernameCtrl.text.trim();
      userProfile.typeOfRoom = _selectedRoom;

      setState(() => _isEditing = false);
      widget.onProfileUpdated?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Profile updated successfully!"),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Username may already be taken."),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _cancelEdit() {
    _formKey.currentState?.reset();
    _initControllers();
    setState(() => _isEditing = false);
  }

  InputDecoration _fieldDec(
    String label,
    IconData icon, {
    bool enabled = true,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      filled: true,
      fillColor: enabled
          ? Theme.of(context).colorScheme.surface
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      enabled: enabled,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        title: const Text(
          "Settings & Profile",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          if (!_isEditing)
            TextButton.icon(
              onPressed: () => setState(() => _isEditing = true),
              icon: const Icon(Icons.edit, size: 16, color: Colors.blue),
              label: const Text("Edit", style: TextStyle(color: Colors.blue)),
            )
          else ...[
            TextButton(
              onPressed: _cancelEdit,
              child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: _isSaving ? null : _saveChanges,
              child: const Text(
                "Save",
                style: TextStyle(
                  color: Colors.blue,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              // ── Avatar ──
              Center(
                child: Stack(
                  children: [
                    ValueListenableBuilder<ThemeMode>(
                      valueListenable: themeNotifier,
                      builder: (_, __, ___) =>
                          AutoAvatar(radius: 44, profile: userProfile),
                    ),
                    if (_isEditing)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.blue,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.edit,
                            color: Colors.white,
                            size: 14,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                userProfile.fullName,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              Text(
                userProfile.email,
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 24),

              _sectionLabel("PERSONAL INFORMATION"),
              const SizedBox(height: 12),
              TextFormField(
                controller: _surnameCtrl,
                enabled: _isEditing,
                textCapitalization: TextCapitalization.words,
                decoration: _fieldDec(
                  "Surname",
                  Icons.person_outline,
                  enabled: _isEditing,
                ),
                validator: (v) => _isEditing && (v == null || v.trim().isEmpty)
                    ? "Enter your surname"
                    : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _firstNameCtrl,
                enabled: _isEditing,
                textCapitalization: TextCapitalization.words,
                decoration: _fieldDec(
                  "First Name",
                  Icons.badge_outlined,
                  enabled: _isEditing,
                ),
                validator: (v) => _isEditing && (v == null || v.trim().isEmpty)
                    ? "Enter your first name"
                    : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _mobileCtrl,
                enabled: _isEditing,
                keyboardType: TextInputType.phone,
                decoration: _fieldDec(
                  "Mobile Number",
                  Icons.phone_outlined,
                  enabled: _isEditing,
                ),
              ),
              const SizedBox(height: 24),

              _sectionLabel("ACCOUNT DETAILS"),
              const SizedBox(height: 12),
              // Email is read-only — cannot be changed after registration
              TextFormField(
                controller: _emailCtrl,
                enabled: false,
                decoration: _fieldDec(
                  "Email Address",
                  Icons.email_outlined,
                  enabled: false,
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _usernameCtrl,
                enabled: _isEditing,
                decoration: _fieldDec(
                  "Username",
                  Icons.alternate_email,
                  enabled: _isEditing,
                ),
                validator: (v) => _isEditing && (v == null || v.trim().isEmpty)
                    ? "Choose a username"
                    : null,
              ),
              const SizedBox(height: 24),

              _sectionLabel("ROOM CONFIGURATION"),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _selectedRoom,
                decoration: InputDecoration(
                  labelText: "Type of Room",
                  prefixIcon: const Icon(Icons.meeting_room_outlined),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: _isEditing
                      ? Theme.of(context).colorScheme.surface
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                items: kRoomTypes
                    .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                    .toList(),
                onChanged: _isEditing
                    ? (v) => setState(() => _selectedRoom = v!)
                    : null,
              ),
              const SizedBox(height: 24),

              _sectionLabel("PREFERENCES"),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Column(
                  children: [
                    _PrefTile(
                      icon: Icons.dark_mode_outlined,
                      title: "Dark Mode",
                      subtitle: "Adjust app appearance for night use",
                      value: _darkMode,
                      onChanged: (v) {
                        themeNotifier.value = v
                            ? ThemeMode.dark
                            : ThemeMode.light;
                        setState(() {});
                      },
                    ),
                    const Divider(height: 1),
                    _PrefTile(
                      icon: Icons.notifications_none,
                      title: "Push Notifications",
                      subtitle: "Receive instant room condition alerts",
                      value: widget.pushNotif,
                      onChanged: widget.onPushNotifChanged,
                    ),
                    const Divider(height: 1),
                    _PrefTile(
                      icon: Icons.air,
                      title: "Auto-Fan Activation",
                      subtitle: "Enable fan when temp exceeds 28°C",
                      value: _autoFan,
                      onChanged: (v) => setState(() => _autoFan = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              _sectionLabel("EMERGENCY SYSTEM"),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Primary Contact Number",
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.phone_outlined, size: 16),
                          const SizedBox(width: 8),
                          Text(
                            userProfile.mobileNumber.isNotEmpty
                                ? userProfile.mobileNumber
                                : "+1 (415) 555-0198",
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      "This number will be automatically dialed in case of critical environmental failures or fire detection.",
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        fontStyle: FontStyle.italic,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              if (_isEditing)
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isSaving ? null : _saveChanges,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _isSaving
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text(
                            "Save All Changes",
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                  ),
                ),
              const SizedBox(height: 8),

              TextButton.icon(
                onPressed: () async {
                  await clearSession();
                  themeNotifier.value = ThemeMode.light;
                  if (!context.mounted) return;
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginPage()),
                    (r) => false,
                  );
                },
                icon: const Icon(Icons.logout, size: 16, color: Colors.red),
                label: const Text(
                  "Log Out from Session",
                  style: TextStyle(color: Colors.red),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                "SMARTROOM V2.4.1 (BUILD 882)",
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.grey,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String t) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      t,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        color: Colors.grey,
        letterSpacing: 1.2,
      ),
    ),
  );
}

class _PrefTile extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _PrefTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.grey),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: Colors.blue,
      ),
    );
  }
}
