import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium_bindings;
import 'package:pdfrx/pdfrx.dart';

/// Finds where the raster images are on each page, so dark mode can invert
/// text and background but leave pictures as they are.
///
/// Uses PDFium directly through pdfrx's [PdfDocument.useNativeDocumentHandle],
/// which pauses pdfrx's own PDFium worker while we run. Pages are scanned
/// lazily as they're painted and the results cached.
class PageImageRegions {
  PageImageRegions(this.document, {required this.onLoaded});

  final PdfDocument document;

  /// Called after a page's regions become available, so the viewer can repaint.
  final void Function() onLoaded;

  static final _pdfium = pdfium_bindings.getPdfium(modulePath: Pdfrx.pdfiumModulePath);

  final Map<int, List<PdfRect>> _cache = {};
  final Set<int> _queued = {};
  bool _running = false;
  bool _disposed = false;

  /// Image rectangles for [pageNumber] in PDF page coordinates, or null if the
  /// page hasn't been scanned yet (a scan is then scheduled).
  List<PdfRect>? regionsFor(int pageNumber) {
    final cached = _cache[pageNumber];
    if (cached != null) return cached;
    if (_queued.add(pageNumber)) _drain();
    return null;
  }

  void dispose() => _disposed = true;

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_queued.isNotEmpty && !_disposed) {
        // Scan a few pages per call so the UI isolate is never blocked for long.
        final batch = _queued.take(4).toList();
        final results = await document.useNativeDocumentHandle((handle) {
          final doc = pdfium_bindings.FPDF_DOCUMENT.fromAddress(handle);
          return {for (final n in batch) n: _scanPage(doc, n)};
        });
        _queued.removeAll(batch);
        _cache.addAll(results);
        if (!_disposed) onLoaded();
      }
    } catch (_) {
      // Document disposed or not a PDFium backend: dark mode just inverts everything.
    } finally {
      _running = false;
    }
  }

  static List<PdfRect> _scanPage(pdfium_bindings.FPDF_DOCUMENT doc, int pageNumber) {
    final page = _pdfium.FPDF_LoadPage(doc, pageNumber - 1);
    if (page == nullptr) return const [];
    return using((arena) {
      try {
        // pdfrx's page coordinates are relative to the page's bounding box.
        final box = arena<pdfium_bindings.FS_RECTF>();
        _pdfium.FPDF_GetPageBoundingBox(page, box);
        final originX = box.ref.left, originY = box.ref.bottom;

        final l = arena<Float>(), b = arena<Float>(), r = arena<Float>(), t = arena<Float>();
        final regions = <PdfRect>[];
        final count = _pdfium.FPDFPage_CountObjects(page);
        for (var i = 0; i < count; i++) {
          final obj = _pdfium.FPDFPage_GetObject(page, i);
          final type = _pdfium.FPDFPageObj_GetType(obj);
          // Images, plus form XObjects that contain images (common in scanned
          // and exported PDFs). Bounds of a form object are already in page space.
          if (type == pdfium_bindings.FPDF_PAGEOBJ_IMAGE ||
              (type == pdfium_bindings.FPDF_PAGEOBJ_FORM && _formHasImage(obj))) {
            if (_pdfium.FPDFPageObj_GetBounds(obj, l, b, r, t) != 0) {
              regions.add(PdfRect(l.value - originX, t.value - originY, r.value - originX, b.value - originY));
            }
          }
        }
        return _dropFullPageImages(regions, box.ref);
      } finally {
        _pdfium.FPDF_ClosePage(page);
      }
    });
  }

  static bool _formHasImage(pdfium_bindings.FPDF_PAGEOBJECT form, [int depth = 0]) {
    if (depth > 4) return false;
    final count = _pdfium.FPDFFormObj_CountObjects(form);
    for (var i = 0; i < count; i++) {
      final child = _pdfium.FPDFFormObj_GetObject(form, i);
      final type = _pdfium.FPDFPageObj_GetType(child);
      if (type == pdfium_bindings.FPDF_PAGEOBJ_IMAGE) return true;
      if (type == pdfium_bindings.FPDF_PAGEOBJ_FORM && _formHasImage(child, depth + 1)) return true;
    }
    return false;
  }

  /// A scanned book is one big image per page; excluding it would disable dark
  /// mode entirely, so images covering most of the page are inverted instead.
  static List<PdfRect> _dropFullPageImages(List<PdfRect> regions, pdfium_bindings.FS_RECTF box) {
    final pageArea = (box.right - box.left) * (box.top - box.bottom);
    if (pageArea <= 0) return regions;
    return [
      for (final r in regions)
        if ((r.right - r.left) * (r.top - r.bottom) < pageArea * 0.8) r,
    ];
  }
}
