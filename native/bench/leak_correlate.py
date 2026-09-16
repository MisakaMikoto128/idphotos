import json

curve = json.load(open(
    'C:/Users/liuyu/Desktop/WorkPlace/idPhotos/out/leak_r7_mem_curve.json',
    encoding='utf-8'))
leak = json.load(open(
    'C:/Users/liuyu/Desktop/WorkPlace/idPhotos/out/leak_r7.json',
    encoding='utf-8'))
samples = curve['samples']
leaks = leak['rounds']
for r, it in enumerate(leaks):
    t0 = it['t'] / 1000.0
    t1 = (leaks[r + 1]['t'] / 1000.0) if r + 1 < len(leaks) else t0 + 6
    window = [v for t, v in zip([s[0] for s in samples],
                                [s[1] for s in samples])
              if t0 <= t <= t1 and v is not None]
    mx = max(window) if window else None
    name = it['path'].split('\\')[-1][:32]
    print(r, it['class'], name, 'load_ms', it['load_ms'],
          ('peak=%.1fMB' % (mx / 1024)) if mx else '-')
