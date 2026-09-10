#!/usr/bin/env python3
"""Run the actual player scroll assignments with pending/failed/ready content."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Classes/PlayerInfoViewController_v5.m').read_text()
assignments = re.findall(r'self\.tableView\.scrollEnabled\s*=\s*([^;]+);', source)
assert len(assignments) == 2, 'Exercise both initial and updated header layout'
program = '''#import <Foundation/Foundation.h>
int main(void) {
 int failures = 0;
 for (int state = 0; state < 3; state++) {
  BOOL hasContent = state == 2;
  BOOL scrollEnabled;
  ASSIGNMENTS
 }
 return failures ? 1 : 0;
}
'''.replace('ASSIGNMENTS', '\n'.join(
    f'scrollEnabled = {expression}; printf("layout {n}, state %d: %s\\n", state, scrollEnabled ? "PASS" : "FAIL"); failures += !scrollEnabled;'
    for n, expression in enumerate(assignments)))
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path/'main.m').write_text(program)
    subprocess.run(['xcrun','clang','-framework','Foundation',str(path/'main.m'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
