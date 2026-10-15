#!/usr/bin/env python3
"""Dashboard UI acceptance — every render path, in a real browser.

Covers:
  board (live server):  running / complete / blocked / no-prd states, the polling
                        loop picking up an on-disk change, timeline→story linking,
                        and the auto-refresh toggle
  snapshot (file://):   data actually embedded, no polling, no console errors
  fragment (in-session): the Gen UI fragment rendered against the host design system

Requires python3 + playwright (chromium). Without playwright the suite reports
SKIP instead of failing, so the shell suites stay runnable everywhere.

Usage: python3 tests/test-ui.py
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

TESTS = Path(__file__).resolve().parent
PLUGIN = TESTS.parent
FIX = Path(os.environ.get("RALPH_TEST_DIR", Path(tempfile.gettempdir()) / "ralph-plugin-tests"))
SHOTS = FIX / "shots"
SHOTS.mkdir(parents=True, exist_ok=True)

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    print("SKIP  未安装 playwright（pip install playwright && playwright install chromium）")
    print("结果: SKIP")
    raise SystemExit(2)

results, console_errors = [], []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(("PASS  " if ok else "FAIL  ") + name + (("  — " + str(detail)) if detail else ""))


def sh(*args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw)


def build_fixtures():
    for state in ("running", "complete", "blocked"):
        sh("bash", str(TESTS / "make-fixture.sh"), state)
    (FIX / "degraded" / "noprj").mkdir(parents=True, exist_ok=True)


def flip_story(project, story_id):
    """Rewrite prd.json on disk, the way an iteration's step 9 would."""
    src = Path(project) / "prd.json"
    tmp = Path(project) / "prd.json.new"
    with open(src) as fin, open(tmp, "w") as fout:
        subprocess.run(["jq", f'(.userStories[]|select(.id=="{story_id}")|.passes)=true', "-c"],
                       stdin=fin, stdout=fout, check=True)
    tmp.replace(src)


class Server:
    def __init__(self, project, port):
        self.port = port
        self.proc = subprocess.Popen(
            [sys.executable, str(PLUGIN / "dashboard" / "serve.py"), "--dir", project, "--port", str(port)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.url = f"http://127.0.0.1:{port}/"
        for _ in range(80):
            try:
                urllib.request.urlopen(self.url + "healthz", timeout=1).read()
                return
            except Exception:
                if self.proc.poll() is not None:
                    raise SystemExit("server died:\n" + (self.proc.stdout.read() or ""))
                time.sleep(0.1)
        raise SystemExit("server did not come up")

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def api(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=10) as r:
        return r.read().decode()


def attach(page, tag):
    page.on("console", lambda m, t=tag: console_errors.append(f"[{t}] {m.type}: {m.text}")
            if m.type in ("error", "warning") else None)
    page.on("pageerror", lambda e, t=tag: console_errors.append(f"[{t}] pageerror: {e}"))


def board_case(pw, state, project, port, expect, shot, dark=False, live=None):
    srv = Server(project, port)
    page = pw.chromium.launch().new_page(viewport={"width": 1560, "height": 1100},
                                         color_scheme="dark" if dark else "light")
    attach(page, state)
    page.goto(srv.url, wait_until="load")
    page.wait_for_timeout(700)

    body = page.inner_text("body")
    for needle in expect.get("text", []):
        check(f"看板({state}): 包含 {needle!r}", needle in body)
    for sel, cnt in expect.get("selectors", {}).items():
        n = page.locator(sel).count()
        if cnt == "any":
            check(f"看板({state}): {sel} 至少一个", n > 0, f"实际 {n}")
        else:
            check(f"看板({state}): {sel} == {cnt}", n == cnt, f"实际 {n}")

    embedded = page.eval_on_selector("#state", "el => el.textContent.trim().slice(0, 20)")
    check(f"看板({state}): 初始状态已注入", embedded.startswith("{"), embedded)
    st = json.loads(api(port, "/api/state"))
    check(f"看板({state}): /api/state 结构完整", st.get("schema") == 1 and "loop" in st and "prd" in st)

    if live:
        before = page.inner_text(live["watch"])
        live["mutate"]()
        changed = False
        for _ in range(14):                      # poll interval is 2s
            page.wait_for_timeout(500)
            if page.inner_text(live["watch"]) != before:
                changed = True
                break
        after = page.inner_text(live["watch"])
        check(f"看板({state}): 磁盘变化后自动刷新（{before!r} → {after!r}）",
              changed and live["expect"] in after)
        for extra in live.get("also_expect", []):
            check(f"看板({state}): 阶段推进到 {extra!r}", extra in page.inner_text("body"))

    if page.locator(".tl").count():
        page.locator(".tl").first.click()
        page.wait_for_timeout(250)
        check(f"看板({state}): 点时间线不报错", True)
    page.locator("#auto").click(); page.wait_for_timeout(150)
    off = page.locator("#auto").get_attribute("aria-pressed")
    page.locator("#auto").click(); page.wait_for_timeout(150)
    on = page.locator("#auto").get_attribute("aria-pressed")
    check(f"看板({state}): 自动刷新开关切换", off == "false" and on == "true", f"{off}->{on}")

    page.screenshot(path=str(SHOTS / shot), full_page=True)
    page.context.browser.close()
    srv.stop()


def folds_case(pw, project, port):
    """Regressions for the reported folding/overflow bugs.

    The board re-reads the disk every 2s. Rebuilding its DOM on every poll used to
    (a) slam any fold the user opened back shut, and (b) drop a click that landed
    mid-rebuild. Panels were not collapsible at all, and long unbroken 备注 text
    overflowed the card and widened the page.
    """
    srv = Server(project, port)
    page = pw.chromium.launch().new_page(viewport={"width": 1560, "height": 1100})
    attach(page, "folds")
    page.goto(srv.url, wait_until="load")
    page.wait_for_timeout(700)

    # -- panels are collapsible ------------------------------------------------
    panels = page.locator("details[data-fold-key^='panel:']")
    check("折叠: 面板可折叠且数量充足", panels.count() >= 5, f"{panels.count()} 个")
    board = page.locator("[data-fold-key='panel:board']")
    board.locator("> summary").click(); page.wait_for_timeout(250)
    check("折叠: 任务看板可收起", board.evaluate("el => el.open") is False)
    board.locator("> summary").click(); page.wait_for_timeout(250)
    check("折叠: 任务看板可再展开", board.evaluate("el => el.open") is True)

    # -- an opened story fold survives idle polling ----------------------------
    fold = page.locator(".story").first.locator("details").first
    fold.locator("> summary").click(); page.wait_for_timeout(200)
    check("折叠: 验收标准可展开", fold.evaluate("el => el.open") is True)
    page.wait_for_timeout(2800)                       # > one poll cycle
    check("折叠: 空转轮询不会收起已展开的验收标准", fold.evaluate("el => el.open") is True)

    # -- the DOM is not rebuilt while the data is unchanged --------------------
    page.evaluate("() => { window.__probe = document.querySelector('.story details'); }")
    page.wait_for_timeout(2800)
    same = page.evaluate("() => document.querySelector('.story details') === window.__probe")
    check("折叠: 数据未变时不重建 DOM（否则点击会丢）", same is True)

    # -- an opened fold survives a real re-render ------------------------------
    target = page.locator(".story").nth(1).locator("details").first
    if target.evaluate("el => el.open"):
        target.locator("> summary").click(); page.wait_for_timeout(200)
    target.locator("> summary").click(); page.wait_for_timeout(250)
    key = target.get_attribute("data-fold-key")
    check("折叠: 目标已展开（前置）", target.evaluate("el => el.open") is True, key)

    src = Path(project) / "prd.json"
    data = json.loads(src.read_text(encoding="utf-8"))
    pending = [s for s in data["userStories"] if not s["passes"]]
    if pending:
        pending[0]["passes"] = True
        src.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        done_before = len([s for s in data["userStories"] if s["passes"]])
        for _ in range(16):
            page.wait_for_timeout(500)
            if page.locator(".story.done").count() >= done_before:
                break
        check("折叠: 数据变化确实触发了重渲染",
              page.locator(".story.done").count() >= done_before,
              f"done={page.locator('.story.done').count()}")
        still = page.locator(f"[data-fold-key='{key}']").evaluate("el => el.open")
        check("折叠: 重渲染后用户展开的折叠仍保持展开", still is True, f"{key} open={still}")

    # -- long unbroken text stays inside the card ------------------------------
    ov = page.evaluate("""() => {
      const bad = [];
      document.querySelectorAll('.story').forEach(card => {
        const cb = card.getBoundingClientRect();
        card.querySelectorAll('.row span:last-child, .desc, ul.ac li, .files li').forEach(el => {
          const r = el.getBoundingClientRect();
          if (r.width && (r.right > cb.right + 0.5 || r.left < cb.left - 0.5))
            bad.push((el.textContent || '').slice(0, 40));
        });
      });
      return { bad, pageOverflow: document.documentElement.scrollWidth - window.innerWidth };
    }""")
    check("折叠: 长备注不越出卡片边框", len(ov["bad"]) == 0, f"{len(ov['bad'])} 处越界: {ov['bad'][:2]}")
    check("折叠: 页面无横向溢出", ov["pageOverflow"] <= 1, f"{ov['pageOverflow']}px")

    page.screenshot(path=str(SHOTS / "board-folds.png"), full_page=True)
    page.context.browser.close()
    srv.stop()


def find_visualize_css():
    override = os.environ.get("RALPH_VISUALIZE_CSS")
    if override and Path(override).exists():
        return Path(override)
    for p in sorted(Path.home().glob(".zcode/cli/plugins/cache/*/visualize/*/skills/visualize/assets/visualize.css")):
        return p
    return None


FALLBACK_CSS = """
:root{--background:#fff;--foreground:#171a1d;--muted:#eef1f5;--muted-foreground:#6a7280;--card:#fff;
--border:#e2e5ea;--primary:#3d7fc4;--primary-foreground:#fff;--blue:#3d7fc4;--green:#2e8f57;--yellow:#a9770a;
--font-size-base:14px;color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--background:#14171a;--foreground:#e6e9ed;--muted:#262b31;
--muted-foreground:#9aa3af;--card:#1b1f23;--border:#2b3138;--blue:#6aa9e0;--green:#5fbb85;--yellow:#d9ab4a}}
body{background:var(--background);color:var(--foreground);font-size:var(--font-size-base)}
.card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:.75rem}
.viz-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:.75rem}
.viz-stat-value{font-size:1.25rem;font-weight:500}
.text-small{font-size:.857em}.text-muted{color:var(--muted-foreground)}
.text-end{text-align:end}.text-nowrap{white-space:nowrap}.tabular-nums{font-variant-numeric:tabular-nums}
.table{width:100%;border-collapse:collapse}.table td,.table th{text-align:left;padding:.35rem .5rem;border-bottom:1px solid var(--border)}
.table-sm td,.table-sm th{padding:.2rem .5rem}
"""


def fragment_preview(fragment, out):
    css_path = find_visualize_css()
    css = css_path.read_text(encoding="utf-8") if css_path else FALLBACK_CSS
    frag = fragment.read_text(encoding="utf-8")
    out.write_text(f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>fragment preview</title>
<style>{css}</style>
<style>html,body{{margin:0}}body{{box-sizing:border-box;padding:1rem;background:var(--background);color:var(--foreground)}}</style>
</head><body>
{frag}
</body></html>
""", encoding="utf-8")
    return css_path


def snapshot_and_fragment(pw):
    dash = str(PLUGIN / "scripts" / "ralph-dashboard.sh")
    for state in ("running", "blocked"):
        sh("bash", dash, "--snapshot", str(FIX / f"snap-{state}.html"), "--dir", str(FIX / f"proj-{state}"))
    sh("bash", dash, "--inline-fragment", str(FIX / "fragment.html"), "--dir", str(FIX / "proj-running"))

    browser = pw.chromium.launch()
    for state, expects in (("running", ["3 / 4", "收尾", "快照"]), ("blocked", ["已卡住", "BLOCKER", "第 2 次"])):
        page = browser.new_page(viewport={"width": 1500, "height": 1000})
        attach(page, f"snap-{state}")
        page.goto((FIX / f"snap-{state}.html").as_uri(), wait_until="load")
        page.wait_for_timeout(500)
        body = page.inner_text("body")
        for needle in expects:
            check(f"快照({state}): 包含 {needle!r}", needle in body)
        check(f"快照({state}): 故事卡 4 张", page.locator(".story").count() == 4)
        page.screenshot(path=str(SHOTS / f"snapshot-{state}.png"), full_page=True)
        page.close()

    preview = FIX / "fragment-preview.html"
    used = fragment_preview(FIX / "fragment.html", preview)
    print(f"      片段预览使用设计系统 CSS: {used or '(未找到 visualize.css，用内置回退样式)'}")
    for scheme in ("light", "dark"):
        page = browser.new_page(viewport={"width": 980, "height": 900},
                                color_scheme="dark" if scheme == "dark" else "light")
        attach(page, f"frag-{scheme}")
        page.goto(preview.as_uri(), wait_until="load")
        page.wait_for_timeout(450)
        check(f"片段({scheme}): 根节点存在", page.locator("#ralph-inline-view").count() == 1)
        check(f"片段({scheme}): 11 个流程节点", page.locator(".riv-node").count() == 11)
        check(f"片段({scheme}): 当前节点唯一", page.locator(".riv-node.active").count() == 1)
        check(f"片段({scheme}): 故事表 4 行", page.locator("#riv-stories tr").count() == 4)
        check(f"片段({scheme}): 时间线 3 段", page.locator("#riv-lane .riv-slot").count() == 3)
        txt = page.locator("#ralph-inline-view").inner_text()
        for needle in ("3 / 4", "US-003", "任务看板"):
            check(f"片段({scheme}): 包含 {needle!r}", needle in txt)
        page.screenshot(path=str(SHOTS / f"fragment-{scheme}.png"), full_page=True)
        page.close()
    browser.close()


def build_long_notes_fixture():
    """A project whose 备注 / 验收标准 contain pathological unbroken tokens, so the
    overflow rule is exercised rather than assumed."""
    proj = FIX / "proj-longnotes"
    sh("bash", str(TESTS / "make-fixture.sh"), "running", str(proj))
    src = proj / "prd.json"
    data = json.loads(src.read_text(encoding="utf-8"))
    url = ("https://intranet.example.com/very/long/path/without/any/break/opportunity/"
           "segment/abcdefghijklmnopqrstuvwxyz0123456789/another/segment/that/keeps/going")
    buckets = [
        "这条备注故意写得非常长，用来检验文字是否会顶出卡片边框。中文部分应当正常折行显示。",
        url,
        "混合内容：" + url + " 后面还有中文继续延伸以确认换行规则生效。",
    ]
    stories = data["userStories"]
    for s, note in zip(stories, buckets):
        s["notes"] = note
    # an unbroken token inside an acceptance criterion too
    if stories and stories[0].get("acceptanceCriteria"):
        stories[0]["acceptanceCriteria"] = list(stories[0]["acceptanceCriteria"]) + [
            "See " + url + " for the exact contract"
        ]
    src.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return proj


def multirun_case(pw, port):
    """A project that was run twice: iteration numbers restart at 1, so the timeline
    must show both runs instead of silently keeping only the later one."""
    proj = FIX / "proj-multirun"
    sh("bash", str(TESTS / "make-fixture.sh"), "multirun", str(proj))
    srv = Server(str(proj), port)
    page = pw.chromium.launch().new_page(viewport={"width": 1560, "height": 1100})
    attach(page, "multirun")
    page.goto(srv.url, wait_until="load")
    page.wait_for_timeout(700)

    # 6 iterations happened; a number-keyed timeline would collapse these to 4
    check("多次运行: 时间线渲染 6 轮（不是被覆盖后的 4）", page.locator(".tl").count() == 6,
          f"实际 {page.locator('.tl').count()}")
    check("多次运行: 出现 2 个运行分组", page.locator(".tl-run-group").count() == 2,
          f"实际 {page.locator('.tl-run-group').count()}")
    check("多次运行: 第二次运行标注为当前", page.locator(".tl-run-head .tl-cur").count() == 1)
    heads = page.locator(".tl-run-head").all_inner_texts()
    check("多次运行: 两个运行分组都编号", all("运行" in h for h in heads), heads)
    hint = page.inner_text("#timeline-hint")
    check("多次运行: 标题点明次数与总轮数", "2 次运行" in hint and "6 轮" in hint, hint)
    body = page.inner_text("body")
    check("多次运行: 显示当前运行内轮次而非历史最大",
          "第 4 轮" in body and "第 4 次运行" not in body, "")
    check("多次运行: max 取当前运行（最多 100）", "最多 100" in body, "")

    page.screenshot(path=str(SHOTS / "board-multirun.png"), full_page=True)
    page.context.browser.close()
    srv.stop()


def main():
    build_fixtures()
    base = int(os.environ.get("RALPH_TEST_PORT", "7911"))
    with sync_playwright() as pw:
        board_case(pw, "running", str(FIX / "proj-running"), base, {
            "text": ["Ralph 看板", "MyApp", "2 / 4", "实现中", "US-003", "迭代时间线", "历史运行", "代码库经验", "有未提交改动"],
            "selectors": {".story": 4, ".node": 11, ".edge": 11, ".tl": 3, ".archive-run": 1,
                          ".story.running": 1, ".story.done": 2, ".node.active": 1},
        }, "board-running.png", live={
            "watch": "#kpis .kpi:nth-child(1) .v", "expect": "3 / 4", "also_expect": ["收尾"],
            "mutate": lambda: flip_story(FIX / "proj-running", "US-003"),
        })
        board_case(pw, "complete", str(FIX / "proj-complete"), base + 1, {
            "text": ["4 / 4", "全部完成"], "selectors": {".story.done": 4, ".story.todo": 0},
        }, "board-complete-dark.png", dark=True)
        board_case(pw, "blocked", str(FIX / "proj-blocked"), base + 2, {
            "text": ["已卡住", "BLOCKER", "第 2 次", "2 次尝试"], "selectors": {".story.blocked": 1},
        }, "board-blocked.png")
        board_case(pw, "no-prd", str(FIX / "degraded" / "noprj"), base + 3, {
            "text": ["还没有 prd.json", "/ralph-run", "prd.json not found"], "selectors": {".empty": "any"},
        }, "board-empty.png")
        folds_case(pw, str(build_long_notes_fixture()), base + 4)
        multirun_case(pw, base + 5)
        snapshot_and_fragment(pw)

    real = [e for e in console_errors if "favicon" not in e]
    print("\n--- 控制台/页面错误 ---")
    print("  无" if not real else "\n".join("  " + e for e in real))
    failed = [r for r in results if not r[1]]
    print(f"\n断言: {len(results) - len(failed)}/{len(results)} 通过")
    if failed or real:
        print("结果: FAIL")
        return 1
    print("结果: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
