import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsync/screens/common.dart';
import 'package:shelfsync/screens/reader_parts.dart';

void main() {
  test('chapters are the level under a single top entry', () {
    final outline = Outline(const [
      OutlineEntry('C Programming (Second Edition)', 1, 0),
      OutlineEntry('1 Introducing C', 20, 1),
      OutlineEntry('1.1 History of C', 21, 2),
      OutlineEntry('3 Formatted Input/Output', 60, 1),
      OutlineEntry('9 Functions', 200, 1),
    ]);
    expect(outline.chapters.map((c) => c.title), ['1 Introducing C', '3 Formatted Input/Output', '9 Functions']);
    expect(outline.chapterAt(77)?.title, '3 Formatted Input/Output');
    expect(outline.nextChapterPage(77), 200);
  });

  test('several top entries stay the chapters', () {
    final outline = Outline(const [
      OutlineEntry('Preface', 1, 0),
      OutlineEntry('1 Basics', 5, 0),
      OutlineEntry('1.1 Start', 6, 1),
    ]);
    expect(outline.chapters.map((c) => c.title), ['Preface', '1 Basics']);
  });

  test('chapter lines', () {
    expect(chapterLine('9 Functions'), 'Chapter 9 · Functions');
    expect(chapterLine('9 Functions', short: true), '9 · Functions');
    expect(chapterLine('Preface'), 'Preface');
    expect(chapterLine('3 FORMATTED INPUT/OUTPUT'), 'Chapter 3 · Formatted Input/Output');
    expect(chapterLine('THE ART OF C'), 'The Art of C');
  });
}
