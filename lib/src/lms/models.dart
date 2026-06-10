/// LMS 域数据模型。
///
/// 字段命名与 rollcall-go 内部 `lms.Rollcall` / `CheckinResult` 一致，
/// 便于在两个 SDK 之间互操作。
library;

/// 签到任务。
class Rollcall {
  const Rollcall({
    required this.rollcallId,
    required this.source,
    required this.status,
    required this.courseTitle,
    required this.rollcallTime,
    this.createdByName = '',
  });

  /// 签到任务 ID。
  final int rollcallId;

  /// 签到类型：`qr` / `number` / `radar`。
  final String source;

  /// 签到状态：`absent`（未签） / `on_call`（已签）。
  final String status;

  /// 课程名称。
  final String courseTitle;

  /// 签到发起时间，ISO8601 UTC。
  final String rollcallTime;

  /// 教师姓名（对应 API `created_by_name`）。
  final String createdByName;

  /// 是否未签到。
  bool get isAbsent => status == 'absent';

  /// 是否已签到。
  bool get isOnCall => status == 'on_call';

  /// 是否二维码签到。
  bool get isQr => source == 'qr';

  /// 是否数字码签到。
  bool get isNumber => source == 'number';

  /// 是否雷达（定位）签到。
  bool get isRadar => source == 'radar';

  factory Rollcall.fromJson(Map<String, dynamic> json) => Rollcall(
        rollcallId: (json['rollcall_id'] as num).toInt(),
        source: json['source'] as String? ?? '',
        status: json['status'] as String? ?? '',
        courseTitle: json['course_title'] as String? ?? '',
        rollcallTime: json['rollcall_time'] as String? ?? '',
        createdByName: json['created_by_name'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'rollcall_id': rollcallId,
        'source': source,
        'status': status,
        'course_title': courseTitle,
        'rollcall_time': rollcallTime,
        'created_by_name': createdByName,
      };

  @override
  String toString() => 'Rollcall(id=$rollcallId, type=$source, status=$status, '
      'course=$courseTitle, teacher=$createdByName)';
}

/// 签到结果（与 rollcall-go 的 `CheckinResult` 对应）。
class CheckinResult {
  const CheckinResult({required this.success, this.errorCode = ''});

  /// 是否签到成功。
  final bool success;

  /// 服务端下发的错误码；成功时为空。
  final String errorCode;

  @override
  String toString() => success
      ? 'CheckinResult.success'
      : 'CheckinResult.failed(code=$errorCode)';
}

/// 学生签到详情。
class StudentRollcallsData {
  const StudentRollcallsData({
    required this.isNumber,
    required this.numberCode,
    required this.rollcalls,
    this.courseTitle = '',
    this.classroom = '',
    this.teacher = '',
  });

  /// 当前签到是否为数字码签到。
  final bool isNumber;

  /// 数字码签到时的签到码（仅 `isNumber` 为 true 且有人签到后才有值）。
  final String numberCode;

  /// 班级成员签到状态列表。
  final List<StudentRollcall> rollcalls;

  /// 课程名称。
  final String courseTitle;

  /// 教室（如 `2306`、`综合实验楼A305`）。
  final String classroom;

  /// 教师姓名。
  final String teacher;

  /// 状态为 `on_call` 的成员数。
  int get checkedInCount => rollcalls.where((r) => r.isOnCall).length;

  factory StudentRollcallsData.fromJson(Map<String, dynamic> json) {
    final list = (json['student_rollcalls'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(StudentRollcall.fromJson)
        .toList(growable: false);
    return StudentRollcallsData(
      isNumber: json['is_number'] as bool? ?? false,
      numberCode: json['number_code'] as String? ?? '',
      rollcalls: list,
      courseTitle: json['course_title'] as String? ?? '',
      classroom: json['classroom'] as String? ?? '',
      teacher: json['teacher'] as String? ?? '',
    );
  }
}

/// 单个学生签到状态。
class StudentRollcall {
  const StudentRollcall({required this.status});

  final String status;

  bool get isOnCall => status == 'on_call';
  bool get isAbsent => status == 'absent';

  factory StudentRollcall.fromJson(Map<String, dynamic> json) =>
      StudentRollcall(status: json['status'] as String? ?? '');
}
