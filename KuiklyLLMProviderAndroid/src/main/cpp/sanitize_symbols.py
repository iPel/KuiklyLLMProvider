#!/usr/bin/env python3
"""把编译机 $HOME 在二进制字符串表里等长替换为中性路径。

CMake POST_BUILD 对「交付的 .so」与「unstripped 符号」各调用一次。等长替换
保证 ELF section / DWARF 偏移不变，符号表仍可正常用于崩溃栈还原。
"""
import os
import pathlib
import sys


def main(paths):
    old = os.path.expanduser("~").encode()
    if len(old) < 2:
        return
    new = b"/" + b"x" * (len(old) - 1)
    for name in paths:
        path = pathlib.Path(name)
        data = path.read_bytes()
        if old not in data:
            continue
        replaced = data.replace(old, new)
        if len(replaced) != len(data):
            raise SystemExit("替换改变了文件长度：" + name)
        path.write_bytes(replaced)


if __name__ == "__main__":
    main(sys.argv[1:])
