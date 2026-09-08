// Dev-only: dump the `image` package's decoded RGB bytes so they can be
// diffed against the OpenCV reference decoder. Not shipped in the app.
//
// usage: dart run native/bench/decode_dump.dart <outDir> <img>...
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final outDir = Directory(args.first)..createSync(recursive: true);
  for (final path in args.skip(1)) {
    final im = img.decodeImage(File(path).readAsBytesSync());
    if (im == null) {
      stderr.writeln('decode failed: $path');
      continue;
    }
    final out = Uint8List(im.width * im.height * 3);
    var i = 0;
    for (var y = 0; y < im.height; y++) {
      for (var x = 0; x < im.width; x++) {
        final p = im.getPixel(x, y);
        out[i++] = p.r.toInt();
        out[i++] = p.g.toInt();
        out[i++] = p.b.toInt();
      }
    }
    final name = path.split(Platform.pathSeparator).last.split('/').last;
    final dst = '${outDir.path}/$name.${im.width}x${im.height}.rgb';
    File(dst).writeAsBytesSync(out);
    stdout.writeln('$path ${im.width}x${im.height} -> $dst');
  }
}
