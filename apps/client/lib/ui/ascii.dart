import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'land.dart';
import 'theme.dart';

const _ramp = ' .:-=+*#%@';
const _charAspect = 0.6;
const _tilt = 0.38;

final Float32List _points = () {
  final out = Float32List(landPoints.length ~/ 2 * 3);
  for (var i = 0, k = 0; i < landPoints.length; i += 2, k += 3) {
    final a = landPoints[i] * math.pi / 180, o = landPoints[i + 1] * math.pi / 180;
    out[k] = math.cos(a) * math.cos(o);
    out[k + 1] = math.sin(a);
    out[k + 2] = math.cos(a) * math.sin(o);
  }
  return out;
}();

enum GlobeMode { idle, working, active }

/// Глобус из символов, тот же, что на сайте. Показывает состояние подключения:
/// тусклый — выключено, бегущая волна — подключение, яркий с пульсом — работает.
class AsciiGlobe extends StatefulWidget {
  const AsciiGlobe({super.key, required this.mode, this.cols = 50});
  final GlobeMode mode;
  final int cols;

  @override
  State<AsciiGlobe> createState() => _AsciiGlobeState();
}

class _AsciiGlobeState extends State<AsciiGlobe> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _time = ValueNotifier<double>(0);
  Duration _last = Duration.zero;
  double _rotation = 0;
  double _level = 0.4;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration now) {
    // 15 кадров в секунду достаточно для символов и почти не тратит батарею
    if ((now - _last).inMilliseconds < 66) return;
    final dt = (now - _last).inMilliseconds / 1000;
    _last = now;
    final speed = switch (widget.mode) { GlobeMode.idle => 0.08, GlobeMode.working => 0.9, GlobeMode.active => 0.22 };
    final target = switch (widget.mode) { GlobeMode.idle => 0.42, GlobeMode.working => 0.7, GlobeMode.active => 1.0 };
    _rotation += dt * speed;
    _level += (target - _level) * math.min(1, dt * 4);
    _time.value = now.inMilliseconds / 1000;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.of(context).disableAnimations;
    if (still && _ticker.isActive) _ticker.stop();
    return RepaintBoundary(
      child: CustomPaint(
        painter: _GlobePainter(this, context.c.text, repaint: _time),
        size: Size.infinite,
      ),
    );
  }
}

class _GlobePainter extends CustomPainter {
  _GlobePainter(this.state, this.color, {super.repaint});
  final _AsciiGlobeState state;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final cols = state.widget.cols;
    final cell = size.width / cols / _charAspect;
    final rows = (size.height / cell).floor();
    if (rows < 4 || cell <= 0) return;
    final buf = Float32List(cols * rows);
    final t = state._time.value, level = state._level, mode = state.widget.mode;
    // запас по краям под кольцо пульса
    final cx = cols / 2, cy = rows / 2, radius = rows * 0.4;

    void put(double c, double r, double v) {
      final ic = c.round(), ir = r.round();
      if (ic < 0 || ir < 0 || ic >= cols || ir >= rows) return;
      final i = ir * cols + ic;
      if (v > buf[i]) buf[i] = v;
    }

    // редкие точки океана, чтобы диск читался как шар
    for (var r = 0; r < rows; r += 2) {
      for (var c = r % 4 != 0 ? 2 : 0; c < cols; c += 4) {
        final dx = (c - cx) * _charAspect, dy = r - cy;
        if (math.sqrt(dx * dx + dy * dy) < radius) put(c.toDouble(), r.toDouble(), 0.12);
      }
    }
    for (var a = 0.0; a < math.pi * 2; a += 0.012) {
      put(cx + math.cos(a) * radius / _charAspect, cy + math.sin(a) * radius, 0.32);
    }
    final sr = math.sin(state._rotation), cr = math.cos(state._rotation), st = math.sin(_tilt), ct = math.cos(_tilt);
    for (var k = 0; k < _points.length; k += 3) {
      final x = _points[k], y = _points[k + 1], z = _points[k + 2];
      final x1 = x * cr + z * sr, z1 = -x * sr + z * cr;
      final y2 = y * ct - z1 * st, z2 = y * st + z1 * ct;
      if (z2 <= 0) continue;
      var v = 0.25 + 0.75 * z2;
      if (mode == GlobeMode.working) {
        // волна проходит по шару сверху вниз
        final phase = (t * 0.9) % 1.4 - 0.2;
        final d = ((1 - y2) / 2 - phase).abs();
        v = v * 0.55 + 0.6 * math.exp(-d * d * 60);
      }
      put(cx + x1 * radius / _charAspect, cy - y2 * radius, v);
    }
    if (mode == GlobeMode.active) {
      // пульс расходится от шара наружу
      final p = (t * 0.35) % 1;
      final ring = radius * (1.02 + p * 0.2);
      for (var a = 0.0; a < math.pi * 2; a += 0.02) {
        put(cx + math.cos(a) * ring / _charAspect, cy + math.sin(a) * ring, 0.45 * (1 - p));
      }
    }

    final style = TextStyle(fontFamily: monoFont, fontSize: cell, height: 1, fontWeight: FontWeight.w600, color: color.withValues(alpha: level.clamp(0, 1)));
    final codes = Uint16List(cols);
    for (var r = 0; r < rows; r++) {
      var any = false;
      for (var c = 0; c < cols; c++) {
        final b = buf[r * cols + c];
        var ch = 0x20;
        if (b >= 0.04) {
          final grain = ((c * 12.9898 + r * 78.233) % 1) * 0.1;
          final idx = math.min(_ramp.length - 1, ((b + grain) * _ramp.length).floor());
          ch = _ramp.codeUnitAt(idx);
          if (ch != 0x20) any = true;
        }
        codes[c] = ch;
      }
      if (!any) continue;
      final tp = TextPainter(text: TextSpan(text: String.fromCharCodes(codes), style: style), textDirection: TextDirection.ltr, maxLines: 1)..layout();
      tp.paint(canvas, Offset((size.width - tp.width) / 2, r * cell + (size.height - rows * cell) / 2));
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(_GlobePainter old) => old.color != color;
}
