import io, subprocess, sys, os, tempfile

# Known-good and known-bad snippets, to prove which checker is trustworthy on interpolations.
good = 'let a = "\\(x + 1)"\nlet b = foo(bar)\n'
bad = 'let a = "\\(x + 1)"\nlet b = foo(bar\n'

here = os.path.dirname(os.path.abspath(__file__))
gd = os.path.join(here, '_good.swift')
bd = os.path.join(here, '_bad.swift')
io.open(gd, 'w', encoding='utf-8').write(good)
io.open(bd, 'w', encoding='utf-8').write(bad)

for path in (gd, bd):
    print('===', path)
    out = subprocess.run([sys.executable, os.path.join(here, 'balance_check.py'), path], capture_output=True, text=True)
    print('balance_check:', out.stdout.strip())
    out = subprocess.run([sys.executable, os.path.join(here, 'paren_depth.py'), path], capture_output=True, text=True)
    print('paren_depth  :', out.stdout.strip())
