#!/usr/bin/env bash
# Flow Kit — tạo project mới rồi chạy pipeline đến video cuối.
# Cách dùng: ./run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Thiếu lệnh: $1" >&2
    exit 1
  }
}

need python3
need curl
need ffmpeg
need ffprobe

export PYTHONUNBUFFERED=1
# Heredoc trên fd 3 — stdin (fd 0) vẫn là terminal để input() đọc được.
exec python3 /dev/fd/3 "$ROOT" 3<<'PY'
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
os.chdir(ROOT)

BASE = os.environ.get("FLOWKIT_BASE_URL", "http://127.0.0.1:8100").rstrip("/")
UUID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I
)
POLL_SHORT = 15
POLL_VIDEO = 30
MAX_STAGE_RETRIES = 2
OMNI_INFLIGHT = 5

VEO_PRESETS = {
    "1": {
        "id": "lite_lp",
        "label": "rẻ/chậm — VEO 3.1 Lite Low Priority (0 credit)",
        "t2_l": "veo_3_1_i2v_lite_low_priority",
        "t2_p": "veo_3_1_i2v_lite_low_priority",
        "t1_l": "veo_3_1_i2v_lite_low_priority",
        "t1_p": "veo_3_1_i2v_lite_low_priority",
    },
    "2": {
        "id": "lite",
        "label": "cân bằng — VEO 3.1 Lite (~5 credit/clip)",
        "t2_l": "veo_3_1_i2v_lite",
        "t2_p": "veo_3_1_i2v_lite",
        "t1_l": "veo_3_1_i2v_lite",
        "t1_p": "veo_3_1_i2v_lite",
    },
    "3": {
        "id": "ultra",
        "label": "đẹp — VEO 3.1 Fast Ultra (~10 credit/clip)",
        "t2_l": "veo_3_1_i2v_s_fast_ultra",
        "t2_p": "veo_3_1_i2v_s_fast_portrait_ultra",
        "t1_l": "veo_3_1_i2v_s_fast",
        "t1_p": "veo_3_1_i2v_s_fast_portrait",
    },
}

class ApiError(RuntimeError):
    def __init__(self, status: int, path: str, body: str):
        self.status = status
        self.path = path
        self.body = body
        super().__init__(f"HTTP {status} {path}: {body[:400]}")


def log(msg: str) -> None:
    print(f"[fk-pipeline] {msg}", flush=True)


def die(msg: str, code: int = 1) -> None:
    print(f"[fk-pipeline] LỖI: {msg}", file=sys.stderr, flush=True)
    raise SystemExit(code)


def read_line(prompt: str = "") -> str:
    """Đọc 1 dòng từ terminal thật, không phụ thuộc stdin của process."""
    if prompt:
        print(prompt, end="", flush=True)
    try:
        with open("/dev/tty", encoding="utf-8", errors="replace") as tty:
            line = tty.readline()
    except OSError:
        line = sys.stdin.readline()
    if line == "":
        die("Không đọc được terminal. Chạy ./run.sh trong một terminal tương tác.")
    return line.rstrip("\n\r")


def ask(prompt: str, required: bool = True, default: str | None = None) -> str:
    suffix = f" [{default}]" if default else ""
    while True:
        raw = read_line(f"{prompt}{suffix}: ").strip()
        if not raw and default is not None:
            return default
        if raw or not required:
            return raw
        print("  (bắt buộc)")


def ask_block(prompt: str, required: bool = True) -> str:
    print(f"{prompt}")
    print("  (gõ END trên một dòng để kết thúc)")
    lines: list[str] = []
    while True:
        line = read_line()
        if line.strip() == "END":
            text = "\n".join(lines).strip()
            if text or not required:
                return text
            print("  (bắt buộc — nhập lại, rồi END)")
            lines = []
            continue
        lines.append(line)


def ask_choice(prompt: str, options: dict[str, str], aliases: dict[str, str] | None = None) -> str:
    print(prompt)
    for key, label in options.items():
        print(f"  {key}) {label}")
    allowed = {k.lower(): k for k in options}
    if aliases:
        for a, k in aliases.items():
            allowed[a.lower()] = k
    while True:
        raw = ask("Chọn").lower()
        if raw in allowed:
            return allowed[raw]
        print(f"  Không hợp lệ. Chọn: {', '.join(options)}")


def extract_uuid(text: str) -> str:
    m = UUID_RE.search(text or "")
    return m.group(0).lower() if m else ""


def is_uuid(value: str | None) -> bool:
    return bool(value) and bool(re.fullmatch(UUID_RE, value or ""))


def api(method: str, path: str, body=None, query: dict | None = None, timeout: int = 180):
    url = BASE + path
    if query:
        url += "?" + urllib.parse.urlencode({k: v for k, v in query.items() if v is not None})
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            if not raw:
                return None
            return json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as e:
        err = e.read().decode("utf-8", "replace")
        raise ApiError(e.code, path, err) from None
    except urllib.error.URLError as e:
        die(f"Không kết nối được {BASE} ({e.reason}). Hãy chạy server Flow Kit trước.")


def preflight() -> None:
    try:
        health = api("GET", "/health")
    except ApiError as e:
        die(f"/health thất bại: {e}")
    if not health or not health.get("extension_connected"):
        die(
            "extension_connected != true. Mở Chrome, reload extension, "
            "và để một tab https://flow.google.com/ đã đăng nhập."
        )
    try:
        status = api("GET", "/api/flow/status")
    except ApiError as e:
        die(f"/api/flow/status thất bại: {e}")
    if status.get("transport") != "batch":
        log(f"Cảnh báo: transport={status.get('transport')!r} (kỳ vọng 'batch')")
    if not status.get("connected") and not status.get("flow_project_id"):
        log("Cảnh báo: flow status không có connected/flow_project_id")
    log("Preflight OK — extension đang kết nối")


def collect_inputs() -> dict:
    print()
    print("=== Flow Kit run.sh — tạo project mới đến video cuối ===")
    print("Tab https://flow.google.com/ phải đang mở và đã đăng nhập.")
    print()

    flow_raw = ask("FLOW_PROJECT_ID (uuid trên flow.google.com, dán URL cũng được)")
    flow_id = extract_uuid(flow_raw)
    if not flow_id:
        die("Không tìm thấy UUID trong FLOW_PROJECT_ID")

    ori_key = ask_choice(
        "Orientation",
        {"1": "VERTICAL (Shorts 9:16)", "2": "HORIZONTAL (YouTube 16:9)"},
        {"v": "1", "h": "2", "vertical": "1", "horizontal": "2"},
    )
    orientation = "VERTICAL" if ori_key == "1" else "HORIZONTAL"

    chain_key = ask_choice(
        "Cách gen video",
        {
            "1": "Từng scene độc lập (VEO i2v)",
            "2": "Scene chaining start+end frame (Omni Flash)",
        },
    )
    chain_videos = chain_key == "2"

    veo = None
    if chain_videos:
        log("Chaining → model_family=omni_flash (preset Veo bị bỏ qua)")
    else:
        veo_key = ask_choice(
            "Video model",
            {k: v["label"] for k, v in VEO_PRESETS.items()},
        )
        veo = VEO_PRESETS[veo_key]

    project_name = ask("Tên project")
    story = ask_block("Story (tiếng Việt)")

    try:
        materials = api("GET", "/api/materials") or []
    except ApiError as e:
        die(f"Không lấy được materials: {e}")
    if not materials:
        die("GET /api/materials trả về rỗng")
    mat_opts = {str(i + 1): m["id"] for i, m in enumerate(materials)}
    print("Material (style ảnh)")
    for i, m in enumerate(materials, 1):
        flag = "builtin" if m.get("is_builtin") else "custom"
        print(f"  {i}) {m['id']} — {m.get('name', '')} ({flag})")
    while True:
        raw = ask("Chọn material (số hoặc id)").strip()
        if raw in mat_opts:
            material = mat_opts[raw]
            break
        ids = {m["id"] for m in materials}
        if raw in ids:
            material = raw
            break
        print("  Không có material đó")

    print()
    print("=== Entity (nhân vật / địa điểm / props) ===")
    print("Gõ done ở tên để dừng. Được phép 0 mục.")
    entities: list[dict] = []
    while True:
        name = ask(f"Entity #{len(entities) + 1} name (tiếng Anh, alias — hoặc done)", required=False)
        if not name or name.lower() == "done":
            break
        etype_key = ask_choice(
            "entity_type",
            {"1": "character", "2": "location", "3": "visual_asset"},
            {
                "c": "1",
                "l": "2",
                "v": "3",
                "character": "1",
                "location": "2",
                "visual_asset": "3",
            },
        )
        etype = {"1": "character", "2": "location", "3": "visual_asset"}[etype_key]
        desc = ask_block("description (tiếng Anh, ngoại hình/không gian, 1 outfit)")
        entities.append({"name": name, "entity_type": etype, "description": desc})
        print(f"  + {etype}: {name}")

    print()
    print("=== Scenes ===")
    print("prompt + video_prompt bằng English. Gõ done ở prompt để dừng.")
    scenes: list[dict] = []
    while True:
        n = len(scenes) + 1
        prompt = ask_block(f"Scene {n} prompt (action + môi trường + mood, English — hoặc done)", required=False)
        if not prompt or prompt.lower() == "done":
            break
        video_prompt = ask_block(
            f"Scene {n} video_prompt (8s: 0-3s / 3-6s / 6-8s, English)"
        )
        names: list[str] = []
        if entities:
            print("character_names — entity nào xuất hiện trong scene này?")
            for i, e in enumerate(entities, 1):
                print(f"  {i}) {e['name']} ({e['entity_type']})")
            raw_names = ask("Số (vd 1,3) hoặc tên, trống = không ref", required=False)
            if raw_names:
                by_i = {str(i): e["name"] for i, e in enumerate(entities, 1)}
                by_n = {e["name"].lower(): e["name"] for e in entities}
                for part in re.split(r"[,\n]+", raw_names):
                    p = part.strip()
                    if not p:
                        continue
                    if p in by_i:
                        names.append(by_i[p])
                    elif p.lower() in by_n:
                        names.append(by_n[p.lower()])
                    else:
                        print(f"  Bỏ qua tên không khớp: {p}")
        chain_key = ask_choice(
            f"Scene {n} chain_type (ảnh)",
            {"1": "ROOT (độc lập / đầu chain)", "2": "CONTINUATION (EDIT_IMAGE từ scene cha)"},
            {"root": "1", "continuation": "2", "c": "2", "r": "1"},
        )
        chain_type = "ROOT" if chain_key == "1" else "CONTINUATION"
        parent_index = None
        if chain_type == "CONTINUATION":
            if not scenes:
                print("  Scene đầu không thể CONTINUATION — đổi thành ROOT")
                chain_type = "ROOT"
            else:
                print("parent_scene:")
                for i, s in enumerate(scenes, 1):
                    print(f"  {i}) {s['prompt'][:80].replace(chr(10), ' ')}")
                while True:
                    raw = ask("Số scene cha")
                    if raw.isdigit() and 1 <= int(raw) <= len(scenes):
                        parent_index = int(raw) - 1
                        break
                    print("  Số không hợp lệ")
        scenes.append({
            "prompt": prompt,
            "video_prompt": video_prompt,
            "character_names": names,
            "chain_type": chain_type,
            "parent_index": parent_index,
        })
        print(f"  + scene {n} [{chain_type}]")

    if not scenes:
        die("Cần ít nhất 1 scene")

    return {
        "flow_id": flow_id,
        "orientation": orientation,
        "chain_videos": chain_videos,
        "veo": veo,
        "project_name": project_name,
        "story": story,
        "material": material,
        "entities": entities,
        "scenes": scenes,
    }


def print_summary(cfg: dict) -> None:
    print()
    print("========== TÓM TẮT ==========")
    print(f"FLOW_PROJECT_ID : {cfg['flow_id']}")
    print(f"orientation     : {cfg['orientation']}")
    if cfg["chain_videos"]:
        print("video           : Omni Flash (chaining first+last)")
        cont = sum(1 for s in cfg["scenes"] if s["chain_type"] == "CONTINUATION")
        if cont == 0:
            print("  ⚠ Không có CONTINUATION → Omni first-frame, không first+last")
    else:
        print(f"video           : {cfg['veo']['label']}")
    print(f"project         : {cfg['project_name']}")
    print(f"material        : {cfg['material']}")
    print(f"entities        : {len(cfg['entities'])}")
    for e in cfg["entities"]:
        print(f"  - [{e['entity_type']}] {e['name']}")
    print(f"scenes          : {len(cfg['scenes'])}")
    for i, s in enumerate(cfg["scenes"], 1):
        parent = ""
        if s["parent_index"] is not None:
            parent = f" ← scene {s['parent_index'] + 1}"
        names = ",".join(s["character_names"]) or "-"
        print(f"  {i:02d} [{s['chain_type']}]{parent} refs={names}")
        print(f"      {s['prompt'][:90].replace(chr(10), ' ')}")
    print("Không research / review / TTS / upscale / Telegram")
    print("Enter để chạy · Ctrl+C để hủy")
    read_line()


def apply_video_model(veo: dict) -> None:
    body = {
        "video_models": {
            "PAYGATE_TIER_TWO": {
                "frame_2_video": {
                    "VIDEO_ASPECT_RATIO_LANDSCAPE": veo["t2_l"],
                    "VIDEO_ASPECT_RATIO_PORTRAIT": veo["t2_p"],
                },
                "start_end_frame_2_video": {
                    "VIDEO_ASPECT_RATIO_LANDSCAPE": veo["t2_l"],
                    "VIDEO_ASPECT_RATIO_PORTRAIT": veo["t2_p"],
                },
            },
            "PAYGATE_TIER_ONE": {
                "frame_2_video": {
                    "VIDEO_ASPECT_RATIO_LANDSCAPE": veo["t1_l"],
                    "VIDEO_ASPECT_RATIO_PORTRAIT": veo["t1_p"],
                },
                "start_end_frame_2_video": {
                    "VIDEO_ASPECT_RATIO_LANDSCAPE": veo["t1_l"],
                    "VIDEO_ASPECT_RATIO_PORTRAIT": veo["t1_p"],
                },
            },
        }
    }
    api("PATCH", "/api/models", body)
    log(f"Đã set video model: {veo['label']}")


def create_project_video_scenes(cfg: dict) -> tuple[str, str, str, str]:
    flow_id = cfg["flow_id"]
    try:
        existing = api("GET", f"/api/projects/{flow_id}")
    except ApiError as e:
        if e.status != 404:
            die(f"GET project: {e}")
        existing = None

    if existing:
        die(
            f"Project local đã tồn tại với UUID {flow_id} ({existing.get('name')}). "
            "Tạo project mới trên flow.google.com rồi dùng uuid khác."
        )

    body = {
        "name": cfg["project_name"],
        "story": cfg["story"],
        "description": cfg["story"][:500],
        "language": "vi",
        "material": cfg["material"],
        "flow_project_id": flow_id,
    }
    if cfg["entities"]:
        body["characters"] = cfg["entities"]
    try:
        project = api("POST", "/api/projects", body)
    except ApiError as e:
        die(f"Tạo project thất bại: {e}")
    pid = project["id"]
    log(f"Project: {pid}  {project.get('name')}")

    video = api("POST", "/api/videos", {
        "project_id": pid,
        "title": cfg["project_name"],
        "display_order": 0,
        "orientation": cfg["orientation"],
    })
    vid = video["id"]
    log(f"Video: {vid}")

    created: list[dict] = []
    for i, spec in enumerate(cfg["scenes"]):
        payload = {
            "video_id": vid,
            "display_order": i,
            "prompt": spec["prompt"],
            "video_prompt": spec["video_prompt"],
            "chain_type": spec["chain_type"],
        }
        if spec["character_names"]:
            payload["character_names"] = spec["character_names"]
        if spec["parent_index"] is not None:
            payload["parent_scene_id"] = created[spec["parent_index"]]["id"]
        scene = api("POST", "/api/scenes", payload)
        created.append(scene)
        log(f"Scene {i:03d} {scene['id'][:8]} [{spec['chain_type']}]")

    out = api("GET", f"/api/projects/{pid}/output-dir")
    slug = out["slug"]
    outdir = ROOT / out["path"]
    outdir.mkdir(parents=True, exist_ok=True)
    log(f"Output: {outdir}")
    return pid, vid, slug, str(outdir)


def prefix(orientation: str) -> str:
    return "vertical" if orientation == "VERTICAL" else "horizontal"


def submit_batch(requests: list[dict]) -> list:
    if not requests:
        return []
    return api("POST", "/api/requests/batch", {"requests": requests}) or []


def poll_batch(label: str, query: dict, interval: int, timeout_s: int) -> dict:
    started = time.time()
    stalled_since = None
    cycle = 0
    while True:
        cycle += 1
        st = api("GET", "/api/requests/batch-status", query=query)
        total = st.get("total") or 0
        pending = st.get("pending") or 0
        processing = st.get("processing") or 0
        completed = st.get("completed") or 0
        failed = st.get("failed") or 0
        log(
            f"{label} cycle {cycle}: "
            f"{completed}/{total} done, {processing} processing, {pending} pending, {failed} failed"
        )
        if st.get("done"):
            return st
        if pending > 0 and processing == 0:
            if stalled_since is None:
                stalled_since = time.time()
            elif time.time() - stalled_since >= 120:
                log("Cảnh báo: worker có vẻ stalled (pending>0, processing=0 ≥ 2 phút)")
                stalled_since = time.time()
        else:
            stalled_since = None
        if time.time() - started > timeout_s:
            die(f"{label} timeout sau {timeout_s}s")
        time.sleep(interval)


def stage_refs(pid: str) -> None:
    chars = api("GET", f"/api/projects/{pid}/characters") or []
    missing = [c for c in chars if not is_uuid(c.get("media_id"))]
    if not chars:
        log("Không có entity — bỏ qua refs")
        return
    if not missing:
        log(f"Refs: {len(chars)}/{len(chars)} đã có media_id")
        return

    for attempt in range(1, MAX_STAGE_RETRIES + 1):
        todo = [c for c in (api("GET", f"/api/projects/{pid}/characters") or []) if not is_uuid(c.get("media_id"))]
        if not todo:
            break
        req_type = "GENERATE_CHARACTER_IMAGE" if attempt == 1 else "REGENERATE_CHARACTER_IMAGE"
        log(f"Refs attempt {attempt}: submit {len(todo)} {req_type}")
        submit_batch([
            {"type": req_type, "character_id": c["id"], "project_id": pid}
            for c in todo
        ])
        poll_batch(
            "REFS",
            {"project_id": pid, "type": req_type},
            POLL_SHORT,
            timeout_s=30 * 60,
        )

    chars = api("GET", f"/api/projects/{pid}/characters") or []
    bad = [c for c in chars if not is_uuid(c.get("media_id"))]
    if bad:
        names = ", ".join(c.get("name", c["id"][:8]) for c in bad)
        die(f"Ref image thất bại sau retry: {names}")
    log(f"Refs: {len(chars)}/{len(chars)} ✓")


def image_waves(scenes: list[dict]) -> list[list[dict]]:
    by_id = {s["id"]: s for s in scenes}
    depth: dict[str, int] = {}

    def of(sid: str, stack: tuple[str, ...] = ()) -> int:
        if sid in depth:
            return depth[sid]
        if sid in stack:
            die(f"cycle parent_scene_id tại {sid}")
        s = by_id.get(sid) or {}
        parent = s.get("parent_scene_id")
        if s.get("chain_type") != "CONTINUATION" or not parent:
            depth[sid] = 0
            return 0
        depth[sid] = of(parent, stack + (sid,)) + 1
        return depth[sid]

    for s in scenes:
        of(s["id"])
    buckets: dict[int, list[dict]] = {}
    for s in scenes:
        buckets.setdefault(depth[s["id"]], []).append(s)
    return [buckets[k] for k in sorted(buckets)]


def stage_images(pid: str, vid: str, orientation: str) -> None:
    pfx = prefix(orientation)
    scenes = api("GET", "/api/scenes", query={"video_id": vid}) or []
    pending = [
        s for s in scenes
        if s.get(f"{pfx}_image_status") != "COMPLETED" or not is_uuid(s.get(f"{pfx}_image_media_id"))
    ]
    if not pending:
        log(f"Images: {len(scenes)}/{len(scenes)} ✓")
        return

    pending_ids = {s["id"] for s in pending}
    for wi, wave in enumerate(image_waves(scenes), 1):
        wave = [s for s in wave if s["id"] in pending_ids]
        if not wave:
            continue
        req_type = "GENERATE_IMAGE" if wi == 1 else "EDIT_IMAGE"
        for attempt in range(1, MAX_STAGE_RETRIES + 1):
            still = []
            fresh = api("GET", "/api/scenes", query={"video_id": vid}) or []
            by = {s["id"]: s for s in fresh}
            for s in wave:
                cur = by[s["id"]]
                if cur.get(f"{pfx}_image_status") == "COMPLETED" and is_uuid(cur.get(f"{pfx}_image_media_id")):
                    continue
                still.append(cur)
            if not still:
                break
            use_type = req_type if attempt == 1 else ("REGENERATE_IMAGE" if req_type == "GENERATE_IMAGE" else "EDIT_IMAGE")
            log(f"Images wave {wi} attempt {attempt}: {len(still)} {use_type}")
            submit_batch([
                {
                    "type": use_type,
                    "scene_id": s["id"],
                    "project_id": pid,
                    "video_id": vid,
                    "orientation": orientation,
                }
                for s in still
            ])
            poll_batch(
                f"IMAGES w{wi}",
                {"video_id": vid, "type": use_type, "orientation": orientation},
                POLL_SHORT,
                timeout_s=45 * 60,
            )

    scenes = api("GET", "/api/scenes", query={"video_id": vid}) or []
    bad = [
        s for s in scenes
        if s.get(f"{pfx}_image_status") != "COMPLETED" or not is_uuid(s.get(f"{pfx}_image_media_id"))
    ]
    if bad:
        ids = ", ".join(f"{s.get('display_order')}:{s['id'][:8]}" for s in bad)
        die(f"Scene image thất bại sau retry: {ids}")
    log(f"Images: {len(scenes)}/{len(scenes)} ✓")


def stage_videos_veo(pid: str, vid: str, orientation: str) -> None:
    pfx = prefix(orientation)
    scenes = api("GET", "/api/scenes", query={"video_id": vid}) or []
    pending = [s for s in scenes if s.get(f"{pfx}_video_status") != "COMPLETED"]
    if not pending:
        log(f"Videos: {len(scenes)}/{len(scenes)} ✓")
        return
    for attempt in range(1, MAX_STAGE_RETRIES + 1):
        fresh = api("GET", "/api/scenes", query={"video_id": vid}) or []
        still = [s for s in fresh if s.get(f"{pfx}_video_status") != "COMPLETED"]
        if not still:
            break
        log(f"Videos attempt {attempt}: submit {len(still)} GENERATE_VIDEO")
        submit_batch([
            {
                "type": "GENERATE_VIDEO",
                "scene_id": s["id"],
                "project_id": pid,
                "video_id": vid,
                "orientation": orientation,
            }
            for s in still
        ])
        poll_batch(
            "VIDEOS",
            {"video_id": vid, "type": "GENERATE_VIDEO", "orientation": orientation},
            POLL_VIDEO,
            timeout_s=max(45 * 60, 8 * 60 * len(still)),
        )
    scenes = api("GET", "/api/scenes", query={"video_id": vid}) or []
    bad = [s for s in scenes if s.get(f"{pfx}_video_status") != "COMPLETED"]
    if bad:
        ids = ", ".join(f"{s.get('display_order')}:{s['id'][:8]}" for s in bad)
        die(f"Video thất bại sau retry: {ids}")
    log(f"Videos: {len(scenes)}/{len(scenes)} ✓")


def _video_from_op(op: dict) -> tuple[str, str]:
    meta = ((op.get("operation") or {}).get("metadata") or {})
    video = meta.get("video") or {}
    media_id = video.get("mediaId") or video.get("media_id") or ""
    url = video.get("fifeUrl") or video.get("fife_url") or ""
    if not is_uuid(media_id) and url:
        media_id = extract_uuid(url)
    return media_id, url


def _op_status(op: dict) -> str:
    return (op.get("status") or "").upper()


def patch_scene_video(scene_id: str, orientation: str, media_id: str, url: str) -> None:
    pfx = prefix(orientation)
    api("PATCH", f"/api/scenes/{scene_id}", {
        f"{pfx}_video_media_id": media_id,
        f"{pfx}_video_url": url,
        f"{pfx}_video_status": "COMPLETED",
    })


def ensure_end_frames(vid: str, orientation: str) -> None:
    pfx = prefix(orientation)
    scenes = api("GET", "/api/scenes", query={"video_id": vid}) or []
    children: dict[str, dict] = {}
    for s in scenes:
        parent = s.get("parent_scene_id")
        if parent:
            children[parent] = s
    for s in scenes:
        child = children.get(s["id"])
        if not child:
            continue
        end_id = child.get(f"{pfx}_image_media_id")
        if not is_uuid(end_id):
            continue
        if s.get(f"{pfx}_end_scene_media_id") == end_id:
            continue
        api("PATCH", f"/api/scenes/{s['id']}", {f"{pfx}_end_scene_media_id": end_id})
        log(f"end_scene {s['id'][:8]} → {end_id[:8]}")


def omni_prompt(scene: dict, has_end: bool) -> str:
    if has_end and scene.get("transition_prompt"):
        return scene["transition_prompt"]
    return scene.get("video_prompt") or scene.get("prompt") or ""


def submit_omni(scene: dict, pid: str, orientation: str) -> dict:
    pfx = prefix(orientation)
    aspect = (
        "VIDEO_ASPECT_RATIO_PORTRAIT"
        if orientation == "VERTICAL"
        else "VIDEO_ASPECT_RATIO_LANDSCAPE"
    )
    start_id = scene.get(f"{pfx}_image_media_id")
    end_id = scene.get(f"{pfx}_end_scene_media_id") or None
    if end_id and not is_uuid(end_id):
        end_id = None
    body = {
        "model_family": "omni_flash",
        "start_image_media_id": start_id,
        "prompt": omni_prompt(scene, bool(end_id)),
        "project_id": pid,
        "scene_id": scene["id"],
        "duration_s": 8,
        "resolution": "720p",
        "aspect_ratio": aspect,
    }
    if end_id:
        body["end_image_media_id"] = end_id
    result = api("POST", "/api/flow/generate-video", body, timeout=180)
    polling = (result or {}).get("flowkitPolling") or {}
    ops = polling.get("operations") or (result or {}).get("operations") or []
    if not ops:
        raise RuntimeError(f"Omni không trả operations cho scene {scene['id'][:8]}: {result}")
    return {"scene": scene, "operations": ops, "tries": 1}


def stage_videos_omni(pid: str, vid: str, orientation: str) -> None:
    pfx = prefix(orientation)
    ensure_end_frames(vid, orientation)
    scenes = api("GET", "/api/scenes", query={"video_id": vid}) or []
    pending = [s for s in scenes if s.get(f"{pfx}_video_status") != "COMPLETED"]
    if not pending:
        log(f"Videos: {len(scenes)}/{len(scenes)} ✓")
        return

    queue = list(pending)
    inflight: list[dict] = []
    started = time.time()
    timeout_s = max(45 * 60, 10 * 60 * len(pending))

    while queue or inflight:
        if time.time() - started > timeout_s:
            die("Omni video timeout")
        while queue and len(inflight) < OMNI_INFLIGHT:
            scene = queue.pop(0)
            try:
                job = submit_omni(scene, pid, orientation)
                inflight.append(job)
                kind = "first+last" if scene.get(f"{pfx}_end_scene_media_id") else "first-frame"
                log(f"Omni submit scene {scene.get('display_order')} ({kind})")
            except (ApiError, RuntimeError) as e:
                log(f"Omni submit lỗi scene {scene.get('display_order')}: {e}")
                if scene.get("_retry", 0) < MAX_STAGE_RETRIES - 1:
                    scene["_retry"] = scene.get("_retry", 0) + 1
                    queue.append(scene)
                else:
                    die(f"Omni submit thất bại scene {scene['id']}")
            time.sleep(1)

        still = []
        for job in inflight:
            try:
                polled = api("POST", "/api/flow/check-status", {
                    "project_id": pid,
                    "operations": job["operations"],
                }, timeout=120)
            except ApiError as e:
                log(f"Omni poll lỗi: {e}")
                still.append(job)
                continue
            ops = (polled or {}).get("operations") or job["operations"]
            job["operations"] = ops
            op = ops[0] if ops else {}
            st = _op_status(op)
            if "SUCCESS" in st or "COMPLETE" in st:
                media_id, url = _video_from_op(op)
                if not url:
                    log(f"Omni scene {job['scene'].get('display_order')} xong nhưng chưa có URL — poll tiếp")
                    still.append(job)
                    continue
                if not is_uuid(media_id):
                    media_id = extract_uuid(url)
                patch_scene_video(job["scene"]["id"], orientation, media_id, url)
                log(f"Omni scene {job['scene'].get('display_order')} ✓")
            elif "FAIL" in st:
                scene = job["scene"]
                log(f"Omni scene {scene.get('display_order')} FAILED")
                if scene.get("_retry", 0) < MAX_STAGE_RETRIES - 1:
                    scene["_retry"] = scene.get("_retry", 0) + 1
                    queue.append(scene)
                else:
                    die(f"Omni video thất bại scene {scene['id']}")
            else:
                still.append(job)
        inflight = still
        if inflight or queue:
            n_done = len(scenes) - len(queue) - len(inflight)
            log(f"Omni {n_done}/{len(scenes)} done, {len(inflight)} in-flight, {len(queue)} queued")
            time.sleep(POLL_VIDEO)

    scenes = api("GET", "/api/scenes", query={"video_id": vid}) or []
    bad = [s for s in scenes if s.get(f"{pfx}_video_status") != "COMPLETED"]
    if bad:
        ids = ", ".join(f"{s.get('display_order')}:{s['id'][:8]}" for s in bad)
        die(f"Video Omni còn thiếu: {ids}")
    log(f"Videos: {len(scenes)}/{len(scenes)} ✓")


def download_file(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": "flowkit-run.sh"})
    with urllib.request.urlopen(req, timeout=300) as resp, open(tmp, "wb") as f:
        while True:
            chunk = resp.read(1024 * 256)
            if not chunk:
                break
            f.write(chunk)
    tmp.replace(dest)


def ffprobe_ok(path: Path) -> bool:
    r = subprocess.run(
        ["ffprobe", "-v", "quiet", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True,
    )
    try:
        return float((r.stdout or "0").strip() or "0") > 0
    except ValueError:
        return False


def has_audio(path: Path) -> bool:
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a",
         "-show_entries", "stream=codec_type", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True,
    )
    return "audio" in (r.stdout or "")


def probe_wh(path: Path) -> tuple[int, int]:
    r = subprocess.run(
        ["ffprobe", "-v", "quiet", "-select_streams", "v:0",
         "-show_entries", "stream=width,height", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True,
    )
    parts = (r.stdout or "").strip().split(",")
    if len(parts) != 2:
        return (1920, 1080)
    return int(parts[0]), int(parts[1])


def run_ffmpeg(args: list[str]) -> None:
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        die(f"ffmpeg thất bại:\n{r.stderr[-1500:]}")


def concat_final(pid: str, vid: str, orientation: str, slug: str, outdir: Path) -> Path:
    pfx = prefix(orientation)
    scenes = api("GET", "/api/scenes", query={"video_id": vid}) or []
    scenes = sorted(scenes, key=lambda s: s.get("display_order", 0))
    raw_dir = outdir / "4k"
    norm_dir = outdir / "norm"
    raw_dir.mkdir(parents=True, exist_ok=True)
    norm_dir.mkdir(parents=True, exist_ok=True)

    sources: list[Path] = []
    for s in scenes:
        idx = int(s.get("display_order") or 0)
        dest = raw_dir / f"scene_{idx:03d}_{s['id']}.mp4"
        url = s.get(f"{pfx}_upscale_url") or s.get(f"{pfx}_video_url")
        if dest.exists() and ffprobe_ok(dest):
            log(f"Download skip {dest.name} (đã có)")
        else:
            if not url:
                die(f"Scene {idx} không có video URL")
            log(f"Download scene {idx:03d}")
            try:
                download_file(url, dest)
            except Exception as e:
                die(f"Download scene {idx} thất bại: {e}")
            if not ffprobe_ok(dest):
                die(f"File scene {idx} hỏng / duration=0")
        sources.append(dest)

    w, h = probe_wh(sources[0])
    log(f"Normalize {w}x{h}")
    norm_files: list[Path] = []
    for src in sources:
        out = norm_dir / src.name
        vf = f"scale={w}:{h}:force_original_aspect_ratio=decrease,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2"
        if has_audio(src):
            run_ffmpeg([
                "ffmpeg", "-y", "-i", str(src),
                "-c:v", "libx264", "-preset", "fast", "-crf", "18",
                "-vf", vf, "-r", "24", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k",
                "-movflags", "+faststart", str(out),
            ])
        else:
            run_ffmpeg([
                "ffmpeg", "-y", "-i", str(src),
                "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                "-c:v", "libx264", "-preset", "fast", "-crf", "18",
                "-vf", vf, "-r", "24", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k", "-shortest",
                "-movflags", "+faststart", str(out),
            ])
        norm_files.append(out)

    concat_list = outdir / "concat.txt"
    concat_list.write_text("".join(f"file '{p.resolve()}'\n" for p in norm_files), encoding="utf-8")
    final = outdir / f"{slug}_final.mp4"
    run_ffmpeg([
        "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(concat_list),
        "-c", "copy", "-movflags", "+faststart", str(final),
    ])
    if not ffprobe_ok(final):
        die("File cuối hỏng")
    size_mb = final.stat().st_size / (1024 * 1024)
    dur = subprocess.run(
        ["ffprobe", "-v", "quiet", "-show_entries", "format=duration", "-of", "csv=p=0", str(final)],
        capture_output=True, text=True,
    ).stdout.strip()
    try:
        d = float(dur)
        dur_h = f"{int(d // 60)}:{int(d % 60):02d}"
    except ValueError:
        dur_h = dur
    log("========== XONG ==========")
    log(f"Output   : {final}")
    log(f"Duration : {dur_h}")
    log(f"Size     : {size_mb:.1f} MB")
    log(f"Scenes   : {len(scenes)}")
    log(f"Audio    : AAC (SFX gốc, không TTS)")
    return final


def main() -> None:
    preflight()
    cfg = collect_inputs()
    print_summary(cfg)
    if cfg["chain_videos"]:
        log("Video path: Omni Flash")
    else:
        apply_video_model(cfg["veo"])
    pid, vid, slug, outdir = create_project_video_scenes(cfg)
    orientation = cfg["orientation"]
    stage_refs(pid)
    stage_images(pid, vid, orientation)
    if cfg["chain_videos"]:
        stage_videos_omni(pid, vid, orientation)
    else:
        stage_videos_veo(pid, vid, orientation)
    concat_final(pid, vid, orientation, slug, Path(outdir))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[fk-pipeline] Đã hủy", file=sys.stderr)
        raise SystemExit(130)
PY
