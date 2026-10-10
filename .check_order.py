import sys
expected = sys.argv[2].split('|')
seen, out = set(), []
for line in open(sys.argv[1]):
    t = line.strip()
    if t and t not in seen:
        seen.add(t)
        out.append(t)
kept = [e for e in expected if e in seen]
index = {e: i for i, e in enumerate(out)}
positions = [index[e] for e in kept if e in index]
ok = positions == sorted(positions) and len(kept) >= len(expected) - 1
print("OK" if ok else "BAD")
