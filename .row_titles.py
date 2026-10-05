"""Print the title of every clickable settings row, top to bottom."""
import re
import sys

rows = []
for tag in re.findall(r"<node[^>]*>", open(sys.argv[1]).read()):
    if 'clickable="true"' not in tag:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if b:
        rows.append((int(b.group(1)), int(b.group(2)), int(b.group(3)), int(b.group(4))))

texts = []
for tag in re.findall(r"<node[^>]*>", open(sys.argv[1]).read()):
    t = re.search(r'\btext="([^"]+)"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if t and b:
        texts.append((int(b.group(2)), int(b.group(4)), t.group(1)))

for x1, y1, x2, y2 in rows:
    inside = sorted((ty1, n) for ty1, ty2, n in texts if y1 - 6 <= ty1 and ty2 <= y2 + 6)
    if inside:
        print(inside[0][1])
