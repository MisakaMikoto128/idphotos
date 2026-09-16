import struct

files = [
    '1979d869c783fcc849d4e05b81eb809e.png',
    '4e84ef7b8a910c776acd0eebb8293ee9.png',
    'e9168d2cfe9045d07fac74e68419d211.png',
]
base = 'C:/Users/liuyu/Pictures/'
for f in files:
    with open(base + f, 'rb') as fh:
        d = fh.read(33)
    if d[:8] == b'\x89PNG\r\n\x1a\n':
        w, h = struct.unpack('>II', d[16:24])
        bd, ct = d[24], d[25]
        print(f, w, 'x', h, 'bitdepth', bd, 'colortype', ct,
              'rgba_bytes %.1f MB' % (w * h * 4 / 1e6))
    else:
        print(f, 'not png', d[:8])
