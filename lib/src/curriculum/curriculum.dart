/// 课表模型。
///
/// 与 rollcall-go 内部 `edge/poller.go` 的 [CurriculumInstance] / [CurriculumData]
/// 一一对应。
library;

/// 一次课实例。
class CurriculumInstance {
  const CurriculumInstance({
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.course,
    required this.location,
  });

  /// `YYYY-MM-DD`。
  final String date;

  /// `HH:MM`。
  final String startTime;

  /// `HH:MM`。
  final String endTime;

  /// 课程名称。
  final String course;

  /// 教学地点（如 `2306`、`综合实验楼A305`）。
  final String location;

  factory CurriculumInstance.fromJson(Map<String, dynamic> json) =>
      CurriculumInstance(
        date: json['date'] as String? ?? '',
        startTime: json['start_time'] as String? ?? '',
        endTime: json['end_time'] as String? ?? '',
        course: json['course'] as String? ?? '',
        location: json['location'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'date': date,
        'start_time': startTime,
        'end_time': endTime,
        'course': course,
        'location': location,
      };
}

/// 课表完整数据。
class CurriculumData {
  const CurriculumData({this.instances = const []});

  final List<CurriculumInstance> instances;

  factory CurriculumData.fromJson(Map<String, dynamic> json) {
    final list = (json['instances'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(CurriculumInstance.fromJson)
        .toList(growable: false);
    return CurriculumData(instances: list);
  }

  Map<String, dynamic> toJson() => {
        'instances': instances.map((i) => i.toJson()).toList(),
      };

  /// 所有不同课程名。
  Iterable<String> get courses => instances.map((i) => i.course).toSet();
}
