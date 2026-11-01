import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsync/screens/reader_tablet.dart';

void main() {
  testWidgets('dragging near a chapter dot snaps onto the chapter start', (tester) async {
    final changes = <int>[];
    int? ended;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            child: TabletPageSlider(
              page: 1,
              count: 101,
              chapters: const [1, 50],
              document: null,
              sectionAt: (_) => null,
              onChanged: changes.add,
              onChangeEnd: (p) => ended = p,
            ),
          ),
        ),
      ),
    );
    final left = tester.getTopLeft(find.byType(TabletPageSlider));
    // Chapter 50 sits at 49% of 400px = 196px.
    final gesture = await tester.startGesture(left + const Offset(100, 18));
    await gesture.moveTo(left + const Offset(202, 18)); // 6px away: snaps
    await tester.pump();
    expect(changes.last, 50);
    await gesture.moveTo(left + const Offset(220, 18)); // 24px away: free
    await tester.pump();
    expect(changes.last, 56);
    await gesture.moveTo(left + const Offset(191, 18));
    await gesture.up();
    await tester.pump();
    expect(ended, 50);
  });
}
