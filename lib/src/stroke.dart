import 'contour.dart';

/// The area a stroke of [width] covers along [line], as loops an even-odd fill
/// paints exactly.
///
/// A stroke is drawn, measured and clipped like any other paint, so the parts
/// of this package that ask "what is on screen here" have to be able to answer
/// for one. A closed outline gives a ring - the outline pushed out and pulled
/// in, which even-odd fills as the band between them - and an open one, which
/// is what a trim leaves behind, gives a single loop that runs out along one
/// side and back along the other.
///
/// The ends are square rather than round. A cap is half a stroke width across
/// at the two ends of a line that is usually hundreds of times longer, and
/// squaring it keeps this exact where it matters: along the length.
List<List<Point>> strokeBands(List<Point> line, double width, {required bool closed}) {
  final half = width / 2;
  // A trim collapses the parts of the path it cuts away to a point rather than
  // dropping them, so the outline keeps its commands and can still morph. Those
  // points are not on the line any more, and a band drawn through them would
  // run back across the artwork.
  final live = <Point>[];
  for (final point in line) {
    if (live.isEmpty || (point - live.last).length > 1e-6) live.add(point);
  }
  if (closed && live.length > 1 && (live.first - live.last).length <= 1e-6) live.removeLast();
  if (live.length < 2 || half <= 0) return const [];
  if (closed) {
    return [_offset(live, half, closed: true), _offset(live, -half, closed: true)];
  }
  return [
    [..._offset(live, half, closed: false), ..._offset(live, -half, closed: false).reversed],
  ];
}

/// [line] moved [distance] along its own normal, point for point.
List<Point> _offset(List<Point> line, double distance, {required bool closed}) {
  final out = <Point>[];
  for (var i = 0; i < line.length; i++) {
    // The normal of a vertex is the normal of the run through its neighbours,
    // which is the bisector at a corner and the perpendicular on a straight.
    final before = closed ? line[(i - 1) % line.length] : line[i == 0 ? 0 : i - 1];
    final after = closed ? line[(i + 1) % line.length] : line[i == line.length - 1 ? i : i + 1];
    final run = after - before;
    final length = run.length;
    out.add(length == 0 ? line[i] : line[i] + Point(run.y / length, -run.x / length) * distance);
  }
  return out;
}
