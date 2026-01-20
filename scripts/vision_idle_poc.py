import argparse
import base64
import json
import time
import re
import requests
import subprocess
import tempfile
import os
from PIL import Image, ImageOps, ImageFilter, ImageEnhance
from typing import Any, Dict, List, Tuple

OLLAMA_URL = "http://localhost:11434"
QDRANT_URL = "http://localhost:6333"
VISION_MODEL = "moondream"
EMBED_MODEL = "nomic-embed-text"
COLLECTION_NAME = "pvt_memory"


def _extract_json(text: str) -> str:
    if "```" in text:
        parts = text.split("```")
        for p in parts:
            if "{" in p or "[" in p:
                text = p
                break
    start_obj = text.find("{")
    start_arr = text.find("[")
    if start_obj == -1 and start_arr == -1:
        return "{}"
    if start_arr == -1 or (start_obj != -1 and start_obj < start_arr):
        start = start_obj
    else:
        start = start_arr
    sliced = text[start:]
    end = sliced.rfind("}") if sliced.startswith("{") else sliced.rfind("]")
    if end == -1:
        return sliced
    return sliced[: end + 1]


def _ollama_generate(prompt: str, image_b64: str, num_predict: int = 512) -> str:
    payload = {
        "model": VISION_MODEL,
        "prompt": prompt,
        "stream": False,
        "images": [image_b64],
        "options": {"num_predict": num_predict, "temperature": 0.1},
    }
    resp = requests.post(f"{OLLAMA_URL}/api/generate", json=payload, timeout=600)
    resp.raise_for_status()
    return resp.json().get("response", "")


def _ollama_embed(text: str) -> List[float]:
    payload = {"model": EMBED_MODEL, "prompt": text}
    resp = requests.post(f"{OLLAMA_URL}/api/embeddings", json=payload, timeout=300)
    resp.raise_for_status()
    return resp.json().get("embedding", [])


def _qdrant_search(vector: List[float]) -> Tuple[float, Dict[str, Any]]:
    url = f"{QDRANT_URL}/collections/{COLLECTION_NAME}/points/search"
    resp = requests.post(url, json={"vector": vector, "limit": 1, "with_payload": True}, timeout=60)
    if resp.status_code == 404:
        return 0.0, {}
    resp.raise_for_status()
    result = resp.json().get("result", [])
    if not result:
        return 0.0, {}
    return float(result[0].get("score", 0.0)), result[0].get("payload", {})


def _qdrant_save(vector: List[float], payload: Dict[str, Any]) -> None:
    url = f"{QDRANT_URL}/collections/{COLLECTION_NAME}/points"
    point_id = int(time.time() * 1000)
    body = {"points": [{"id": point_id, "vector": vector, "payload": payload}]}
    resp = requests.put(url, json=body, timeout=60)
    if resp.status_code in (404, 400):
        return
    resp.raise_for_status()


def _normalize_goal(purpose: str, label: str) -> str:
    p = purpose.strip()
    if not p:
        return f"Use {label}"
    return p[:1].upper() + p[1:]


def _clean_label_list(labels: List[str]) -> List[str]:
    cleaned: List[str] = []
    for label in labels:
        l = label.strip().strip('"').strip("'")
        if not l:
            continue
        if len(l) < 4:
            continue
        if not re.search(r"[A-Za-z]", l):
            continue
        if re.fullmatch(r"[0-9\.]+", l):
            continue
        # drop likely mojibake artifacts
        if "â" in l or "�" in l:
            continue
        # drop tokens with too many digits
        digit_ratio = len(re.findall(r"\d", l)) / max(len(l), 1)
        if digit_ratio > 0.4:
            continue
        # drop tokens with too many non-alnum characters
        non_alnum = len(re.findall(r"[^A-Za-z0-9\s]", l))
        if non_alnum / max(len(l), 1) > 0.4:
            continue
        # drop tokens with trailing tildes or stray symbols
        if re.search(r"[~`^]", l):
            continue
        cleaned.append(l)
    # dedupe while preserving order
    seen = set()
    result: List[str] = []
    for l in cleaned:
        key = l.lower()
        if key in seen:
            continue
        seen.add(key)
        result.append(l)
    return result


def _run_tesseract_tsv(image_path: str) -> str:
    try:
        result = subprocess.run(
            ["tesseract", image_path, "stdout", "-l", "eng", "tsv"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            return ""
        return result.stdout
    except Exception:
        return ""


def _extract_ocr_labels_from_tsv(tsv_text: str) -> List[str]:
    labels: List[str] = []
    for line in tsv_text.splitlines():
        if line.startswith("level"):
            continue
        parts = line.split("\t")
        if len(parts) < 12:
            continue
        text = parts[11].strip()
        if not text:
            continue
        labels.append(text)
    # Normalize common OCR junk before final cleanup
    normalized: List[str] = []
    for item in labels:
        s = item.replace("\u2018", "'").replace("\u2019", "'")
        s = s.replace("\u201c", '"').replace("\u201d", '"')
        s = re.sub(r"\s+", " ", s).strip()
        s = s.strip("|[]{}()<>·•")
        if s:
            normalized.append(s)
    return _clean_label_list(normalized)


def _preprocess_tile(img: Image.Image, scale: int = 2) -> Image.Image:
    gray = img.convert("L")
    if scale > 1:
        gray = gray.resize((gray.width * scale, gray.height * scale), Image.BICUBIC)
    gray = ImageOps.autocontrast(gray)
    gray = ImageEnhance.Contrast(gray).enhance(1.6)
    gray = ImageEnhance.Sharpness(gray).enhance(1.5)
    gray = gray.filter(ImageFilter.MedianFilter(size=3))
    return gray


def _ocr_labels_from_image(img: Image.Image) -> List[str]:
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        tmp_path = tmp.name
    try:
        img.save(tmp_path)
        tsv = _run_tesseract_tsv(tmp_path)
        return _extract_ocr_labels_from_tsv(tsv)
    finally:
        try:
            os.remove(tmp_path)
        except Exception:
            pass


def _generate_rois(width: int, height: int) -> List[tuple]:
    left_w = int(width * 0.28)
    top_h = int(height * 0.18)
    return [
        ("full", (0, 0, width, height)),
        ("left_panel", (0, 0, left_w, height)),
        ("top_bar", (0, 0, width, top_h)),
        ("main", (left_w, top_h, width, height)),
    ]


def _tile_roi(box: tuple, grid: int, overlap: float) -> List[tuple]:
    x0, y0, x1, y1 = box
    w = x1 - x0
    h = y1 - y0
    tiles: List[tuple] = []
    tile_w = w / grid
    tile_h = h / grid
    pad_x = int(tile_w * overlap / 2)
    pad_y = int(tile_h * overlap / 2)
    for r in range(grid):
        for c in range(grid):
            bx0 = int(x0 + c * tile_w)
            by0 = int(y0 + r * tile_h)
            bx1 = int(x0 + (c + 1) * tile_w)
            by1 = int(y0 + (r + 1) * tile_h)
            tx0 = max(x0, bx0 - pad_x)
            ty0 = max(y0, by0 - pad_y)
            tx1 = min(x1, bx1 + pad_x)
            ty1 = min(y1, by1 + pad_y)
            tiles.append((tx0, ty0, tx1, ty1))
    return tiles


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", default="assets/mock/file_explorer_window.png")
    parser.add_argument("--ollama", default=OLLAMA_URL)
    parser.add_argument("--qdrant", default=QDRANT_URL)
    parser.add_argument("--vision-model", default=VISION_MODEL)
    parser.add_argument("--embed-model", default=EMBED_MODEL)
    parser.add_argument("--collection", default=COLLECTION_NAME)
    parser.add_argument("--min-questions", default="20")
    parser.add_argument("--memory-threshold", default="0.88")
    parser.add_argument("--vision-threshold", default="0.72")
    parser.add_argument("--max-elements", default="40")
    parser.add_argument("--num-predict", default="192")
    parser.add_argument("--purpose-num-predict", default="128")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--labels-only", action="store_true")
    parser.add_argument("--purpose-model", default="")
    parser.add_argument("--hybrid", action="store_true")
    parser.add_argument("--text-purpose-model", default="llama3.2:3b")
    parser.add_argument("--tile-grid", default="3")
    parser.add_argument("--tile-overlap", default="0.3")
    parser.add_argument("--tile-scale", default="3")
    parser.add_argument("--no-ocr-tiles", action="store_true")
    args = parser.parse_args()

    ollama_url = args.ollama
    qdrant_url = args.qdrant
    vision_model = args.vision_model
    embed_model = args.embed_model
    collection = args.collection
    purpose_model = args.purpose_model.strip()
    text_purpose_model = args.text_purpose_model.strip()

    min_questions = int(args.min_questions)
    mem_threshold = float(args.memory_threshold)
    vision_threshold = float(args.vision_threshold)
    max_elements = int(args.max_elements)
    num_predict = int(args.num_predict)
    purpose_num_predict = int(args.purpose_num_predict)
    tile_grid = int(args.tile_grid)
    tile_overlap = float(args.tile_overlap)
    tile_scale = int(args.tile_scale)
    use_tiles = not args.no_ocr_tiles

    with open(args.image, "rb") as f:
        image_bytes = f.read()
    image_b64 = base64.b64encode(image_bytes).decode("utf-8")

    prompt = f"""
You are analyzing a CURRENT software UI screenshot.
Return ONLY valid JSON. No markdown, no prose.

Schema:
{{
  \"screen_summary\": \"short summary\",
  \"elements\": [
    {{
      \"label\": \"exact visible text\",
      \"role\": \"button|tab|menu|link|input|icon|other\",
      \"purpose\": \"what it likely does (leave empty if unsure)\",
      \"confidence\": 0.0-1.0
    }}
  ]
}}

Rules:
- Only include elements with visible text labels.
- Use the exact visible text for each label.
- If you are unsure about an element's purpose, set purpose to \"\" and confidence < 0.5.
- Try to list at least {min_questions} elements if visible.
""".strip()

    t0 = time.time()
    def _ollama_generate_local(
        prompt_text: str,
        image_b64_local: str,
        model_override: str = "",
        num_predict_override: int | None = None,
    ) -> str:
        payload = {
            "model": model_override or vision_model,
            "prompt": prompt_text,
            "stream": False,
            "images": [image_b64_local],
            "options": {"num_predict": num_predict_override or num_predict, "temperature": 0.1},
        }
        resp = requests.post(f"{ollama_url}/api/generate", json=payload, timeout=600)
        resp.raise_for_status()
        return resp.json().get("response", "")

    def _ollama_generate_text_local(prompt_text: str, model_override: str = "") -> str:
        payload = {
            "model": model_override or text_purpose_model,
            "prompt": prompt_text,
            "stream": False,
            "options": {"num_predict": num_predict, "temperature": 0.1},
        }
        resp = requests.post(f"{ollama_url}/api/generate", json=payload, timeout=600)
        resp.raise_for_status()
        return resp.json().get("response", "")

    def _ollama_embed_local(text: str) -> List[float]:
        payload = {"model": embed_model, "prompt": text}
        resp = requests.post(f"{ollama_url}/api/embeddings", json=payload, timeout=300)
        resp.raise_for_status()
        return resp.json().get("embedding", [])

    def _qdrant_search_local(vector: List[float]) -> Tuple[float, Dict[str, Any]]:
        url = f"{qdrant_url}/collections/{collection}/points/search"
        resp = requests.post(url, json={"vector": vector, "limit": 1, "with_payload": True}, timeout=60)
        if resp.status_code == 404:
            return 0.0, {}
        resp.raise_for_status()
        result = resp.json().get("result", [])
        if not result:
            return 0.0, {}
        return float(result[0].get("score", 0.0)), result[0].get("payload", {})

    def _qdrant_save_local(vector: List[float], payload: Dict[str, Any]) -> None:
        url = f"{qdrant_url}/collections/{collection}/points"
        point_id = int(time.time() * 1000)
        body = {"points": [{"id": point_id, "vector": vector, "payload": payload}]}
        resp = requests.put(url, json=body, timeout=60)
        if resp.status_code in (404, 400):
            return
        resp.raise_for_status()

    response = _ollama_generate_local(prompt, image_b64) if not args.labels_only else ""
    if args.debug:
        print("--- Raw Vision Response ---")
        print(response)
    vision_ms = int((time.time() - t0) * 1000)

    decoded = {}
    if response:
        clean = _extract_json(response)
        try:
            decoded = json.loads(clean)
        except Exception:
            decoded = {}

    screen_summary = ""
    elements: List[Any] = []
    if isinstance(decoded, dict):
        screen_summary = str(decoded.get("screen_summary", ""))
        raw = decoded.get("elements", decoded.get("items", []))
        if isinstance(raw, list):
            elements = raw
    elif isinstance(decoded, list):
        elements = decoded

    # Fallback: simpler prompt for weaker vision models
    if not elements:
        label_matches = [m.group(1) for m in re.finditer(r'"label"\s*:\s*"([^"]+)"', response)]
        if label_matches:
            elements = [
                {"label": label.strip(), "role": "other", "purpose": "", "confidence": 0.4}
                for label in label_matches
                if label.strip()
            ]

    if not elements:
        fallback_prompt = (
            "List all visible text labels (buttons, tabs, menus, folders) in this UI screenshot. "
            "Output ONLY the labels as comma-separated words/phrases. No numbers, no JSON."
        )
        if args.labels_only:
            t0 = time.time()
        fallback_response = _ollama_generate_local(fallback_prompt, image_b64)
        if args.labels_only:
            vision_ms = int((time.time() - t0) * 1000)
        if args.debug:
            print("--- Raw Fallback Response ---")
            print(fallback_response)
        labels: List[str] = []
        labels = [l.strip() for l in re.split(r"[\n,]+", fallback_response) if l.strip()]
        labels = _clean_label_list(labels)
        if len(labels) == 1 and re.search(r"\d+\.\s*", labels[0]):
            parts = re.split(r"\d+\.\s*", labels[0])
            labels = _clean_label_list([p for p in parts if p.strip()])
        if not labels:
            fallback_clean = _extract_json(fallback_response)
            try:
                fallback_decoded = json.loads(fallback_clean)
            except Exception:
                fallback_decoded = []
            if isinstance(fallback_decoded, dict):
                labels = [str(k).strip() for k in fallback_decoded.keys() if str(k).strip()]
            elif isinstance(fallback_decoded, list):
                labels = [str(item).strip() for item in fallback_decoded if str(item).strip()]
            labels = _clean_label_list(labels)
        if not labels:
            labels = [m.group(1).strip() for m in re.finditer(r'"([^"]+)"', fallback_response)]
            labels = _clean_label_list(labels)
        if labels:
            elements = [
                {"label": label, "role": "other", "purpose": "", "confidence": 0.4}
                for label in labels
                if label
            ]
    if args.debug:
        print(f"Parsed elements: {len(elements)}")

    questions: List[str] = []
    learned: List[Dict[str, str]] = []

    if args.hybrid:
        t_ocr = time.time()
        if use_tiles:
            img = Image.open(args.image).convert("RGB")
            rois = _generate_rois(img.width, img.height)
            collected: List[str] = []
            for _, roi in rois:
                tiles = _tile_roi(roi, tile_grid, tile_overlap)
                for tile in tiles:
                    cropped = img.crop(tile)
                    processed = _preprocess_tile(cropped, scale=tile_scale)
                    collected.extend(_ocr_labels_from_image(processed))
            ocr_ms = int((time.time() - t_ocr) * 1000)
            ocr_labels = _clean_label_list(collected)[:max_elements]
        else:
            ocr_text = _run_tesseract_tsv(args.image)
            ocr_ms = int((time.time() - t_ocr) * 1000)
            ocr_labels = _extract_ocr_labels_from_tsv(ocr_text)[:max_elements]

        if args.debug:
            print(f"OCR labels: {len(ocr_labels)}")

        if not ocr_labels:
            print("OCR produced no labels. Aborting hybrid run.")
            return

        t_vis = time.time()
        labels_list = ", ".join([f'"{l}"' for l in ocr_labels])
        hybrid_prompt = f"""
    You are analyzing a UI screenshot. For each label, assign role and purpose.
    Return ONLY lines in this exact format:
    Label | role | purpose

    Allowed roles: button, tab, menu, link, input, folder, window, other

    Labels:
    [{labels_list}]
    """.strip()

        hybrid_response = _ollama_generate_local(
            hybrid_prompt,
            image_b64,
            model_override=purpose_model,
            num_predict_override=num_predict,
        )
        vis_ms = int((time.time() - t_vis) * 1000)

        if args.debug:
            print("--- Hybrid Vision Response ---")
            print(hybrid_response)

        items = []
        clean = _extract_json(hybrid_response)
        try:
            decoded = json.loads(clean)
        except Exception:
            decoded = {}
        if isinstance(decoded, dict) and isinstance(decoded.get("items"), list):
            items = decoded.get("items", [])
        elif isinstance(decoded, list):
            items = decoded

        if not items:
            for line in hybrid_response.splitlines():
                if "|" not in line:
                    continue
                parts = [p.strip() for p in line.split("|")]
                if len(parts) < 3:
                    continue
                items.append({
                    "label": parts[0],
                    "role": parts[1],
                    "purpose": " | ".join(parts[2:]).strip(),
                    "confidence": 0.8,
                })

        if not items and text_purpose_model:
            t_text = time.time()
            text_prompt = f"""
You are given UI labels from a screenshot. For each label, infer a role and purpose based on common UI patterns.
Return ONLY lines in this exact format:
Label | role | purpose

Allowed roles: button, tab, menu, link, input, folder, window, other

Labels:
[{labels_list}]
""".strip()
            text_response = _ollama_generate_text_local(text_prompt, text_purpose_model)
            text_ms = int((time.time() - t_text) * 1000)
            if args.debug:
                print("--- Hybrid Text Fallback Response ---")
                print(text_response)
                print(f"Text fallback time: {text_ms} ms")
            for line in text_response.splitlines():
                if "|" not in line:
                    continue
                parts = [p.strip() for p in line.split("|")]
                if len(parts) < 3:
                    continue
                items.append({
                    "label": parts[0],
                    "role": parts[1],
                    "purpose": " | ".join(parts[2:]).strip(),
                    "confidence": 0.7,
                })

        valid_items = []
        for item in items:
            if not isinstance(item, dict):
                continue
            label = str(item.get("label", "")).strip()
            role = str(item.get("role", "other")).strip()
            if "|" in role:
                role = "other"
            raw_purpose = item.get("purpose", "")
            purpose = raw_purpose.strip() if isinstance(raw_purpose, str) else ""
            conf = item.get("confidence", 0.0)
            try:
                conf_val = float(conf)
            except Exception:
                conf_val = 0.0
            if not label:
                continue
            valid_items.append({
                "label": label,
                "role": role,
                "purpose": purpose,
                "confidence": conf_val,
            })

        if not valid_items and text_purpose_model:
            t_text = time.time()
            text_prompt = f"""
You are given UI labels from a screenshot. For each label, infer a role and purpose based on common UI patterns.
Return ONLY lines in this exact format:
Label | role | purpose

Allowed roles: button, tab, menu, link, input, folder, window, other

Labels:
[{labels_list}]
""".strip()
            text_response = _ollama_generate_text_local(text_prompt, text_purpose_model)
            text_ms = int((time.time() - t_text) * 1000)
            if args.debug:
                print("--- Hybrid Text Fallback Response ---")
                print(text_response)
                print(f"Text fallback time: {text_ms} ms")
            triplets = re.findall(r'\["([^"]+)"\s*,\s*"([^"]+)"\s*,\s*"([^"]+)"\]', text_response)
            if triplets:
                for label, role, purpose in triplets:
                    label = label.strip()
                    role = role.strip().lower()
                    purpose = purpose.strip()
                    if not label:
                        continue
                    if role not in {"button", "tab", "menu", "link", "input", "folder", "window", "other"}:
                        role = "other"
                    valid_items.append({
                        "label": label,
                        "role": role,
                        "purpose": purpose,
                        "confidence": 0.7,
                    })
            else:
                for line in text_response.splitlines():
                    if "|" in line:
                        parts = [p.strip() for p in line.split("|")]
                        if len(parts) < 3:
                            continue
                        label = parts[0].strip().strip('"').strip("'")
                        role = parts[1].strip().lower()
                        purpose = " | ".join(parts[2:]).strip().strip('"').strip("'")
                    else:
                        quoted = re.findall(r'"([^"]+)"', line)
                        if len(quoted) >= 3:
                            label = quoted[0].strip()
                            role = quoted[1].strip().lower()
                            purpose = quoted[2].strip()
                        else:
                            continue
                    if not label:
                        continue
                    if role not in {"button", "tab", "menu", "link", "input", "folder", "window", "other"}:
                        role = "other"
                    valid_items.append({
                        "label": label,
                        "role": role,
                        "purpose": purpose,
                        "confidence": 0.7,
                    })

        if not valid_items:
            print("No valid role/purpose items parsed.")
            return

        for item in valid_items:
            label = item["label"]
            role = item["role"]
            purpose = item["purpose"]
            conf_val = item["confidence"]

            if purpose:
                learned.append({"label": label, "role": role or "other", "purpose": purpose})
            elif len(questions) < min_questions:
                questions.append(f"What does \"{label}\" do?")

        total_ms = int((time.time() - t0) * 1000)
        print(f"OCR time: {ocr_ms} ms")
        print(f"Vision time: {vis_ms} ms")
        print(f"Total time: {total_ms} ms")
        print("--- Questions ---")
        for q in questions:
            print(q)
        print(f"Parsed items: {len(valid_items)}")
        print(f"Items with purpose: {len(learned)}")
        print("--- Learned Items ---")
        for item in learned:
            label = item.get("label", "")
            role = item.get("role", "")
            purpose = item.get("purpose", "")
            print(f"{label} [{role}] -> {purpose}")
        return

    embed_time = 0.0
    processed = 0
    seen_labels = set()
    for element in elements:
        label = ""
        role = ""
        purpose = ""
        confidence = 0.0

        if isinstance(element, str):
            label = element.strip()
        elif isinstance(element, dict):
            label = str(element.get("label") or element.get("text") or element.get("name") or "").strip()
            role = str(element.get("role") or element.get("type") or "").strip()
            purpose = str(element.get("purpose") or element.get("description") or "").strip()
            conf = element.get("confidence")
            if isinstance(conf, (int, float)):
                confidence = float(conf)
            elif isinstance(conf, str):
                try:
                    confidence = float(conf)
                except Exception:
                    confidence = 0.0

        if not label:
            continue
        label_key = label.lower()
        if label_key in seen_labels:
            continue
        seen_labels.add(label_key)
        processed += 1
        if processed > max_elements:
            break

        query = f"Element: {label}." if not purpose else f"Element: {label}. Purpose: {purpose}."
        t1 = time.time()
        vector = _ollama_embed_local(query)
        score, _ = _qdrant_search_local(vector) if vector else (0.0, {})
        embed_time += (time.time() - t1)

        if score >= mem_threshold:
            continue

        if not purpose:
            purpose_prompt = (
                "You are analyzing a UI screenshot. "
                f"Explain the purpose of the UI element labeled '{label}' in 1 short sentence. "
                "If unsure, return an empty string. Output ONLY the text." 
            )
            purpose_response = _ollama_generate_local(
                purpose_prompt,
                image_b64,
                model_override=purpose_model,
                num_predict_override=purpose_num_predict,
            ).strip().strip('"')
            if purpose_response and purpose_response.lower() not in {"unknown", "unsure", "i'm not sure"}:
                purpose = purpose_response

        if purpose and confidence >= vision_threshold:
            goal = _normalize_goal(purpose, label)
            save_vector = _ollama_embed_local(
                f"Goal: {goal}. Element: {label}. Purpose: {purpose}. Screen: {screen_summary}."
            )
            if save_vector:
                _qdrant_save_local(
                    save_vector,
                    {
                        "goal": goal,
                        "action": {"type": "click", "target_text": label},
                        "fact": purpose,
                        "description": screen_summary,
                        "role": role,
                        "purpose": purpose,
                        "source": "vision_mvp",
                        "confidence": confidence,
                        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
                    },
                )
            learned.append({"label": label, "role": role or "other", "purpose": purpose})
        else:
            if len(questions) < min_questions:
                questions.append(f"What does \"{label}\" do?")

    total_ms = int((time.time() - t0) * 1000)
    embed_ms = int(embed_time * 1000)

    print(f"Vision time: {vision_ms} ms")
    print(f"Embed+search time: {embed_ms} ms")
    print(f"Total time: {total_ms} ms")
    print("--- Questions ---")
    for q in questions:
        print(q)
    print("--- Learned Items ---")
    for item in learned:
        label = item.get("label", "")
        role = item.get("role", "")
        purpose = item.get("purpose", "")
        print(f"{label} [{role}] -> {purpose}")


if __name__ == "__main__":
    main()
