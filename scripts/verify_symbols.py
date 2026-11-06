#!/usr/bin/env python3
"""校验发布产物与调试符号是否来自同一次链接。

读取 ELF64 little-endian 的 PT_NOTE / NT_GNU_BUILD_ID，不依赖 NDK 的
llvm-readelf 或其它平台工具。strip 不会改动 PT_NOTE，因此「交付出去的 .so」
与「未 strip 的符号文件」Build ID 相同才可用于崩溃栈还原。

支持直接读 ELF，也支持从 AAR / ZIP / JAR、HAR / tar.gz 中自动找出
libllm_provider.so*（会忽略 libc++_shared.so 等无关库）。

用法：
  verify_symbols.py ARTIFACT SYMBOLS      比对两侧 Build ID，不一致退出 1
  verify_symbols.py --print FILE          列出归档内所有匹配项及 Build ID
  verify_symbols.py --id FILE             只输出唯一的 Build ID（供 shell 使用）
"""
import argparse
import pathlib
import struct
import sys
import tarfile
import zipfile

LIB_PREFIX = "libllm_provider.so"
PT_NOTE = 4
NT_GNU_BUILD_ID = 3


def elf_build_id(data):
    """返回 ELF64 LE 的 NT_GNU_BUILD_ID 十六进制字符串。"""
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise ValueError("不是 ELF 文件")
    if data[4] != 2:
        raise ValueError("只支持 ELF64")
    if data[5] != 1:
        raise ValueError("只支持小端 ELF")
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]
    if e_phoff + e_phentsize * e_phnum > len(data):
        raise ValueError("ELF program header 越界")
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if struct.unpack_from("<I", data, off)[0] != PT_NOTE:
            continue
        p_offset = struct.unpack_from("<Q", data, off + 8)[0]
        p_filesz = struct.unpack_from("<Q", data, off + 32)[0]
        pos, end = p_offset, p_offset + p_filesz
        if end > len(data):
            raise ValueError("ELF note 段越界")
        while pos + 12 <= end:
            namesz, descsz, ntype = struct.unpack_from("<III", data, pos)
            pos += 12
            name = data[pos:pos + namesz]
            pos += (namesz + 3) & ~3
            desc = data[pos:pos + descsz]
            pos += (descsz + 3) & ~3
            if ntype == NT_GNU_BUILD_ID and name.rstrip(b"\0") == b"GNU":
                if not desc:
                    raise ValueError("NT_GNU_BUILD_ID 为空")
                return desc.hex()
    raise ValueError("未找到 NT_GNU_BUILD_ID")


def iter_members(path, prefix):
    """产出 (成员名, 字节)，只读取文件名匹配 prefix 的成员。

    先按名字过滤再读取：bundled AAR / HAR 里有数百 MB 的模型资源，
    全量 zf.read() 会把它们逐个读进内存，只为了判断文件名。
    普通文件返回单个成员，成员名即文件名。
    """
    p = pathlib.Path(path)
    if not p.is_file():
        raise SystemExit("文件不存在：%s" % p)
    if zipfile.is_zipfile(p):
        with zipfile.ZipFile(p) as zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue
                if not info.filename.rsplit("/", 1)[-1].startswith(prefix):
                    continue
                yield info.filename, zf.read(info)
        return
    if tarfile.is_tarfile(p):
        with tarfile.open(p, "r:*") as tf:
            for member in tf.getmembers():
                if not member.isfile():
                    continue
                if not member.name.rsplit("/", 1)[-1].startswith(prefix):
                    continue
                f = tf.extractfile(member)
                if f is not None:
                    yield member.name, f.read()
        return
    yield p.name, p.read_bytes()


def collect(path):
    """返回 [(成员名, Build ID)]，只保留 libllm_provider.so* 且能解析出 ID 的项。"""
    found = []
    for name, data in iter_members(path, LIB_PREFIX):
        try:
            found.append((name, elf_build_id(data)))
        except ValueError as exc:
            raise SystemExit("无法读取 %s 中的 %s：%s" % (path, name, exc))
    if not found:
        raise SystemExit("在 %s 中未找到 %s*，请确认构件内容" % (path, LIB_PREFIX))
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", help="ARTIFACT SYMBOLS，或 --print/--id 的单个文件")
    ap.add_argument("--print", dest="show", action="store_true", help="列出所有匹配项及 Build ID")
    ap.add_argument("--id", dest="only_id", action="store_true", help="只输出唯一的 Build ID")
    args = ap.parse_args()

    if args.show or args.only_id:
        if len(args.paths) != 1:
            ap.error("--print / --id 需要且只需要一个文件")
        items = collect(args.paths[0])
        if args.only_id:
            ids = {bid for _, bid in items}
            if len(ids) != 1:
                raise SystemExit("%s 内含多个不同的 Build ID：%s" % (args.paths[0], ", ".join(sorted(ids))))
            print(next(iter(ids)))
        else:
            for name, bid in items:
                print("%s\t%s" % (bid, name))
        return 0

    if len(args.paths) != 2:
        ap.error("需要两个参数：ARTIFACT SYMBOLS")
    artifact, symbols = args.paths
    a_items, s_items = collect(artifact), collect(symbols)
    print("artifact  %s" % artifact)
    for name, bid in a_items:
        print("  %s  %s" % (bid, name))
    print("symbols   %s" % symbols)
    for name, bid in s_items:
        print("  %s  %s" % (bid, name))
    a_ids = {bid for _, bid in a_items}
    s_ids = {bid for _, bid in s_items}
    if a_ids != s_ids or len(a_ids) != 1:
        print("FAIL: Build ID 不一致，符号表与交付物不是同一次链接的产物", file=sys.stderr)
        return 1
    print("PASS: Build ID 一致（%s）" % next(iter(a_ids)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
