#!/usr/bin/env python3
"""粗略语法自检：剥离 Swift 注释/字符串后检查括号是否配平。

不能替代编译器，但能在没有 Mac 的环境下抓出「括号/字符串没闭合」这类低级错误。
用法：python tools/check_swift_balance.py [目录...]
"""
import sys
import pathlib


def scan(text: str):
    """返回 (括号栈错误, 是否停在字符串里, 是否停在注释里)"""
    stack = []
    i = 0
    n = len(text)
    line = 1
    pairs = {")": "(", "]": "[", "}": "{"}
    errors = []

    while i < n:
        ch = text[i]

        if ch == "\n":
            line += 1
            i += 1
            continue

        # 行注释
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j == -1 else j
            continue

        # 块注释（Swift 支持嵌套）
        if text.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth += 1
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    if text[i] == "\n":
                        line += 1
                    i += 1
            if depth:
                errors.append((line, "块注释未闭合"))
            continue

        # 多行字符串 """
        if text.startswith('"""', i):
            i += 3
            while i < n and not text.startswith('"""', i):
                if text[i] == "\n":
                    line += 1
                # 跳过转义
                if text[i] == "\\":
                    i += 2
                    continue
                i += 1
            if i >= n:
                errors.append((line, "多行字符串未闭合"))
                break
            i += 3
            continue

        # 单行字符串（含插值里的括号，按普通字符处理会导致误判，这里直接跳过整个字符串）
        if ch == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == "\n":
                    errors.append((line, "字符串未闭合"))
                    break
                i += 1
            i += 1
            continue

        if ch in "([{":
            stack.append((ch, line))
            i += 1
            continue

        if ch in ")]}":
            if not stack:
                errors.append((line, f"多余的 {ch}"))
            elif stack[-1][0] != pairs[ch]:
                errors.append((line, f"{ch} 与第 {stack[-1][1]} 行的 {stack[-1][0]} 不匹配"))
                stack.pop()
            else:
                stack.pop()
            i += 1
            continue

        i += 1

    for ch, ln in stack:
        errors.append((ln, f"{ch} 未闭合"))
    return errors


def main() -> int:
    roots = sys.argv[1:] or ["."]
    files = []
    for root in roots:
        p = pathlib.Path(root)
        if p.is_file() and p.suffix == ".swift":
            files.append(p)
        else:
            files.extend(p.rglob("*.swift"))

    failed = 0
    for f in sorted(set(files)):
        text = f.read_text(encoding="utf-8", errors="replace")
        errors = scan(text)
        if errors:
            failed += 1
            print(f"[FAIL] {f}")
            for line, msg in errors[:10]:
                print(f"    line {line}: {msg}")

    print(f"checked {len(set(files))} files, {failed} with problems")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
