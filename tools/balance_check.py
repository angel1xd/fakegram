import sys, io

def strip(src):
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i+1] == '/':
            while i < n and src[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and src[i+1] == '*':
            i += 2
            depth = 1
            while i < n and depth > 0:
                if src[i] == '/' and i+1 < n and src[i+1] == '*':
                    depth += 1; i += 2
                elif src[i] == '*' and i+1 < n and src[i+1] == '/':
                    depth -= 1; i += 2
                else:
                    i += 1
            continue
        if c == '"':
            # multiline?
            if src.startswith('"""', i):
                i += 3
                while i < n and not src.startswith('"""', i):
                    if src[i] == '\\':
                        i += 1
                    i += 1
                i += 3
                continue
            i += 1
            while i < n and src[i] != '"':
                if src[i] == '\\':
                    if i+1 < n and src[i+1] == '(':
                        # interpolation: find matching paren, keep code stripped recursively
                        depth = 1
                        i += 2
                        start = i
                        while i < n:
                            if src[i] == '(':
                                depth += 1
                            elif src[i] == ')':
                                depth -= 1
                                if depth == 0:
                                    break
                            i += 1
                        out.append(strip(src[start:i]))
                        i += 1
                        continue
                    i += 2
                    continue
                if src[i] == '\n':
                    break
                i += 1
            i += 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)

for path in sys.argv[1:]:
    src = io.open(path, encoding='utf-8').read()
    s = strip(src)
    counts = {}
    for ch in '{}()[]':
        counts[ch] = s.count(ch)
    bal = (counts['{'] - counts['}'], counts['('] - counts[')'], counts['['] - counts[']'])
    status = 'OK' if bal == (0,0,0) else 'MISMATCH'
    print(f"{status}  {path}  {{}}={bal[0]} ()={bal[1]} []={bal[2]}")
