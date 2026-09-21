import 'contour.dart';
import 'fit.dart';

/// Rewinds a set of loops so the non-zero rule fills them the way the even-odd
/// rule would: a loop wound against the loop that contains it cancels it.
///
/// This is not a refinement - it is the only way to punch a hole in a
/// `<clip-path>`. Android's `VectorDrawableClipPath` styleable declares `name`
/// and `pathData` and nothing else, so `android:fillType` on a clip is parsed
/// by no one and every clip fills by winding. Under winding, an outer ring and
/// an inner shape turning the same way are a union, and the hole disappears.
///
/// Orientation is decided once for the whole animation, from the votes of every
/// frame, because reversing a loop reverses its path commands: were a frame free
/// to disagree, the morph between two frames would run one loop backwards.
class Winding {
  Winding._(this._reverse);

  /// Decides, per loop index, whether that loop has to be reversed. Every frame
  /// carries the same loops in the same order, so one flag per index holds.
  factory Winding.of(List<List<Curve>> frames) {
    final count = frames.isEmpty ? 0 : frames.first.length;
    final votes = List<int>.filled(count, 0);
    for (final frame in frames) {
      if (frame.length != count) continue;
      final polygons = [for (final loop in frame) flattenLoop(loop)];
      for (var i = 0; i < count; i++) {
        final area = signedArea(polygons[i]);
        if (area.abs() < 1e-9) continue; // a collapsed loop fills nothing either way
        var depth = 0;
        for (var j = 0; j < count; j++) {
          if (j != i && surrounds(polygons[j], polygons[i])) depth++;
        }
        final wanted = depth.isEven ? 1 : -1;
        votes[i] += area * wanted < 0 ? 1 : -1;
      }
    }
    return Winding._([for (final vote in votes) vote > 0]);
  }

  final List<bool> _reverse;

  /// True when this set of loops needs no rewinding at all.
  bool get identity => !_reverse.contains(true);

  List<Curve> apply(List<Curve> loops) {
    if (identity || loops.length != _reverse.length) return loops;
    return [
      for (var i = 0; i < loops.length; i++) _reverse[i] ? reverseLoop(loops[i]) : loops[i],
    ];
  }
}

/// The same outline traced the other way: the segments back to front, each with
/// its control points swapped. The cubic count is untouched, so a reversed loop
/// still morphs against its neighbours.
Curve reverseLoop(Curve loop) {
  final out = <Point>[loop[loop.length - 1]];
  for (var s = (loop.length - 1) ~/ 3 - 1; s >= 0; s--) {
    out.addAll([loop[s * 3 + 2], loop[s * 3 + 1], loop[s * 3]]);
  }
  return out;
}

List<Point> flattenLoop(Curve loop) => loop.length < 4 ? loop : flatten(loop);

/// Whether [outer] encloses [inner]. The question is asked of [inner]'s own
/// vertices rather than of a point in its middle: the middle of a ring is not
/// in the ring, so a point there would count the ring's own hole as a parent
/// and invert it. Three vertices vote, so one landing on a shared edge cannot
/// decide it.
bool surrounds(List<Point> outer, List<Point> inner) {
  if (outer.length < 3 || inner.isEmpty) return false;
  var yes = 0;
  for (var k = 0; k < 3; k++) {
    if (contains(outer, inner[(inner.length * k) ~/ 3])) yes++;
  }
  return yes >= 2;
}

/// [loop] pushed [distance] outwards, away from the area it encloses.
///
/// Every point moves along the normal of the polyline through its neighbours,
/// so the point count - and with it the path's command sequence - is untouched:
/// a clip built from these loops still morphs. The control points move with
/// their anchors, which traces the offset of a curve closely enough at the
/// widths a stroke has, and exactly on the straight segments.
Curve outsetLoop(Curve loop, double distance) {
  if (loop.length < 4 || distance <= 0) return loop;
  // Which way is out: a loop that turns one way encloses what is inside it,
  // and the other way round the same normal points the other way.
  final side = signedArea(flattenLoop(loop)) >= 0 ? 1.0 : -1.0;
  final out = <Point>[];
  for (var i = 0; i < loop.length; i++) {
    // Coincident points - a handle parked on its anchor - carry no direction,
    // so the tangent comes from the nearest neighbours that differ.
    var before = loop[i], after = loop[i];
    for (var step = 1; step < loop.length && before == loop[i]; step++) {
      before = loop[(i - step) % loop.length];
    }
    for (var step = 1; step < loop.length && after == loop[i]; step++) {
      after = loop[(i + step) % loop.length];
    }
    final tangent = after - before;
    final length = tangent.length;
    out.add(length == 0
        ? loop[i]
        : loop[i] + Point(tangent.y / length, -tangent.x / length) * (distance * side));
  }
  return out;
}
