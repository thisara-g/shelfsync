import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsync/sync/signed_in_page.dart';

void main() {
  test('the page after Google sign-in says what happens next', () {
    expect(signedInPage, startsWith('<!DOCTYPE html>'));
    for (final text in [
      'You’re signed in',
      'What happens next',
      'Sign in on your other devices with the same Google account',
      'ShelfSync only sees the files it creates',
      'https://thisara-g.github.io/shelfsync/privacy.html',
    ]) {
      expect(signedInPage, contains(text));
    }
  });
}
