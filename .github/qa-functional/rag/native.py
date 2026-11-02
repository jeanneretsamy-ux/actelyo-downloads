"""Native Windows helpers for the Actelyo RAG functional QA.

Drives what Playwright (CDP) cannot reach: the Electron native menu bar,
the Windows common file dialogs and the message boxes. Prints one JSON object
on stdout. Every step takes a full-desktop screenshot.
"""
import argparse
import io
import json
import os
import sys
import time
import traceback

from PIL import ImageGrab
from pywinauto import Desktop, keyboard
from pywinauto.findwindows import ElementNotFoundError

LOG = []


def log(msg):
    LOG.append(f"{time.strftime('%H:%M:%S')} {msg}")
    print(msg, file=sys.stderr, flush=True)


def shot(shots, name):
    path = os.path.join(shots, name)
    try:
        ImageGrab.grab(all_screens=True).save(path)
        log(f"screenshot {name}")
        return name
    except Exception as exc:  # noqa: BLE001
        log(f"screenshot {name} failed: {exc}")
        return None


def as_spec(w):
    """Turn a wrapper into a WindowSpecification so child_window() works."""
    try:
        h = w.handle
        if h:
            return Desktop(backend="uia").window(handle=h)
    except Exception:  # noqa: BLE001
        pass
    return w


def find_window(title, timeout=30, exact=True):
    deadline = time.time() + timeout
    desk = Desktop(backend="uia")
    while time.time() < deadline:
        try:
            for w in desk.windows():
                t = w.window_text()
                if (t == title) if exact else (title in t):
                    return as_spec(w)
                # Dialogs owned by the Electron window are exposed as its children.
                if w.window_text() == "Actelyo RAG":
                    for c in w.children(control_type="Window"):
                        ct = c.window_text()
                        if (ct == title) if exact else (title in ct):
                            return as_spec(c)
        except Exception:  # noqa: BLE001
            pass
        time.sleep(0.5)
    raise TimeoutError(f"window not found: {title}")


def dump_tree(win, depth=3):
    out = []

    def walk(el, d):
        try:
            info = el.element_info
            out.append("  " * d + f"[{info.control_type}] name={info.name!r} auto_id={info.automation_id!r}")
        except Exception:  # noqa: BLE001
            return
        if d >= depth:
            return
        try:
            for c in el.children():
                walk(c, d + 1)
        except Exception:  # noqa: BLE001
            pass

    walk(win, 0)
    return out


def main_window():
    win = find_window("Actelyo RAG", timeout=60)
    try:
        win.set_focus()
    except Exception as exc:  # noqa: BLE001
        log(f"set_focus failed: {exc}")
    return win


def open_menu_item(win, top, index):
    """Open top-level menu `top` (Electron views menu bar) and choose its entry number `index` (1-based)."""
    rect = win.rectangle()
    target = None
    try:
        for el in win.descendants():
            info = el.element_info
            r = info.rectangle
            if info.name == top and info.control_type in ("MenuItem", "Button", "MenuBar", "Text") \
                    and r.top > rect.top + 15 and r.top < rect.top + 90 and (r.bottom - r.top) < 40:
                target = el
                LOG.append(f"menu target [{info.control_type}] {info.name!r} {r}")
                break
    except Exception as exc:  # noqa: BLE001
        log(f"descendants scan failed: {exc}")
    if target is not None:
        target.click_input()
        mode = "uia-click"
    else:
        # Fallback: the menu bar label sits just under the title bar, left aligned.
        from pywinauto import mouse
        x, y = max(rect.left, 0) + 36, max(rect.top, 0) + 35
        mouse.click(coords=(x, y))
        mode = f"coords-click({x},{y})"
    time.sleep(1.2)
    keyboard.send_keys("{DOWN}" * index)
    time.sleep(0.4)
    return mode


def fill_file_dialog(dlg, value, shots, shotname):
    edit = None
    for crit in ({"auto_id": "1148", "control_type": "Edit"},
                 {"control_type": "Edit", "found_index": 0}):
        try:
            cand = dlg.child_window(**crit)
            if cand.exists(timeout=5):
                edit = cand
                break
        except Exception:  # noqa: BLE001
            continue
    if edit is None:
        raise RuntimeError("file-name edit box not found:\n" + "\n".join(dump_tree(dlg, 4)))
    edit.set_focus()
    try:
        edit.set_edit_text(value)
    except Exception:  # noqa: BLE001
        keyboard.send_keys("^a{BACKSPACE}")
        keyboard.send_keys(value, with_spaces=True)
    time.sleep(0.5)
    shot(shots, shotname)
    try:
        btn = dlg.child_window(auto_id="1", control_type="Button")
        btn.click_input() if btn.exists(timeout=2) else keyboard.send_keys("{ENTER}")
    except Exception:  # noqa: BLE001
        keyboard.send_keys("{ENTER}")


def wait_closed(dlg, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if not dlg.exists(timeout=0.2):
                return True
        except Exception:  # noqa: BLE001
            return True
        time.sleep(0.5)
    return False


def texts_of(win):
    vals = []
    try:
        for d in win.descendants():
            t = d.window_text()
            if t and t not in vals:
                vals.append(t)
    except Exception:  # noqa: BLE001
        pass
    return vals


RES = {}


def legal_import(args):
    res = RES
    res.update({"ok": False, "screens": []})
    os.makedirs(args.outparent, exist_ok=True)
    win = main_window()
    try:
        win.maximize()
    except Exception:  # noqa: BLE001
        pass
    time.sleep(1)
    res["screens"].append(shot(args.shots, "40-legal-before-menu.png"))
    res["menuTree"] = dump_tree(win, 2)
    dlg = None
    for attempt in range(3):
        mode = open_menu_item(win, "Actelyo RAG", 2)  # entry 2 = "Préparer un corpus juridique…"
        res["menuMode"] = mode
        res["screens"].append(shot(args.shots, f"41-legal-menu-open-{attempt}.png"))
        keyboard.send_keys("{ENTER}")
        try:
            dlg = find_window("Choisir un corpus juridique JSON autorisé", timeout=15)
            break
        except TimeoutError:
            log(f"file dialog not shown after attempt {attempt}")
            keyboard.send_keys("{ESC}{ESC}")
            time.sleep(1)
            if attempt == 0:
                res["windowTree"] = dump_tree(win, 4)[:300]
    if dlg is None:
        raise TimeoutError("file dialog never opened from the menu")
    res["screens"].append(shot(args.shots, "42-legal-file-dialog.png"))
    fill_file_dialog(dlg, args.json, args.shots, "43-legal-file-chosen.png")
    if not wait_closed(dlg):
        raise RuntimeError("JSON file dialog did not close")
    dlg2 = find_window("Choisir le dossier où préparer les articles", timeout=30)
    res["screens"].append(shot(args.shots, "44-legal-folder-dialog.png"))
    fill_file_dialog(dlg2, args.outparent, args.shots, "45-legal-folder-chosen.png")
    if not wait_closed(dlg2, timeout=8):
        # Typing a folder path + Enter may only navigate into it: press Select Folder again.
        try:
            dlg2.child_window(auto_id="1", control_type="Button").click_input()
        except Exception:  # noqa: BLE001
            keyboard.send_keys("{ENTER}")
        if not wait_closed(dlg2, timeout=10):
            raise RuntimeError("folder dialog did not close")
    box = None
    for title in ("Corpus préparé", "Import impossible"):
        try:
            box = find_window(title, timeout=20 if title == "Corpus préparé" else 2)
            res["resultDialog"] = title
            break
        except TimeoutError:
            continue
    if box is None:
        raise RuntimeError("no result dialog after folder selection")
    time.sleep(0.8)
    res["screens"].append(shot(args.shots, "46-legal-result-dialog.png"))
    res["dialogTexts"] = texts_of(box)
    try:
        btn = box.child_window(title="Fermer", control_type="Button")
        btn.click_input() if btn.exists(timeout=3) else keyboard.send_keys("{ESC}")
    except Exception:  # noqa: BLE001
        keyboard.send_keys("{ESC}")
    if res["resultDialog"] == "Import impossible":
        try:
            box2 = find_window("Import impossible", timeout=2)
            box2.child_window(control_type="Button", found_index=0).click_input()
        except Exception:  # noqa: BLE001
            pass
    time.sleep(1)
    res["screens"].append(shot(args.shots, "47-legal-after-dialog.png"))
    outs = sorted(d for d in os.listdir(args.outparent) if d.startswith("articles-juridiques-"))
    res["outputs"] = outs
    if outs:
        out = os.path.join(args.outparent, outs[-1])
        res["outputDir"] = out
        with open(os.path.join(out, "manifest.json"), encoding="utf-8") as fh:
            res["manifest"] = json.load(fh)
        res["ok"] = res["resultDialog"] == "Corpus préparé"
    return res


def maximize(args):
    win = main_window()
    win.maximize()
    time.sleep(1)
    return {"ok": True, "screens": [shot(args.shots, args.name)]}


def screenshot(args):
    return {"ok": True, "screens": [shot(args.shots, args.name)]}


def main():
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8")
    p = argparse.ArgumentParser()
    p.add_argument("cmd")
    p.add_argument("--json")
    p.add_argument("--outparent")
    p.add_argument("--shots", required=True)
    p.add_argument("--name", default="desktop.png")
    args = p.parse_args()
    try:
        res = {"legal-import": legal_import, "screenshot": screenshot, "maximize": maximize}[args.cmd](args)
    except Exception as exc:  # noqa: BLE001
        res = dict(RES)
        res.update({"ok": False, "error": f"{type(exc).__name__}: {exc}", "trace": traceback.format_exc()})
        try:
            shot(args.shots, f"{args.cmd}-error.png")
            keyboard.send_keys("{ESC}")
        except Exception:  # noqa: BLE001
            pass
    res["log"] = LOG
    print(json.dumps(res, ensure_ascii=False))


if __name__ == "__main__":
    main()
