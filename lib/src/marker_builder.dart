import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A utility class for generating custom map markers from Flutter widgets.
///
/// The core idea is to render a widget inside an off-screen [OverlayEntry],
/// capture that widget from a [RepaintBoundary], and then convert the PNG bytes
/// into a [BitmapDescriptor].
///
/// Why this approach:
/// - Google Maps marker APIs need image bytes, not Flutter widgets.
/// - Rendering via a hidden overlay ensures the widget gets a real layout/paint
///   pass (which a detached widget tree cannot provide reliably).
/// - Waiting for end-of-frame + `debugNeedsPaint == false` is more robust than a
///   fixed `Future.delayed`, because real devices vary in frame timing.
class CustomMapMarkerBuilder {
  CustomMapMarkerBuilder._();

  /// In-memory cache for already-rendered markers.
  ///
  /// Why static:
  /// - Marker generation is often called from many places (map rebuilds,
  ///   clustering updates, etc.).
  /// - A process-wide cache avoids redundant expensive rasterization work.
  static final Map<String, BitmapDescriptor> _descriptorCache =
      <String, BitmapDescriptor>{};

  /// Tracks in-flight rendering jobs keyed by [cacheKey].
  ///
  /// Why this exists:
  /// - Without dedupe, concurrent calls with the same key would create multiple
  ///   overlays and duplicate GPU/CPU work.
  /// - With this map, the first call does the work and others await the same
  ///   [Future].
  static final Map<String, Future<BitmapDescriptor>> _inflightRenders =
      <String, Future<BitmapDescriptor>>{};

  /// Converts a Flutter widget into a [BitmapDescriptor] for Google Maps.
  ///
  /// Important behavior:
  /// - Renders fully off-screen so users never see the intermediate widget.
  /// - Waits frame-by-frame until paint is complete (or timeout is reached).
  /// - Cleans up overlay via `try/finally` to avoid leaked overlay entries.
  /// - Supports optional caching + in-flight dedupe through [cacheKey].
  ///
  /// [size] makes layout deterministic. Marker widgets often rely on incoming
  /// constraints; using a fixed [SizedBox] prevents surprising dimensions.
  ///
  /// [pixelRatio] defaults to the device DPR to balance quality and memory.
  /// Passing a higher value can improve sharpness, but increases memory and
  /// rasterization time.
  ///
  /// [timeout] prevents indefinite waiting if rendering never stabilizes.
  static Future<BitmapDescriptor> fromWidget({
    required BuildContext context,
    required Widget marker,
    Size size = const Size(96, 96),
    double? pixelRatio,
    Duration timeout = const Duration(seconds: 2),
    String? cacheKey,
  }) {
    if (cacheKey == null) {
      return _renderDescriptor(
        context: context,
        marker: marker,
        size: size,
        pixelRatio: pixelRatio,
        timeout: timeout,
      );
    }

    final cached = _descriptorCache[cacheKey];
    if (cached != null) {
      return Future<BitmapDescriptor>.value(cached);
    }

    final inFlight = _inflightRenders[cacheKey];
    if (inFlight != null) {
      return inFlight;
    }

    final renderFuture = _renderDescriptor(
      context: context,
      marker: marker,
      size: size,
      pixelRatio: pixelRatio,
      timeout: timeout,
    );

    _inflightRenders[cacheKey] = renderFuture;

    return renderFuture.then((descriptor) {
      _descriptorCache[cacheKey] = descriptor;
      return descriptor;
    }).whenComplete(() {
      _inflightRenders.remove(cacheKey);
    });
  }

  static Future<BitmapDescriptor> _renderDescriptor({
    required BuildContext context,
    required Widget marker,
    required Size size,
    required double? pixelRatio,
    required Duration timeout,
  }) async {
    final overlayState = Overlay.of(context, rootOverlay: true);
    if (overlayState == null) {
      throw StateError(
        'No Overlay found for the provided context. '
        'Ensure the context belongs to a mounted widget under MaterialApp/CupertinoApp/Navigator.',
      );
    }

    // Fall back chain for DPR:
    // 1) explicit method parameter
    // 2) MediaQuery from current context (common runtime case)
    // 3) engine-level view DPR (defensive fallback)
    final effectivePixelRatio = pixelRatio ??
        MediaQuery.maybeOf(context)?.devicePixelRatio ??
        ui.PlatformDispatcher.instance.views.first.devicePixelRatio;

    final repaintBoundaryKey = GlobalKey();

    // Positioned far outside the viewport to ensure rendering is truly
    // off-screen and never visible. We also wrap with IgnorePointer so this
    // temporary entry can never steal gestures/focus.
    final overlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: -10000,
        top: -10000,
        child: IgnorePointer(
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: RepaintBoundary(
                key: repaintBoundaryKey,
                child: marker,
              ),
            ),
          ),
        ),
      ),
    );

    overlayState.insert(overlayEntry);

    try {
      final boundary = await _waitForPaintedBoundary(
        repaintBoundaryKey: repaintBoundaryKey,
        timeout: timeout,
      );

      final image = await boundary.toImage(pixelRatio: effectivePixelRatio);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

      if (byteData == null) {
        throw StateError(
          'Failed to encode marker image as PNG bytes (ByteData was null).',
        );
      }

      return BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
    } finally {
      // `finally` is crucial: even when rendering throws (timeout, cast error,
      // encoding error), the temporary overlay entry is always removed.
      // This prevents invisible leaked entries accumulating over time.
      overlayEntry.remove();
    }
  }

  static Future<RenderRepaintBoundary> _waitForPaintedBoundary({
    required GlobalKey repaintBoundaryKey,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);

    while (true) {
      // Why `endOfFrame`:
      // - Guarantees build/layout/paint pipeline finished for the current frame.
      // - More deterministic than fixed delays across slow/fast devices.
      await WidgetsBinding.instance.endOfFrame;

      final boundaryContext = repaintBoundaryKey.currentContext;
      if (boundaryContext == null) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException(
            'Timed out while waiting for marker boundary context to become available.',
            timeout,
          );
        }
        continue;
      }

      final renderObject = boundaryContext.findRenderObject();
      if (renderObject == null) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException(
            'Timed out while waiting for marker render object to be attached.',
            timeout,
          );
        }
        continue;
      }

      if (renderObject is! RenderRepaintBoundary) {
        throw StateError(
          'Expected a RenderRepaintBoundary but found ${renderObject.runtimeType}. '
          'Ensure the marker is wrapped in RepaintBoundary.',
        );
      }

      if (!renderObject.debugNeedsPaint) {
        return renderObject;
      }

      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'Timed out while waiting for marker widget to finish painting.',
          timeout,
        );
      }
    }
  }
}
