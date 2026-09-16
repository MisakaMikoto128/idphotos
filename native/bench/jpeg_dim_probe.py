import struct

files = [
    '1979d869c783fcc849d4e05b81eb809e.png',
    '4e84ef7b8a910c776acd0eebb8293ee9.png',
    'e9168d2cfe9045d07fac74e68419d211.png',
    '1 (2).jpg',
    '2.jpg',
    'a.jpg',
]
base = 'C:/Users/liuyu/Pictures/'
for f in files:
    with open(base + f, 'rb') as fh:
        data = fh.read()
    i = 2
    while i < len(data) - 1:
        if data[i] != 0xFF:
            i += 1
            continue
        m = data[i + 1]
        if m in (0xD8, 0xD9, 0x01) or 0xD0 <= m <= 0xD7:
            i += 2
            continue
        ln = struct.unpack('>H', data[i + 2:i + 4])[0]
        if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):
            prec, h, w, nc = struct.unpack('>BHHB', data[i + 4:i + 10])
            print(f, 'w=%d h=%d prec=%d ncomp=%d  decoded_rgb=%.1f MB' % (
                w, h, prec, nc, w * h * 4 / 1e6))
            break
        i += 2 + ln
