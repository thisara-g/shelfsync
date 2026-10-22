import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import 'library_store.dart';

/// Renders the first page of each book to a cached PNG thumbnail.
///
/// Renders run one at a time so a large library doesn't open dozens of PDFs at
/// once; repeated requests for the same book share one render.
class CoverRenderer {
  CoverRenderer(this.store);

  final LibraryStore store;
  static const _width = 360;

  // One future per book, kept after completion so rebuilds get the same
  // instance and FutureBuilder doesn't flash back to the placeholder.
  final Map<String, Future<File?>> _covers = {};
  Future<void> _queue = Future.value();

  /// Returns the cover file, rendering it first if needed. Null if the PDF
  /// can't be rendered.
  Future<File?> coverFor(Book book) => _covers.putIfAbsent(book.id, () {
        final file = store.coverFor(book);
        if (file.existsSync()) return Future.value(file);
        final result = _queue.then((_) => _render(book, file));
        _queue = result.then((_) {}, onError: (_) {});
        return result;
      });

  Future<File?> _render(Book book, File out) async {
    await pdfrxFlutterInitialize();
    PdfDocument? document;
    try {
      document = await PdfDocument.openFile(store.fileFor(book).path);
      final page = document.pages.first;
      final height = (_width * page.height / page.width).round();
      final pdfImage = await page.render(
        width: _width,
        height: height,
        fullWidth: _width.toDouble(),
        fullHeight: height.toDouble(),
        backgroundColor: 0xffffffff,
      );
      if (pdfImage == null) return null;
      final image = await pdfImage.createImage();
      pdfImage.dispose();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (png == null) return null;

      await out.parent.create(recursive: true);
      final tmp = File('${out.path}.tmp');
      await tmp.writeAsBytes(png.buffer.asUint8List(), flush: true);
      await tmp.rename(out.path);

      if (book.pageCount == null) {
        await store.updateProgress(book.id, page: book.lastPage, pageCount: document.pages.length);
      }
      return out;
    } catch (_) {
      return null;
    } finally {
      await document?.dispose();
    }
  }
}
