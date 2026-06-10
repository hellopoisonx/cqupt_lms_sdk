/// LMS 签到轮询器。
///
/// 行为复刻 rollcall-go `internal/edge/poller.go`：
///   - 周期性拉取活跃签到（默认 30s）；
///   - 仅在「课前 + 课中」窗口内执行轮询（依赖课表）；
///   - 自动雷达签到（依据当前课程地点解析坐标）；
///   - 自动数字签到（发现有人已签到后用同号抢签）；
///   - 暴露 [Stream] 事件便于 UI 订阅；
///   - 支持外部 [triggerPoll] 立即唤醒（签到成功后立刻拉一次最新状态）。
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../curriculum/curriculum.dart';
import '../exceptions.dart';
import '../lms/lms_client.dart';
import '../lms/models.dart';
import '../location/buildings.dart';

/// Poller 事件。
sealed class PollerEvent {
  const PollerEvent();
}

/// 发现新的活跃签到。
class ActiveRollcallEvent extends PollerEvent {
  const ActiveRollcallEvent(this.rollcall);
  final Rollcall rollcall;
}

/// 签到完成（状态从 absent 变为 on_call）。
class CompletedRollcallEvent extends PollerEvent {
  const CompletedRollcallEvent(this.rollcall);
  final Rollcall rollcall;
}

/// 自动签到结果。
class AutoCheckinEvent extends PollerEvent {
  const AutoCheckinEvent({
    required this.rollcall,
    required this.kind,
    required this.success,
    required this.errorCode,
  });
  final Rollcall rollcall;

  /// `'radar'` / `'number'`。
  final String kind;
  final bool success;
  final String errorCode;
}

/// Poller 配置。
class PollerConfig {
  const PollerConfig({
    this.pollInterval = const Duration(seconds: 30),
    this.curriculumPreMinutes = 10,
    this.autoLocationCheckin = true,
    this.autoNumberCheckin = true,
    this.maxConsecutiveErrors = 3,
  });

  /// 主轮询间隔。
  final Duration pollInterval;

  /// 课前提前轮询分钟数。
  final int curriculumPreMinutes;

  /// 是否开启自动定位签到。
  final bool autoLocationCheckin;

  /// 是否开启自动数字签到。
  final bool autoNumberCheckin;

  /// 连续失败多少次后抛出异常。
  final int maxConsecutiveErrors;
}

/// 轮询器。构造时绑定 [LmsClient]。
class Poller {
  Poller(
    this.lmsClient, {
    PollerConfig? config,
    CurriculumData? initialCurriculum,
    Logger? logger,
  })  : _config = config ?? const PollerConfig(),
        _log = logger ?? Logger('cqupt_lms_sdk.poller') {
    if (initialCurriculum != null) _curriculum = initialCurriculum;
  }

  final LmsClient lmsClient;
  final PollerConfig _config;
  final Logger _log;

  final _eventController = StreamController<PollerEvent>.broadcast();
  final _triggerController = StreamController<void>();
  bool _running = false;

  CurriculumData? _curriculum;

  final Map<int, Rollcall> _active = <int, Rollcall>{};
  final Set<int> _completed = <int>{};
  final Map<String, int> _logCache = <String, int>{};
  int _consecutiveErrors = 0;

  /// 订阅事件流。多次调用返回独立广播流。
  Stream<PollerEvent> get events => _eventController.stream;

  /// 当前已知的课表。
  CurriculumData? get curriculum => _curriculum;

  /// 启动轮询主循环。会同时启动 trigger 监听。
  ///
  /// 多次启动将抛出 [PollerAlreadyRunningException]。
  Future<void> run() async {
    if (_running) throw const PollerAlreadyRunningException();
    _running = true;
    _log.info('轮询签到已启动，间隔=${_config.pollInterval.inSeconds}s');

    final triggerSub = _triggerController.stream.listen((_) {
      _log.fine('轮询被主动触发');
    });

    try {
      while (_running) {
        try {
          await _tick();
        } on Object catch (e, st) {
          _log.severe('轮询异常: $e', e, st);
        }
        if (!_running) break;
        await Future.any([
          Future.delayed(_config.pollInterval),
          _triggerController.stream.first,
        ]);
      }
    } finally {
      await triggerSub.cancel();
      _log.info('轮询签到已停止');
    }
  }

  /// 主动唤醒一次轮询（不等计时器）。
  void triggerPoll() {
    if (_triggerController.isClosed) return;
    _triggerController.add(null);
  }

  /// 替换当前课表。
  /// 替换当前课表。
  void setCurriculum(CurriculumData data) {
    _curriculum = data;
  }

  /// 停止主循环。
  void stop() {
    _running = false;
    triggerPoll();
  }

  /// 释放资源。
  Future<void> close() async {
    stop();
    await _eventController.close();
    await _triggerController.close();
  }

  // ------------------------------------------------------------------
  // 内部
  // ------------------------------------------------------------------

  Future<void> _tick() async {
    if (!_shouldPoll()) {
      _log.fine('当前不在轮询窗口内，跳过');
      return;
    }
    List<Rollcall> rollcalls;
    try {
      rollcalls = await lmsClient.getRollcalls();
    } on Object catch (e) {
      _consecutiveErrors++;
      _emitLog('get_rollcalls_error: $e');
      if (_consecutiveErrors >= _config.maxConsecutiveErrors) {
        rethrow;
      }
      return;
    }
    _consecutiveErrors = 0;

    // 1. 状态变化事件
    for (final r in rollcalls) {
      if (!_active.containsKey(r.rollcallId) && r.isAbsent) {
        _log.info('发现活跃签到: id=${r.rollcallId}, type=${r.source}, '
            'course=${r.courseTitle}');
        _eventController.add(ActiveRollcallEvent(r));
      }
      final prev = _active[r.rollcallId];
      if (prev != null && prev.isAbsent && !r.isAbsent && !_completed.contains(r.rollcallId)) {
        _completed.add(r.rollcallId);
        _eventController.add(CompletedRollcallEvent(r));
      }
    }
    _active
      ..clear()
      ..addEntries(rollcalls.map((r) => MapEntry(r.rollcallId, r)));

    // 2. 自动定位签到
    if (_config.autoLocationCheckin) {
      final inst = _currentCourseInstance(DateTime.now());
      if (inst != null) {
        for (final r in rollcalls) {
          if (!r.isRadar || !r.isAbsent) continue;
          final coord = getLocationCoords(inst.location);
          if (coord == null) {
            _emitLog('location_coords_not_found: ${inst.location}');
            continue;
          }
          _log.info('自动定位签到: course=${inst.course}, location=${inst.location}');
          final result = await lmsClient.doCheckin(r.rollcallId, 'radar', {
            'lat': coord.lat,
            'lon': coord.lon,
          });
          _eventController.add(AutoCheckinEvent(
            rollcall: r,
            kind: 'radar',
            success: result.success,
            errorCode: result.errorCode,
          ));
          if (result.success) {
            _log.info('自动定位签到成功: ${r.courseTitle}');
            triggerPoll();
          } else {
            _emitLog('radar_checkin_failed: ${r.rollcallId}:${result.errorCode}');
          }
        }
      }
    }

    // 3. 自动数字签到
    if (_config.autoNumberCheckin) {
      for (final r in rollcalls) {
        if (!r.isNumber || !r.isAbsent) continue;
        final student = await lmsClient.getStudentRollcalls(r.rollcallId);
        if (student == null) {
          _emitLog('get_student_rollcalls_error: ${r.rollcallId}');
          continue;
        }
        if (student.isNumber &&
            student.numberCode.isNotEmpty &&
            student.checkedInCount > 0) {
          _log.info('自动数字签到: code=${student.numberCode}, '
              'course=${r.courseTitle}');
          final result = await lmsClient.doCheckin(r.rollcallId, 'number', {
            'numberCode': student.numberCode,
          });
          _eventController.add(AutoCheckinEvent(
            rollcall: r,
            kind: 'number',
            success: result.success,
            errorCode: result.errorCode,
          ));
          if (result.success) {
            _log.info('自动数字签到成功: ${r.courseTitle}');
            triggerPoll();
          } else {
            _emitLog('number_checkin_failed: ${r.rollcallId}:${result.errorCode}');
          }
        }
      }
    }
  }

  bool _shouldPoll() {
    final now = DateTime.now();
    final curriculum = _curriculum;
    if (curriculum == null) {
      // 没有课表时使用「上课时段」默认值。
      const windows = [
        [7 * 60 + 50, 12 * 60],
        [13 * 60 + 50, 18 * 60],
        [18 * 60 + 50, 22 * 60 + 40],
      ];
      final nowMin = now.hour * 60 + now.minute;
      return windows.any((w) => nowMin >= w[0] && nowMin <= w[1]);
    }

    final today = _formatDate(now);
    for (final inst in curriculum.instances) {
      if (inst.date != today) continue;
      final range = _parseTimeRange(inst.date, inst.startTime, inst.endTime);
      if (range == null) continue;
      final pollStart = range.$1.subtract(Duration(minutes: _config.curriculumPreMinutes));
      if (now.isAfter(pollStart) && now.isBefore(range.$2)) return true;
    }
    return false;
  }

  CurriculumInstance? _currentCourseInstance(DateTime checkTime) {
    final curriculum = _curriculum;
    if (curriculum == null) return null;
    final today = _formatDate(checkTime);
    for (final inst in curriculum.instances) {
      if (inst.date != today) continue;
      final range = _parseTimeRange(inst.date, inst.startTime, inst.endTime);
      if (range == null) continue;
      // 课前 15 分钟内即视为「当前课程」。
      if (checkTime.isAfter(range.$1.subtract(const Duration(minutes: 15))) &&
          checkTime.isBefore(range.$2)) {
        return inst;
      }
    }
    return null;
  }

  /// 根据签到时间反查课程实例的地点。供签到成功时把 `course_location` 写入
  /// 上传字段。
  String? getCourseLocationForRollcall(Rollcall r) {
    final rtStr = r.rollcallTime;
    if (rtStr.isEmpty) return null;
    DateTime? rt;
    try {
      rt = DateTime.parse(rtStr);
    } on FormatException {
      return null;
    }
    final local = rt.toLocal();
    return _currentCourseInstance(local)?.location;
  }

  void _emitLog(String key) {
    final n = ( _logCache[key] ?? 0) + 1;
    _logCache[key] = n;
    _log.fine('[$n] $key');
  }
}

String _formatDate(DateTime t) {
  final m = t.month.toString().padLeft(2, '0');
  final d = t.day.toString().padLeft(2, '0');
  return '${t.year}-$m-$d';
}

(DateTime, DateTime)? _parseTimeRange(String date, String start, String end) {
  try {
    final startDT = DateTime.parse('${date.replaceAll('-', '-')} $start:00');
    final endDT = DateTime.parse('${date.replaceAll('-', '-')} $end:00');
    return (startDT, endDT);
  } on FormatException {
    return null;
  }
}
