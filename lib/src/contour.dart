import 'dart:math' as math;
import 'dart:typed_data';

/// A closed polyline in continuous image coordinates, where pixel `i` covers
/// `[i, i + 1)`.
typedef Loop = List<Point>;

class Point {
  const Point(this.x, this.y);

  final double x;
  final double y;

  Point operator +(Point o) => Point(x + o.x, y + o.y);
  Point operator -(Point o) => Point(x - o.x, y - o.y);
  Point operator *(double k) => Point(x * k, y * k);

  double get length => math.sqrt(x * x + y * y);
}

/// A filled region: one outer loop plus the loops that punch holes in it.
class Shape {
  Shape(this.outer, this.holes);

  final Loop outer;
  final List<Loop> holes;

  Point get centroid => _centroid(outer);
  double get area => signedArea(outer).abs();
  double get perimeter => _perimeter(outer);
}

/// Extracts the 0.5-coverage contours of [field] with sub-pixel accuracy
/// (marching squares), then nests them into filled shapes.
List<Shape> trace(Float32List field, int w, int h, {double level = 0.5}) {
  final segments = <double>[]; // flat x0,y0,x1,y1
  // One implicit ring of background keeps shapes that touch the GIF edge closed.
  double at(int x, int y) => (x < 0 || y < 0 || x >= w || y >= h) ? 0.0 : field[y * w + x];
  Point cut(double xa, double ya, double xb, double yb, double va, double vb) {
    final t = (level - va) / (vb - va);
    return Point(xa + t * (xb - xa) + 0.5, ya + t * (yb - ya) + 0.5);
  }

  for (var y = -1; y < h; y++) {
    for (var x = -1; x < w; x++) {
      final a = at(x, y), b = at(x + 1, y), c = at(x + 1, y + 1), d = at(x, y + 1);
      final code =
          (a > level ? 1 : 0) | (b > level ? 2 : 0) | (c > level ? 4 : 0) | (d > level ? 8 : 0);
      if (code == 0 || code == 15) continue;
      final dx = x.toDouble(), dy = y.toDouble();
      Point top() => cut(dx, dy, dx + 1, dy, a, b);
      Point right() => cut(dx + 1, dy, dx + 1, dy + 1, b, c);
      Point bottom() => cut(dx, dy + 1, dx + 1, dy + 1, d, c);
      Point left() => cut(dx, dy, dx, dy + 1, a, d);
      void add(Point p, Point q) => segments.addAll([p.x, p.y, q.x, q.y]);
      switch (code) {
        case 1:
          add(left(), top());
        case 2:
          add(top(), right());
        case 3:
          add(left(), right());
        case 4:
          add(right(), bottom());
        case 5:
          add(left(), top());
          add(right(), bottom());
        case 6:
          add(top(), bottom());
        case 7:
          add(left(), bottom());
        case 8:
          add(bottom(), left());
        case 9:
          add(bottom(), top());
        case 10:
          add(top(), right());
          add(bottom(), left());
        case 11:
          add(bottom(), right());
        case 12:
          add(right(), left());
        case 13:
          add(right(), top());
        case 14:
          add(top(), left());
      }
    }
  }

  final count = segments.length ~/ 4;
  final heads = <int, int>{};
  int key(double x, double y) => (x * 1e6).round() * 0x2000000 + (y * 1e6).round();
  for (var i = 0; i < count; i++) {
    heads[key(segments[i * 4], segments[i * 4 + 1])] = i;
  }

  final used = Uint8List(count);
  final loops = <Loop>[];
  for (var i = 0; i < count; i++) {
    if (used[i] != 0) continue;
    final loop = <Point>[Point(segments[i * 4], segments[i * 4 + 1])];
    var current = i;
    while (used[current] == 0) {
      used[current] = 1;
      final x = segments[current * 4 + 2], y = segments[current * 4 + 3];
      final next = heads[key(x, y)];
      if (next == null || used[next] != 0) break;
      loop.add(Point(x, y));
      current = next;
    }
    if (loop.length > 5) loops.add(loop);
  }

  // Nest by containment: even depth is a filled outline, odd depth a hole.
  loops.sort((a, b) => signedArea(b).abs().compareTo(signedArea(a).abs()));
  final parent = List<int>.filled(loops.length, -1);
  final depth = List<int>.filled(loops.length, 0);
  for (var i = 0; i < loops.length; i++) {
    for (var j = i - 1; j >= 0; j--) {
      if (contains(loops[j], loops[i][0])) {
        parent[i] = j;
        depth[i] = depth[j] + 1;
        break;
      }
    }
  }
  final shapes = <Shape>[];
  final index = <int, int>{};
  for (var i = 0; i < loops.length; i++) {
    if (depth[i].isEven) {
      index[i] = shapes.length;
      shapes.add(Shape(loops[i], []));
    }
  }
  for (var i = 0; i < loops.length; i++) {
    if (depth[i].isOdd) shapes[index[parent[i]]!].holes.add(loops[i]);
  }
  return shapes;
}

double signedArea(Loop loop) {
  var sum = 0.0;
  for (var i = 0; i < loop.length; i++) {
    final p = loop[i], q = loop[(i + 1) % loop.length];
    sum += p.x * q.y - q.x * p.y;
  }
  return sum / 2;
}

bool contains(Loop loop, Point p) {
  var inside = false;
  for (var i = 0; i < loop.length; i++) {
    final a = loop[i], b = loop[(i + 1) % loop.length];
    if ((a.y > p.y) != (b.y > p.y) && p.x < a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)) {
      inside = !inside;
    }
  }
  return inside;
}

Point _centroid(Loop loop) {
  var x = 0.0, y = 0.0, a = 0.0;
  for (var i = 0; i < loop.length; i++) {
    final p = loop[i], q = loop[(i + 1) % loop.length];
    final cross = p.x * q.y - q.x * p.y;
    a += cross;
    x += (p.x + q.x) * cross;
    y += (p.y + q.y) * cross;
  }
  if (a.abs() < 1e-9) {
    for (final p in loop) {
      x += p.x;
      y += p.y;
    }
    return Point(x / loop.length, y / loop.length);
  }
  return Point(x / (3 * a), y / (3 * a));
}

double _perimeter(Loop loop) {
  var sum = 0.0;
  for (var i = 0; i < loop.length; i++) {
    sum += (loop[(i + 1) % loop.length] - loop[i]).length;
  }
  return sum;
}
