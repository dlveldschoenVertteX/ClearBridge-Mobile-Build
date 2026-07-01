/// Lightweight local equivalents of the hand_landmarker Hand/Landmark types.
/// Defined here so the entire hand_landmarker package (MediaPipe Tasks AAR,
/// ~15 MB native .so) can be removed from the dependency tree.
class Hand {
  final List<Landmark> landmarks;
  Hand(this.landmarks);
}

class Landmark {
  final double x;
  final double y;
  final double z;
  Landmark(this.x, this.y, this.z);
}
