"""Remove top-level Zig test blocks from a frozen test-comparator module."""
import re


def strip_tests(source):
    pattern=re.compile(r'^test(?:\s+"(?:[^"\\]|\\.)*")?\s*\{',re.M)
    while match:=pattern.search(source):
        i=match.end();depth=1;quote=False;escape=False
        while depth:
            if i>=len(source):raise ValueError('Unterminated test block')
            char=source[i]
            if quote:
                if escape:escape=False
                elif char=='\\':escape=True
                elif char=='"':quote=False
            elif source.startswith('//',i):
                end=source.find('\n',i)
                if end<0:raise ValueError('Unterminated test block')
                i=end;continue
            elif char=='"':quote=True
            elif char=='{':depth+=1
            elif char=='}':depth-=1
            i+=1
        source=source[:match.start()]+source[i:]
    return source
