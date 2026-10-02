import 'package:flutter_test/flutter_test.dart';
import 'package:sidekick/platform/gallery.dart';

void main() {
  test('photos and videos go to the gallery, other files stay', () {
    expect(Gallery.kindOf('/r/IMG_2041.HEIC'), 'photo');
    expect(Gallery.kindOf('/r/shot.jpeg'), 'photo');
    expect(Gallery.kindOf('/r/Trip.MOV'), 'video');
    expect(Gallery.kindOf('/r/clip.mp4'), 'video');
    expect(Gallery.kindOf('/r/notes.pdf'), isNull);
    expect(Gallery.kindOf('/r/archive.zip'), isNull);
    expect(Gallery.kindOf('/r/logo.svg'), isNull);
    // iPhone Photos can't play WebM; Android's gallery can.
    expect(Gallery.kindOf('/r/screen.webm'), isNull);
    expect(Gallery.kindOf('/r/screen.webm', android: true), 'video');
  });
}
