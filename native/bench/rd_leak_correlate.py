import json

# real-device leak rounds + churn samples -> per-round peak correlation
rounds = []
with open('C:/Users/liuyu/Desktop/WorkPlace/idPhotos/out/rd_leak_items.jsonl',
          encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if line:
            rounds.append(json.loads(line))
samples = json.load(open(
    'C:/Users/liuyu/Desktop/WorkPlace/idPhotos/out/metrics_r1_realdevice.json',
    encoding='utf-8'))['G4_8_leak']['samples_mb']

# leak rounds on real device may be recorded with shifted clock; use relative
# order: 20 rounds spanning [t0, tN]; churn sample window = [leak_begin, end].
# We don't have marker ts here; instead just print rounds and the sample curve
# peaks with rank.
print('n_rounds', len(rounds))
for r, it in enumerate(rounds):
    name = it['path'].split('\\')[-1][:34]
    print(r, it.get('class'), name, 'load_ms', it.get('load_ms'),
          't', it.get('t'))

vals = [v for t, v in samples]
top = sorted(range(len(vals)), key=lambda i: -vals[i])[:8]
print('\ntop samples:')
for i in top:
    print('  t=%.1f  %.1fMB' % (samples[i][0], samples[i][1]))
