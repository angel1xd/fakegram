import sys, io

# Accurate-enough Swift bracket scanner: strips comments and strings (recursing into
# interpolations with correct depth) and reports where the paren depth ends nonzero or
# goes negative, so a pre-existing false positive can be told apart from a broken edit.

def scan(src):
    i = 0
    n = len(src)
    depth = 0
    line = 1
    events = []
    while i < n:
        c = src[i]
        if c == '\n':
            line += 1; i += 1; continue
        if c == '/' and i + 1 < n and src[i+1] == '/':
            while i < n and src[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and src[i+1] == '*':
            i += 2
            d = 1
            while i < n and d > 0:
                if src[i] == '\n': line += 1
                if src[i] == '/' and i+1 < n and src[i+1] == '*': d += 1; i += 2
                elif src[i] == '*' and i+1 < n and src[i+1] == '/': d -= 1; i += 2
                else: i += 1
            continue
        if c == '"':
            if src.startswith('"""', i):
                i += 3
                while i < n and not src.startswith('"""', i):
                    if src[i] == '\n': line += 1
                    if src[i] == '\\': i += 1
                    i += 1
                i += 3
                continue
            i += 1
            while i < n and src[i] != '"':
                if src[i] == '\n':
                    break
                if src[i] == '\\' and i + 1 < n and src[i+1] == '(':
                    depth += 1
                    i += 2
                    start = i
                    d = 1
                    while i < n and d > 0:
                        if src[i] == '(':
                            d += 1
                        elif src[i] == ')':
                            d -= 1
                            if d == 0:
                                break
                        i += 1
                    # recurse into interpolation content
                    sub, sub_line, sub_events = scan(src[start:i])
                    events.extend(sub_events)
                    depth -= 1
                    i += 1
                    continue
                i += 1
            i += 1
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth < 0:
                events.append((line, 'negative'))
        i += 1
    return depth, line, events

for path in sys.argv[1:]:
    src = io.open(path, encoding='utf-8').read()
    depth, lines, events = scan(src)
    print(path, 'paren depth at EOF =', depth, 'events =', events[:10])
