#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pw_recon.py -- Palworld 存档侦察工具  (阶段 0 侦察)

目的
----
用一份真实的 Level.sav 回答三个决定项目走向的问题:

  Q1  这份存档的 GVAS 格式版本是多少? 能不能被解析?
  Q2  MapObjectSaveData / BaseCampSaveData 里的建筑记录能不能读出来?
  Q3  读出来以后, "建筑ID + Transform" 是否完整? 也就是离线导出蓝图这条路
      到底成不成立?

设计原则
--------
* 不依赖网络也能跑: 若本地已有 palworld_save_tools 就直接用;
  否则尝试从已下载的 wheel 解压到 _vendor/ ; 再不行走内置的降级解析器
  (tools/pw_sav_probe.py), 那个是完全自包含的。
* 不需要安装任何东西。
* 输出为纯 ASCII 控制台摘要 + 完整的 UTF-8 JSON 报告文件。
* 失败也要留下线索: 每一步单独 try, 把异常完整记录到报告里。

用法
----
    python pw_recon.py
    python pw_recon.py --save "C:\\path\\to\\Level.sav"
    python pw_recon.py --list           # 只列出找到的存档
    python pw_recon.py --dump-full      # 额外导出完整 JSON (体积很大)

脚本默认会强制启用 MapObjectSaveData 的解析（新版库里它是关闭的），
这是读建筑数据的关键。用 --no-map-objects 可以关掉。
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import traceback
import zipfile
from datetime import datetime

# --------------------------------------------------------------------------
# 0. 常量与小工具
# --------------------------------------------------------------------------

MAGIC = b"PlZ"
HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(HERE)
WORK_DIR = os.path.join(PROJECT_ROOT, "work")
VENDOR_DIR = os.path.join(PROJECT_ROOT, "_vendor")
BOOTSTRAP_DIR = os.path.join(HERE, "_bootstrap")

SAVE_ROOT = os.path.join(
    os.environ.get("LOCALAPPDATA", ""), "Pal", "Saved", "SaveGames"
)

# 我们关心的键名模式 (小写子串匹配)
INTERESTING = (
    "mapobject",
    "basecamp",
    "building",
    "build_process",
    "foliage",
    "levelobject",
    "concretemodel",
    "modulemap",
)

MAP_OBJECT_DATA_PATH = ".worldSaveData.MapObjectSaveData"


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
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024.0
    return f"{n:.1f}GB"


def err_text(exc: BaseException) -> str:
    return "".join(traceback.format_exception_only(type(exc), exc)).strip()


# --------------------------------------------------------------------------
# 1. 定位存档
# --------------------------------------------------------------------------


def find_saves() -> list[tuple[float, str, str]]:
    """返回 [(mtime, 世界目录, Level.sav 路径), ...]，按修改时间倒序。"""
    out: list[tuple[float, str, str]] = []
    if not os.path.isdir(SAVE_ROOT):
        return out
    for pattern in ("*/*/Level.sav", "*/*/backup/world/*/Level.sav"):
        for p in glob.glob(os.path.join(SAVE_ROOT, pattern)):
            try:
                mtime = os.path.getmtime(p)
            except OSError:
                continue
            world_dir = os.path.dirname(p)
            if os.sep + "backup" + os.sep in p:
                world_dir = p.split(os.sep + "backup" + os.sep)[0]
            name = os.path.relpath(p, SAVE_ROOT)
            out.append((mtime, world_dir, name))
    # 去重（同一物理文件可能被两个 pattern 命中）
    seen: set[str] = set()
    uniq: list[tuple[float, str, str]] = []
    for item in sorted(out, key=lambda x: -x[0]):
        key = item[2]
        if key in seen:
            continue
        seen.add(key)
        uniq.append(item)
    return uniq


def list_saves() -> None:
    saves = find_saves()
    section("找到的 Palworld 存档 (按修改时间倒序)")
    if not saves:
        log(f"[!] 在以下目录没有找到任何 Level.sav:")
        log(f"    {SAVE_ROOT}")
        log("    如果游戏装在别的用户下, 用 --save 手动指定路径。")
        return
    for i, (mtime, world, rel) in enumerate(saves):
        stamp = datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")
        size = human(os.path.getsize(os.path.join(SAVE_ROOT, rel)))
        log(f"{i:3d}. {stamp}  {size:>10}  {rel}")


# --------------------------------------------------------------------------
# 2. 依赖准备
# --------------------------------------------------------------------------


def ensure_dependency() -> tuple[bool, str]:
    """确保能 import palworld_save_tools。返回 (是否可用, 说明)。"""
    # 2a. 本地已装?
    try:
        import palworld_save_tools  # noqa: F401

        return True, "已在当前 Python 环境中找到 palworld_save_tools"
    except Exception as exc:
        first_error = err_text(exc)

    # 2b. 已解压到 _vendor?
    if os.path.isdir(VENDOR_DIR):
        sys.path.insert(0, VENDOR_DIR)
        try:
            import palworld_save_tools  # noqa: F401

            return True, f"已使用本地缓存 {VENDOR_DIR}"
        except Exception:
            pass

    # 2c. 从 wheel / 源码包解压
    archives = sorted(
        glob.glob(os.path.join(BOOTSTRAP_DIR, "*.whl"))
        + glob.glob(os.path.join(BOOTSTRAP_DIR, "*.zip"))
        + glob.glob(os.path.join(BOOTSTRAP_DIR, "*.tar.gz"))
    )
    if archives:
        os.makedirs(VENDOR_DIR, exist_ok=True)
        extracted_any = False
        for arch in archives:
            try:
                if arch.endswith(".tar.gz"):
                    import tarfile

                    with tarfile.open(arch) as tf:
                        tf.extractall(VENDOR_DIR)
                else:
                    with zipfile.ZipFile(arch) as zf:
                        zf.extractall(VENDOR_DIR)
                extracted_any = True
                log(f"[+] 已解压 {os.path.basename(arch)} -> {VENDOR_DIR}")
            except Exception as exc:
                log(f"[!] 解压失败 {arch}: {err_text(exc)}")
        if extracted_any:
            sys.path.insert(0, VENDOR_DIR)
            try:
                import palworld_save_tools  # noqa: F401

                return True, f"从 {BOOTSTRAP_DIR} 解压后可用"
            except Exception as exc:
                return False, f"解压成功但仍无法 import: {err_text(exc)}"

    return False, (
        f"无法 import palworld_save_tools ({first_error})。"
        f"请把 palworld_save_tools 的 wheel 放进 {BOOTSTRAP_DIR}，"
        f"或直接运行降级解析器 pw_sav_probe.py。"
    )


def enable_map_object_parsing() -> str:
    """把 MapObjectSaveData 的解析器重新注册进 PALWORLD_CUSTOM_PROPERTIES。

    新版库把这一项放进了 DISABLED_PROPERTIES（0.3.7+ 的内存优化格式把
    UObject 字段编码进了 raw bytes），所以默认不会解码它。
    但 0.1.4 时代的旧存档用的是结构化格式，解码器依然可用，
    因此我们显式把它插回去。这是整个侦察的关键一步，默认就做。
    """
    try:
        from palworld_save_tools import paltypes
        from palworld_save_tools.rawdata import map_object

        paltypes.PALWORLD_CUSTOM_PROPERTIES[MAP_OBJECT_DATA_PATH] = (
            map_object.decode,
            map_object.encode,
        )
        added = []
        for suffix in (
            ".ConcreteModel.ModuleMap.Value",
            ".Model.EffectMap.Value",
        ):
            key = MAP_OBJECT_DATA_PATH + ".MapObjectSaveData" + suffix
            if key not in paltypes.PALWORLD_TYPE_HINTS:
                paltypes.PALWORLD_TYPE_HINTS[key] = "StructProperty"
                added.append(suffix)
        note = f" (补充 type hint: {added})" if added else ""
        return f"已启用 MapObjectSaveData 解析{note}"
    except Exception as exc:
        return f"启用 MapObjectSaveData 解析失败: {err_text(exc)}"


# --------------------------------------------------------------------------
# 3. 读取 .sav
# --------------------------------------------------------------------------


def inspect_header(raw: bytes) -> dict:
    """不依赖任何库，直接从文件头提取版本信息。

    真实布局 (来自 palworld_save_tools/palsav.py):
        [0:4]   u32 uncompressed_len
        [4:8]   u32 compressed_len
        [8:11]  b"PlZ"
        [11]    u8  save_type   (0x31 = 单层 zlib, 0x32 = 双层 zlib)
        [12:]   payload

    0.5+ 的部分存档会在最前面多一层 "CNK" 包装:
        [0:4]=0 [4:8]=0 b"CNK" [12:16] uncompressed [16:20] compressed
        [20:23] b"PlZ" [23] save_type [24:] payload
    """
    info: dict = {"head_hex": raw[:32].hex(" ")}
    try:
        if len(raw) < 24:
            info["note"] = "文件太小"
            return info
        if raw[8:11] == b"CNK":
            info["cnk_wrapper"] = True
            info["uncompressed_size"] = int.from_bytes(raw[12:16], "little")
            info["compressed_size"] = int.from_bytes(raw[16:20], "little")
            magic = raw[20:23]
            save_type = raw[23]
            info["payload_offset"] = 24
        else:
            info["cnk_wrapper"] = False
            info["uncompressed_size"] = int.from_bytes(raw[0:4], "little")
            info["compressed_size"] = int.from_bytes(raw[4:8], "little")
            magic = raw[8:11]
            save_type = raw[11]
            info["payload_offset"] = 12

        info["magic"] = magic.decode("ascii", "replace")
        info["save_type"] = hex(save_type)
        info["compression"] = {
            0x30: "未压缩",
            0x31: "zlib (单层)",
            0x32: "zlib (双层)",
        }.get(save_type, f"未知/可能是 Oodle ({hex(save_type)})")
        info["magic_ok"] = magic == MAGIC
        info["save_type_ok"] = save_type in (0x30, 0x31, 0x32)
        # 自检: 压缩长度是否与文件实际大小吻合
        expected = info["compressed_size"]
        actual = len(raw) - info["payload_offset"]
        # 0x31 存的 compressed_len 就是 payload 长度; 0x32 存的是中间层长度
        info["length_check"] = "ok" if expected == actual else (
            f"compressed_len={expected} 而 payload={actual} "
            f"({'双层压缩, 正常' if save_type == 0x32 else '不匹配, 可能文件损坏'})"
        )
    except Exception as exc:
        info["header_error"] = err_text(exc)
    return info


def decompress(raw: bytes) -> tuple[bytes, list[str]]:
    """按 GVAS 格式解压，不依赖第三方库。支持 0x31 / 0x32 两种 zlib 布局。"""
    notes: list[str] = []
    import zlib

    try:
        off = 24 if raw[8:11] == b"CNK" else 12
        uncompressed_size = int.from_bytes(
            raw[12:16] if off == 24 else raw[0:4], "little"
        )
        save_type = raw[23] if off == 24 else raw[11]
        payload = raw[off:]

        data = zlib.decompress(payload)
        if save_type == 0x32:
            data = zlib.decompress(data)
            notes.append("双层 zlib 压缩，已解两次")

        if len(data) != uncompressed_size:
            notes.append(
                f"解压后长度 {len(data)} 与头部声明 {uncompressed_size} 不一致"
            )
        return data, notes
    except Exception as exc:
        notes.append(f"zlib 解压失败: {err_text(exc)}")
        notes.append(
            "若存档来自 0.5+ 版本，可能使用 Oodle 压缩，"
            "需要额外安装 ooz 库 (pip install ooz)，本脚本暂不支持"
        )
        return b"", notes


def load_save(path: str, raw: bytes, skip_map_objects: bool = False) -> tuple[dict | None, dict]:
    """返回 (gvas 对象 或 None, 诊断信息)"""
    diag: dict = {"path": path, "bytes": len(raw)}

    section("阶段 A: 解析 GVAS")
    log(f"文件      : {path}")
    log(f"大小      : {human(len(raw))}")

    info = inspect_header(raw)
    diag["header"] = info
    log(f"文件头魔数: {info.get('magic', '(?)')}   CNK 包装: {info.get('cnk_wrapper')}")
    log(f"压缩方式  : {info.get('compression', '(?)')}")
    log(f"解压后大小: {info.get('uncompressed_size', '(?)')}")
    log(f"长度自检  : {info.get('length_check', '(?)')}")
    if not info.get("magic_ok", False):
        log("[!] 文件头不是 'PlZ'，可能拿错文件了（比如拿到 Player 的 .sav）")
    if not info.get("save_type_ok", True):
        log("[!] 压缩类型未知，很可能是 0.5+ 的 Oodle 压缩，本脚本处理不了")

    ok, msg = ensure_dependency()
    log(f"依赖      : {msg}")
    diag["dependency"] = msg
    diag["dependency_ok"] = ok

    if ok:
        # 关键: 把 MapObjectSaveData 的解码器插回去 (新版库里默认是关的)
        if not skip_map_objects:
            note = enable_map_object_parsing()
            log(f"解码器    : {note}")
            diag["map_object_decoder"] = note

        try:
            from palworld_save_tools.gvas import GvasFile
            from palworld_save_tools import paltypes

            gvas_bytes, notes = decompress(raw)
            diag["decompress_notes"] = notes
            if not gvas_bytes:
                for n in notes:
                    log(f"[!] {n}")
                log("[X] 解压失败，无法继续")
                return None, diag
            for n in notes:
                log(f"[i] {n}")

            gvas = GvasFile.read(
                gvas_bytes,
                paltypes.PALWORLD_TYPE_HINTS,
                paltypes.PALWORLD_CUSTOM_PROPERTIES,
            )
            log("[+] GVAS 解析成功")
            diag["parsed"] = True
            diag["gvas_size"] = len(gvas_bytes)
            return gvas, diag
        except Exception as exc:
            diag["parse_error"] = err_text(exc)
            diag["parse_traceback"] = traceback.format_exc()
            log(f"[X] GVAS 解析失败: {err_text(exc)}")
            log("")
            log("    下一步: 跑自包含解析器确认是不是库的兼容问题")
            log("        python pw_sav_probe.py")
            return None, diag

    log("[X] 依赖不可用，跳过库解析路径")
    return None, diag


# --------------------------------------------------------------------------
# 4. 结构侦察
# --------------------------------------------------------------------------


def walk_keys(node, path: str, acc: dict, depth: int = 0, max_depth: int = 20) -> None:
    """把整棵 JSON 树里出现过的所有键路径收集到 acc。"""
    if depth > max_depth:
        return
    if isinstance(node, dict):
        for k, v in node.items():
            child = f"{path}.{k}" if path else k
            info = acc.setdefault(
                child, {"count": 0, "types": set(), "examples": []}
            )
            info["count"] += 1
            info["types"].add(type(v).__name__)
            if len(info["examples"]) < 3:
                info["examples"].append(squeeze(v))
            walk_keys(v, child, acc, depth + 1, max_depth)
    elif isinstance(node, list):
        for item in node[:5]:
            walk_keys(item, path + "[]", acc, depth + 1, max_depth)


def squeeze(value, limit: int = 300):
    """把值压成可安全放进报告的短形式。"""
    if isinstance(value, (str, int, float, bool)) or value is None:
        text = repr(value)
        return text if len(text) <= limit else text[:limit] + "...<截断>"
    if isinstance(value, list):
        return f"<list len={len(value)}>"
    if isinstance(value, dict):
        keys = list(value.keys())
        return f"<dict keys={keys[:8]}{'...' if len(keys) > 8 else ''}>"
    return f"<{type(value).__name__}>"


def get_by_path(tree, dotted: str):
    """按 '.a.b.c' 取值。

    会自动穿透 GVAS 属性包装层: 遇到 {"type":..., "value":...} 时
    优先看 value 里面，这样既能走属性名也能走裸结构。
    """
    node = tree
    for part in dotted.strip(".").split("."):
        if not part:
            continue
        if not isinstance(node, dict):
            return None
        if part in node:
            node = node[part]
        elif isinstance(node.get("value"), dict) and part in node["value"]:
            node = node["value"][part]
        else:
            return None
    return node


def find_map_objects(tree) -> tuple[list, str]:
    """在解析结果里找出建筑/地图对象记录列表。"""
    candidates = [
        ".worldSaveData.MapObjectSaveData",
        "worldSaveData.MapObjectSaveData",
    ]
    for path in candidates:
        node = get_by_path(tree, path)
        if node is None:
            continue
        # 结构通常是 {"value": {"values": [...]}}
        cur = node
        for _ in range(4):
            if isinstance(cur, dict) and "value" in cur:
                cur = cur["value"]
            elif isinstance(cur, dict) and "values" in cur:
                cur = cur["values"]
            else:
                break
        if isinstance(cur, list):
            return cur, path
    return [], ""


def summarize_entry(entries: list) -> dict:
    """分析一条建筑记录的字段构成。"""
    result: dict = {"entry_count": len(entries)}
    if not entries:
        return result
    sample = entries[0]
    result["top_level_keys"] = sorted(sample.keys()) if isinstance(sample, dict) else []

    ids: dict[str, int] = {}
    with_transform = 0
    with_model = 0
    bad: list[str] = []
    for e in entries:
        if not isinstance(e, dict):
            continue
        mid = e.get("MapObjectId")
        if isinstance(mid, dict):
            mid = mid.get("value")
        ids[str(mid)] = ids.get(str(mid), 0) + 1

        model = e.get("Model")
        if isinstance(model, dict):
            with_model += 1
            raw = get_by_path(model, "value.RawData.value")
            if isinstance(raw, dict) and "initital_transform_cache" in raw:
                with_transform += 1
        else:
            bad.append("Model 字段缺失或类型异常")

    result["distinct_map_object_ids"] = len(ids)
    result["top_ids"] = sorted(ids.items(), key=lambda kv: -kv[1])[:25]
    result["with_Model"] = with_model
    result["with_initital_transform_cache"] = with_transform
    result["problems"] = bad[:5]
    return result


def dump_one_entry(entries: list, out_path: str) -> bool:
    """把第一条完整记录写成文件，供逐字段确认。"""
    for e in entries:
        if isinstance(e, dict):
            try:
                with open(out_path, "w", encoding="utf-8") as fh:
                    json.dump(e, fh, ensure_ascii=False, indent=2)
                return True
            except Exception as exc:
                log(f"[!] 写样例失败: {err_text(exc)}")
                return False
    return False


# --------------------------------------------------------------------------
# 5. 主流程
# --------------------------------------------------------------------------


def analyse(gvas, out_dir: str, dump_full: bool) -> dict:
    tree = getattr(gvas, "properties", gvas)
    report: dict = {}

    # ---- 5a. 键清单 -------------------------------------------------------
    section("阶段 B: 键结构扫描")
    acc: dict = {}
    walk_keys(tree, "", acc)
    report["key_paths_found"] = len(acc)

    interesting = {
        k: v for k, v in acc.items() if any(p in k.lower() for p in INTERESTING)
    }
    report["key_paths_interesting"] = len(interesting)

    log(f"共发现 {len(acc)} 条键路径，其中 {len(interesting)} 条与建筑相关。")
    log("")
    log("--- 与建筑/地图对象相关的键 (按出现次数倒序, 最多 40 条) ---")
    if not interesting:
        log("(无)")
    for k, v in sorted(interesting.items(), key=lambda kv: -kv[1]["count"])[:40]:
        types = ",".join(sorted(v["types"]))
        log(f"  x{v['count']:<6} {types:<22} {k}")
        for ex in v["examples"][:1]:
            log(f"          例: {ex}")

    report["interesting_keys"] = {
        k: {
            "count": v["count"],
            "types": sorted(v["types"]),
            "examples": [str(x) for x in v["examples"]],
        }
        for k, v in sorted(interesting.items(), key=lambda kv: -kv[1]["count"])
    }

    # ---- 5b. worldSaveData 一级子项 ---------------------------------------
    section("阶段 C: worldSaveData 一级子项")
    wsd = get_by_path(tree, ".worldSaveData")
    if isinstance(wsd, dict):
        cur = wsd.get("value", wsd)
        if isinstance(cur, dict):
            for k in sorted(cur.keys()):
                node = cur[k]
                kind = type(node).__name__
                extra = ""
                inner = node.get("value") if isinstance(node, dict) else None
                if isinstance(inner, dict) and "values" in inner:
                    vals = inner["values"]
                    if isinstance(vals, list):
                        extra = f"  ({len(vals)} 条记录)"
                    elif isinstance(vals, dict):
                        extra = f"  ({len(vals)} 个键)"
                log(f"  {k:<46} {kind:<16}{extra}")
                report.setdefault("worldSaveData_children", {})[k] = {
                    "type": kind,
                    "note": extra.strip(),
                }
    else:
        log("[!] 没找到 worldSaveData，这不太正常")

    # ---- 5c. 建筑记录 ------------------------------------------------------
    section("阶段 D: 建筑 / 地图对象记录")
    entries, path = find_map_objects(tree)
    if not entries:
        log("[X] 没有读出任何 MapObjectSaveData 记录。")
        log("    可能原因:")
        log("      1) 该存档版本将这部分数据存在未被解码的 RawData 里")
        log("         (0.3.7+ 的内存优化格式)。脚本默认已启用解码器，")
        log("         若仍失败说明确实是新格式，请把报告发我。")
        log("      2) 存档太老，字段路径不同 -> 跑 pw_sav_probe.py 看键名")
        report["map_objects"] = {"found": False, "path_tried": MAP_OBJECT_DATA_PATH}
    else:
        log(f"[+] 从 {path} 读出 {len(entries)} 条记录")
        summary = summarize_entry(entries)
        report["map_objects"] = {"found": True, "path": path, **summary}

        log("")
        log(f"  首条记录字段: {summary.get('top_level_keys')}")
        log(f"  不同建筑 ID  : {summary['distinct_map_object_ids']} 种")
        log(f"  含 Model     : {summary['with_Model']} 条")
        log(f"  含 Transform : {summary['with_initital_transform_cache']} 条   <-- 关键指标")
        if summary.get("problems"):
            log(f"  异常         : {summary['problems']}")

        log("")
        log("  --- 出现最多的建筑 ID (前 25) ---")
        for name, cnt in summary.get("top_ids", []):
            log(f"    {cnt:>6}  {name}")

        sample_path = os.path.join(out_dir, "sample_map_object.json")
        if dump_one_entry(entries, sample_path):
            log("")
            log(f"[+] 首条完整记录已写出: {sample_path}")

        if summary["with_initital_transform_cache"] > 0:
            log("")
            log("  ==> 结论: 建筑记录同时包含 建筑ID 与 Transform，")
            log("      离线导出蓝图 这条路 【成立】。")
        else:
            log("")
            log("  ==> 结论: 拿到了记录，但 Transform 没读出来，需要进一步排查。")

    # ---- 5d. 全量导出 ------------------------------------------------------
    if dump_full:
        section("阶段 E: 全量 JSON 导出")
        full_path = os.path.join(out_dir, "level_full.json")
        try:
            with open(full_path, "w", encoding="utf-8") as fh:
                json.dump(tree, fh, ensure_ascii=False, indent=1, default=str)
            log(f"[+] 已写出 {full_path} ({human(os.path.getsize(full_path))})")
            log("    注意: 这个文件很大，不要整个贴给我，用 grep 或切片看。")
            report["full_dump"] = full_path
        except Exception as exc:
            log(f"[X] 全量导出失败: {err_text(exc)}")

    return report


def main() -> int:
    ap = argparse.ArgumentParser(description="Palworld 存档侦察工具 (阶段 0)")
    ap.add_argument("--save", help="直接指定 Level.sav 的完整路径")
    ap.add_argument("--list", action="store_true", help="只列出找到的存档然后退出")
    ap.add_argument("--dump-full", action="store_true", help="额外导出完整 JSON")
    ap.add_argument(
        "--no-map-objects",
        action="store_true",
        help="不要强制启用 MapObjectSaveData 解析（默认是启用的）",
    )
    args = ap.parse_args()

    section("Palworld 蓝图模组 - 阶段 0 侦察")
    log(f"Python : {sys.version.split()[0]}  ({sys.executable})")
    log(f"时间   : {datetime.now():%Y-%m-%d %H:%M:%S}")

    if args.list:
        list_saves()
        return 0

    # 选存档
    save_path: str | None = args.save
    if not save_path:
        saves = find_saves()
        if not saves:
            list_saves()
            return 2
        # 优先非 backup 的正式存档
        primary = [s for s in saves if os.sep + "backup" + os.sep not in s[2]]
        chosen = (primary or saves)[0]
        save_path = os.path.join(SAVE_ROOT, chosen[2])
        log("")
        log(f"自动选择存档: {chosen[2]}")
        log(f"  (共找到 {len(saves)} 个 Level.sav，用 --list 查看全部)")

    if not os.path.isfile(save_path):
        log(f"[X] 文件不存在: {save_path}")
        return 2

    os.makedirs(WORK_DIR, exist_ok=True)
    out_dir = WORK_DIR
    log(f"报告目录: {out_dir}")

    with open(save_path, "rb") as fh:
        raw = fh.read()

    report: dict = {"generated_at": datetime.now().isoformat(), "save": save_path}

    if args.no_map_objects:
        log("[i] 按参数要求跳过 MapObjectSaveData 解码器注册")

    gvas, diag = load_save(save_path, raw, skip_map_objects=args.no_map_objects)
    report["load"] = diag

    if gvas is not None:
        try:
            report["analysis"] = analyse(gvas, out_dir, args.dump_full)
        except Exception as exc:
            log(f"[X] 结构分析时异常: {err_text(exc)}")
            report["analysis_error"] = traceback.format_exc()
    else:
        log("")
        log("解析未成功，回退到自包含解析器:")
        log("    python pw_sav_probe.py")

    report_path = os.path.join(out_dir, "recon_report.json")
    try:
        with open(report_path, "w", encoding="utf-8") as fh:
            json.dump(report, fh, ensure_ascii=False, indent=2, default=str)
        section("完成")
        log(f"报告已写出: {report_path}")
        log("")
        log("请把这个文件的内容发给我 (或只发其中 analysis 部分)。")
        log("如果它很大，先执行: python pw_recon.py --list 并告诉我档期最新的那个。")
    except Exception as exc:
        log(f"[X] 写报告失败: {err_text(exc)}")

    return 0 if gvas is not None else 1


if __name__ == "__main__":
    sys.exit(main())
