#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pw_sav_probe.py -- 自包含的 Palworld .sav 结构探测器

为什么需要它
------------
pw_recon.py 依赖第三方库 palworld_save_tools。如果那个库在你的旧存档上
翻车（0.1.4 时代的格式和它主推的 0.3.x 有差异），你会陷入
"不知道是库的问题还是存档的问题"。

这个脚本只用 Python 标准库，做三件事:

  1. 解压 .sav，验证 GVAS 文件头 (引擎版本 / custom version / UE 版本)
  2. 扫描顶层属性名与类型
  3. 递归进入 StructProperty，列出 worldSaveData 下每个子项的
     名称、类型、payload 大小

它不做完整解码 —— 目标是"看见结构"，不是"读出数据"。
只要能在这里看到 MapObjectSaveData 是一个 ArrayProperty 且大小合理，
就说明数据在文件里是结构化的，剩下的只是找对解码方式。

明确不打印 payload 的十六进制内容（那会刷屏）。

用法
----
    python pw_sav_probe.py
    python pw_sav_probe.py --save "C:\\path\\to\\Level.sav"
    python pw_sav_probe.py --depth 3          # 限制递归深度
    python pw_sav_probe.py --report out.json  # 把结构树写成 JSON
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import struct
import sys
import zlib
from datetime import datetime

SAVE_ROOT = os.path.join(
    os.environ.get("LOCALAPPDATA", ""), "Pal", "Saved", "SaveGames"
)
GVAS_MAGIC = 0x53415647  # "GVAS"

# 只报告这些类型的内容摘要，避免噪音
SCALAR_TYPES = {
    "IntProperty", "Int8Property", "Int16Property", "Int64Property",
    "UInt8Property", "UInt16Property", "UInt32Property", "UInt64Property",
    "FloatProperty", "DoubleProperty", "BoolProperty", "ByteProperty",
    "StrProperty", "NameProperty", "EnumProperty", "TextProperty",
    "SoftObjectProperty", "ObjectProperty", "Guid",
}


def log(msg: str = "") -> None:
    print(msg, flush=True)


def section(title: str) -> None:
    log("")
    log("=" * 72)
    log(title)
    log("=" * 72)


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024.0
    return f"{n:.1f}GB"


# --------------------------------------------------------------------------
# 定位存档
# --------------------------------------------------------------------------


def find_saves() -> list[tuple[float, str]]:
    out: dict[str, float] = {}
    if not os.path.isdir(SAVE_ROOT):
        return []
    for pattern in ("*/*/Level.sav", "*/*/backup/world/*/Level.sav"):
        for p in glob.glob(os.path.join(SAVE_ROOT, pattern)):
            rel = os.path.relpath(p, SAVE_ROOT)
            try:
                out[rel] = os.path.getmtime(p)
            except OSError:
                pass
    return sorted(((m, r) for r, m in out.items()), key=lambda x: -x[0])


# --------------------------------------------------------------------------
# 解压
# --------------------------------------------------------------------------


def decompress(raw: bytes) -> tuple[bytes, int, list[str]]:
    """返回 (gvas 字节, save_type, 说明列表)"""
    notes: list[str] = []
    if raw[8:11] == b"CNK":
        off = 24
        unc = int.from_bytes(raw[12:16], "little")
        save_type = raw[23]
        notes.append("检测到 CNK 包装层 (0.5+)")
    else:
        off = 12
        unc = int.from_bytes(raw[0:4], "little")
        save_type = raw[11]

    if raw[off - 3 : off] != b"PlZ" and raw[8:11] != b"PlZ":
        raise ValueError(
            f"没找到 'PlZ' 魔数，这不是 Palworld 存档 (头部: {raw[:16].hex(' ')})"
        )

    payload = raw[off:]
    try:
        data = zlib.decompress(payload)
        if save_type == 0x32:
            data = zlib.decompress(data)
            notes.append("双层 zlib，已解两次")
    except zlib.error as exc:
        raise ValueError(
            f"zlib 解压失败: {exc}\n"
            "  这通常意味着存档使用了 Oodle 压缩 (0.5+ 部分版本)。\n"
            "  本脚本不支持 Oodle，需要 pip install ooz 或用 palworld_save_tools。"
        ) from exc

    if unc and len(data) != unc:
        notes.append(f"解压长度 {len(data)} != 头部声明 {unc}")
    notes.append(f"save_type = {hex(save_type)}")
    return data, save_type, notes


# --------------------------------------------------------------------------
# 二进制读取器
# --------------------------------------------------------------------------


class Reader:
    def __init__(self, data: bytes):
        self.d = data
        self.p = 0

    def eof(self) -> bool:
        return self.p >= len(self.d)

    def remaining(self) -> int:
        return len(self.d) - self.p

    def take(self, n: int) -> bytes:
        if n < 0 or self.p + n > len(self.d):
            raise EOFError(
                f"越界读取: 位置 {self.p} 需要 {n} 字节, 只剩 {self.remaining()}"
            )
        b = self.d[self.p : self.p + n]
        self.p += n
        return b

    def u8(self) -> int:
        return self.take(1)[0]

    def i32(self) -> int:
        return struct.unpack("<i", self.take(4))[0]

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u16(self) -> int:
        return struct.unpack("<H", self.take(2))[0]

    def i64(self) -> int:
        return struct.unpack("<q", self.take(8))[0]

    def fstring(self) -> str:
        """UE 的字符串: i32 长度(含结尾 NUL, 负数=UTF-16) + 数据"""
        n = self.i32()
        if n == 0:
            return ""
        if n < 0:
            raw = self.take(-n * 2)
            return raw.decode("utf-16-le", "replace").rstrip("\x00")
        raw = self.take(n)
        return raw.decode("utf-8", "replace").rstrip("\x00")

    def guid(self) -> str:
        b = self.take(16)
        h = b.hex()
        return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


# --------------------------------------------------------------------------
# GVAS 头
# --------------------------------------------------------------------------


def read_gvas_header(r: Reader) -> dict:
    h: dict = {}
    h["magic"] = r.i32()
    if h["magic"] != GVAS_MAGIC:
        raise ValueError(f"GVAS 魔数不对: {h['magic']:#x}")
    h["save_game_version"] = r.i32()
    h["package_file_version_ue4"] = r.i32()
    h["package_file_version_ue5"] = r.i32()
    h["engine_major"] = r.u16()
    h["engine_minor"] = r.u16()
    h["engine_patch"] = r.u16()
    h["engine_changelist"] = r.u32()
    h["engine_branch"] = r.fstring()
    h["custom_version_format"] = r.i32()
    count = r.u32()
    h["custom_version_count"] = count
    cvs = []
    for _ in range(min(count, 64)):
        cvs.append({"guid": r.guid(), "version": r.i32()})
    h["custom_versions"] = cvs
    h["save_game_class_name"] = r.fstring()
    return h


# --------------------------------------------------------------------------
# 属性结构扫描 (只记录名字/类型/大小, 不打印内容)
# --------------------------------------------------------------------------


def read_property_header(r: Reader) -> tuple[str, str, int] | None:
    """读一个属性的 名称/类型/payload大小。返回 None 表示属性列表结束。"""
    name = r.fstring()
    if name == "None" or name == "":
        return None
    type_name = r.fstring()
    size = r.i64()
    return name, type_name, size


def scan_properties(r: Reader, depth: int, max_depth: int, out: list, path: str) -> None:
    """在当前偏移处扫描属性列表，递归进入 StructProperty。"""
    while not r.eof():
        try:
            head = read_property_header(r)
        except EOFError:
            out.append({"path": path, "note": "提前遇到文件结尾"})
            return
        if head is None:
            return
        name, type_name, size = head
        entry = {
            "path": f"{path}.{name}" if path else name,
            "type": type_name,
            "size": size,
        }

        if type_name == "StructProperty":
            entry["struct_type"] = r.fstring()
            entry["struct_id"] = r.guid()
            r.u8()  # 属性引导字节
            # 这里 payload 大小应等于 size，递归其内部
            start = r.p
            if depth < max_depth:
                sub: list = []
                try:
                    scan_properties(r, depth + 1, max_depth, sub, entry["path"])
                except Exception as exc:
                    sub.append({"path": entry["path"], "error": str(exc)})
                entry["children"] = sub
            # 无论是否递归，指针都对齐到 payload 末尾
            r.p = start + size
            out.append(entry)

        elif type_name == "ArrayProperty":
            entry["element_type"] = r.fstring()
            r.u8()  # 引导字节
            if entry["element_type"] == "StructProperty":
                # 数组内元素的属性头
                start = r.p
                inner_name = ""
                try:
                    inner_name = r.fstring()
                    r.fstring()  # 元素类型
                    r.i64()  # 元素大小
                    r.fstring()  # struct type
                    r.guid()
                    r.u8()
                except Exception:
                    pass
                entry["element_name"] = inner_name
                r.p = start + size
            else:
                r.p += size
            out.append(entry)

        else:
            # 标量/其它类型: 直接跳过 payload
            r.p += max(size, 0)
            out.append(entry)


# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------


def render(node: dict, depth: int = 0, lines: list | None = None,
           max_lines: int = 400) -> list[str]:
    if lines is None:
        lines = []
    if len(lines) >= max_lines:
        return lines
    indent = "  " * depth
    size = node.get("size", 0)
    label = node.get("path", "?").split(".")[-1]
    desc = f"{node.get('type', '?')}"
    if node.get("struct_type"):
        desc += f" <{node['struct_type']}>"
    if node.get("element_type"):
        desc += f" [{node['element_type']}]"
    lines.append(f"{indent}{label:<42} {desc:<34} {human(size)}")
    for ch in node.get("children", []):
        if "error" in ch:
            lines.append(f"{indent}  ! {ch['path']}: {ch['error']}")
            continue
        render(ch, depth + 1, lines, max_lines)
    return lines


def main() -> int:
    ap = argparse.ArgumentParser(description="Palworld .sav 结构探测器 (自包含)")
    ap.add_argument("--save", help="Level.sav 完整路径")
    ap.add_argument("--depth", type=int, default=4, help="递归深度, 默认 4")
    ap.add_argument("--report", help="把结构树写成 JSON")
    ap.add_argument("--list", action="store_true", help="只列出存档")
    args = ap.parse_args()

    section("Palworld 存档结构探测 (自包含, 无第三方依赖)")
    log(f"Python : {sys.version.split()[0]}")
    log(f"时间   : {datetime.now():%Y-%m-%d %H:%M:%S}")

    if args.list:
        for m, rel in find_saves():
            stamp = datetime.fromtimestamp(m).strftime("%Y-%m-%d %H:%M:%S")
            log(f"  {stamp}  {rel}")
        return 0

    save_path = args.save
    if not save_path:
        saves = find_saves()
        primary = [s for s in saves if os.sep + "backup" + os.sep not in s[1]]
        pick = (primary or saves)
        if not pick:
            log(f"[X] 没找到存档: {SAVE_ROOT}")
            return 2
        save_path = os.path.join(SAVE_ROOT, pick[0][1])
        log("")
        log(f"自动选择: {pick[0][1]}")

    with open(save_path, "rb") as fh:
        raw = fh.read()

    section("步骤 1: 解压")
    log(f"文件: {save_path}")
    log(f"大小: {human(len(raw))}")
    try:
        gvas, save_type, notes = decompress(raw)
    except ValueError as exc:
        log(f"[X] {exc}")
        return 1
    for n in notes:
        log(f"[i] {n}")
    log(f"[+] 解压成功, GVAS 大小 {human(len(gvas))}")

    section("步骤 2: GVAS 文件头")
    r = Reader(gvas)
    try:
        header = read_gvas_header(r)
    except Exception as exc:
        log(f"[X] 读文件头失败: {exc}")
        return 1

    log(f"  UE 版本        : {header['engine_major']}.{header['engine_minor']}.{header['engine_patch']}")
    log(f"  引擎分支       : {header['engine_branch']}")
    log(f"  changelist     : {header['engine_changelist']}")
    log(f"  SaveGame 版本  : {header['save_game_version']}")
    log(f"  PackageFile    : ue4={header['package_file_version_ue4']} ue5={header['package_file_version_ue5']}")
    log(f"  custom version : 格式 {header['custom_version_format']}, 共 {header['custom_version_count']} 条")
    log(f"  存档类名       : {header['save_game_class_name']}")

    section(f"步骤 3: 属性结构 (递归深度 {args.depth})")
    log("  格式: 名称  类型<结构体> [数组元素类型]  payload大小")
    log("")
    tree: list = []
    try:
        scan_properties(r, 1, args.depth, tree, "")
    except Exception as exc:
        log(f"[!] 扫描中断: {exc}")
        log(f"    已成功扫描到 {len(tree)} 个属性，位置 {r.p}/{len(gvas)}")

    for node in tree:
        for line in render(node, 0, [], max_lines=60):
            log("  " + line)
        if len(tree) > 40:
            log("  ... (属性过多，只显示前 40 个)")
            break

    # 关注点
    section("关注点检查")
    flat: list[dict] = []

    def flatten(nodes):
        for n in nodes:
            flat.append(n)
            flatten(n.get("children", []))

    flatten(tree)

    hits = [n for n in flat if "mapobject" in n["path"].lower()]
    if hits:
        log("[+] 发现 MapObject 相关属性:")
        for n in hits[:10]:
            log(f"    {n['path']}  ({n['type']}, {human(n.get('size', 0))})")
        log("")
        log("    ==> 建筑数据在文件里是结构化的，离线导出蓝图可行。")
    else:
        log("[!] 在扫描深度内没看到 MapObject 相关属性。")
        log("    试试加大深度: python pw_sav_probe.py --depth 6")
        log("    或看 worldSaveData 那一项的子节点列表。")

    wsd = [n for n in flat if n["path"].endswith("worldSaveData")]
    if wsd:
        log("")
        log("[+] worldSaveData 的子项:")
        for ch in wsd[0].get("children", []):
            log(f"    {ch['path'].split('.')[-1]:<46} {ch.get('type','?'):<18} {human(ch.get('size',0))}")

    if args.report:
        try:
            with open(args.report, "w", encoding="utf-8") as fh:
                json.dump(
                    {"save": save_path, "header": header, "tree": tree},
                    fh,
                    ensure_ascii=False,
                    indent=2,
                    default=str,
                )
            log("")
            log(f"[+] 结构树已写出: {args.report}")
        except Exception as exc:
            log(f"[X] 写报告失败: {exc}")

    log("")
    log("注: 本脚本只扫描结构，不解码 payload。")
    log("    要真正读出建筑 ID 和 Transform，请跑 pw_recon.py。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
