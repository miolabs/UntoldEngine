#!/usr/bin/env python3
"""Resolve the conflict blocks of a file by a policy per block: ours, theirs, both (ours first)."""
import sys
path, policies = sys.argv[1], sys.argv[2].split(',')
lines = open(path).read().split('\n')
out, i, n = [], 0, 0
while i < len(lines):
    if lines[i].startswith('<<<<<<< '):
        ours, theirs, i = [], [], i + 1
        while not lines[i].startswith('======='):
            ours.append(lines[i]); i += 1
        i += 1
        while not lines[i].startswith('>>>>>>> '):
            theirs.append(lines[i]); i += 1
        i += 1
        policy = policies[n] if n < len(policies) else policies[-1]
        n += 1
        out.extend({'ours': ours, 'theirs': theirs, 'both': ours + theirs, 'theirs-ours': theirs + ours}[policy])
    else:
        out.append(lines[i]); i += 1
open(path, 'w').write('\n'.join(out))
print(f"{path}: {n} blocks resolved with {policies}")
