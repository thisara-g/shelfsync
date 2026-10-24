import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsync/screens/reader_parts.dart';

void main() {
  final outline = Outline(const [
    OutlineEntry('1 Introduction', 1, 0),
    OutlineEntry('2 Basics', 10, 0),
    OutlineEntry('2.1 Types', 12, 1),
    OutlineEntry('2.2 Arrays', 18, 1),
    OutlineEntry('3 Functions', 30, 0),
  ]);

  test('finds the chapter and section for a page', () {
    expect(outline.chapterAt(20)?.title, '2 Basics');
    expect(outline.sectionAt(20)?.title, '2.2 Arrays');
    expect(outline.sectionAt(11)?.title, '2 Basics');
    expect(outline.sectionAt(30)?.title, '3 Functions');
  });

  test('next chapter page', () {
    expect(outline.nextChapterPage(12), 30);
    expect(outline.nextChapterPage(30), isNull);
  });

  test('spread rows start with the cover alone, then even pages on the left', () {
    expect(spreadRowStart(1), 1);
    expect(spreadRowStart(2), 2);
    expect(spreadRowStart(3), 2);
    expect(spreadRowStart(4), 4);
  });

  test('frame zoom fits the page, and halves the side bars in full screen', () {
    const page = Rect.fromLTWH(0, 0, 600, 800);
    const view = Size(1600, 900);
    final fit = frameZoom(page, view, 0);
    expect(fit, closeTo(900 / 800, 1e-9)); // height-bound
    final bars = view.width - page.width * fit; // 925 px of black
    final zoomed = frameZoom(page, view, 0, halveBars: true);
    expect(view.width - page.width * zoomed, closeTo(bars / 2, 1e-6));
  });

  test('two facing pages fit side by side', () {
    const pair = Rect.fromLTWH(0, 0, 1220, 800);
    const view = Size(1600, 900);
    final zoom = frameZoom(pair, view, 10);
    expect(pair.width * zoom, lessThanOrEqualTo(1600 - 20 + 1e-9));
    expect(pair.height * zoom, lessThanOrEqualTo(900 - 20 + 1e-9));
  });
}
