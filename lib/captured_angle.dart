class CapturedAngle {
  final int angleIndex;
  final String imagePath;
  final DateTime capturedAt;
  final double focusScore;
  final double lightingMean;
  final double lightingStdDev;
  final double yaw;
  final double pitch;
  final double rollStability;

  const CapturedAngle({
    required this.angleIndex,
    required this.imagePath,
    required this.capturedAt,
    required this.focusScore,
    required this.lightingMean,
    required this.lightingStdDev,
    required this.yaw,
    required this.pitch,
    required this.rollStability,
  });

  /// Returns true when this angle's quality is sufficient for RANSAC stitching.
  bool get isSuitableForStitching =>
      focusScore >= 60 &&
      lightingMean >= 60 &&
      lightingMean <= 200 &&
      rollStability >= 0.7;

  Map<String, dynamic> toMap() => {
    'angleIndex': angleIndex,
    'imagePath': imagePath,
    'capturedAt': capturedAt.toIso8601String(),
    'focusScore': focusScore,
    'lightingMean': lightingMean,
    'lightingStdDev': lightingStdDev,
    'yaw': yaw,
    'pitch': pitch,
    'rollStability': rollStability,
    'isSuitableForStitching': isSuitableForStitching,
  };

  Map<String, dynamic> toRansacMetadata() => {
    'angle_index': angleIndex,
    'focus_score': focusScore,
    'lighting_mean': lightingMean,
    'yaw': yaw,
    'pitch': pitch,
    'roll_stability': rollStability,
    'is_suitable': isSuitableForStitching,
  };

  factory CapturedAngle.fromMap(Map<String, dynamic> map) => CapturedAngle(
    angleIndex: map['angleIndex'] as int,
    imagePath: map['imagePath'] as String,
    capturedAt: DateTime.parse(map['capturedAt'] as String),
    focusScore: (map['focusScore'] as num).toDouble(),
    lightingMean: (map['lightingMean'] as num).toDouble(),
    lightingStdDev: (map['lightingStdDev'] as num).toDouble(),
    yaw: (map['yaw'] as num).toDouble(),
    pitch: (map['pitch'] as num).toDouble(),
    rollStability: (map['rollStability'] as num).toDouble(),
  );
}
