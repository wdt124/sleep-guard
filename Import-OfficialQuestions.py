"""Import selected JLPT N4 public workbook items for personal study.

Only source coordinates and official answer numbers are versioned. Original
question images remain under the user's LocalAppData, outside the MIT repo.
"""
import argparse
import json
import os
import tempfile
import urllib.request
from pathlib import Path

import pypdfium2 as pdfium

parser = argparse.ArgumentParser()
parser.add_argument("--data-root", required=True)
args = parser.parse_args()
root = Path(args.data_root).resolve()
assets = root / "official"
assets.mkdir(parents=True, exist_ok=True)
repo = Path(__file__).resolve().parent
index = json.loads((repo / "official-index.json").read_text(encoding="utf-8-sig"))
knowledge = {p["id"]: p for p in json.loads((repo / "knowledge-bank.json").read_text(encoding="utf-8-sig"))}
documents = {}
for year in sorted({item["year"] for item in index["items"]}):
    target = assets / f"{year}-N4G.pdf"
    if not target.exists():
        url = f"https://www.jlpt.jp/samples/sample{year}/pdf/N4G.pdf"
        with urllib.request.urlopen(url, timeout=30) as response:
            payload = response.read()
        if not payload.startswith(b"%PDF-"):
            raise ValueError("Official endpoint did not return a PDF")
        target.write_bytes(payload)
    documents[year] = pdfium.PdfDocument(target)

questions = []
for item in index["items"]:
    point = knowledge[item["knowledgePointId"]]
    page = documents[item["year"]][item["page"]]
    image = page.render(scale=2.0).to_pil()
    left, top, right, bottom = item["crop"]
    cropped = image.crop((round(image.width*left), round(image.height*top),
                          round(image.width*right), round(image.height*bottom)))
    image_path = assets / f"{item['year']}-G-{item['number']}.png"
    cropped.save(image_path)
    questions.append({
        "id": f"official-{item['year']}-G-{item['number']}",
        "knowledgePointId": point["id"],
        # The original unmodified question and options are shown as an image.
        "stem": f"JLPT N4 {item['year']} 公开真题选编 · 语法第 {item['number']} 题（　）",
        "options": ["1", "2", "3", "4"],
        "correctIndex": item["answer"]-1,
        "grammarPoint": point["title"],
        "explanation": f"官方正答表为第 {item['answer']} 项。知识点说明：{point['content']}",
        "imagePath": str(image_path),
        "source": f"JLPT 官方真题选编 {item['year']} · N4 文法问题1 第{item['number']}题 · 原文及官方答案",
        "sourceUrl": f"https://www.jlpt.jp/samples/sample{item['year']}/pdf/N4G.pdf",
    })
for doc in documents.values():
    doc.close()
fd, temporary = tempfile.mkstemp(prefix="official-questions-", suffix=".tmp", dir=root)
with os.fdopen(fd, "w", encoding="utf-8") as stream:
    json.dump({"schemaVersion": 1, "questions": questions}, stream, ensure_ascii=False, indent=2)
os.replace(temporary, root / "official-questions.json")
print(f"Imported {len(questions)} official items for personal study into {root}")
