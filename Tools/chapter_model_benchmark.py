#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import time
from pathlib import Path


SYSTEM_PROMPT = (
    "Du bist ein praeziser Podcast-Kapitelgenerator. Arbeite nur mit den "
    "angegebenen Zeiten und Texten. Erfinde keine Inhalte. Antworte "
    "ausschliesslich mit validem JSON, ohne Markdown und ohne Erklaertext."
)

SPONSOR_RULE = (
    "- Behandle isSponsor als skip-wuerdige Promotion, nicht nur als externe "
    "Werbung: Sponsoring, Eigenpromo, bezahlte Angebote, Mitgliedschaften/Abos, "
    "Shops/Merch, Spenden/Support, Bewertungs-/Follow-Aufrufe, Cross-Promotion "
    "sowie kommerzielle oder monetaere Calls-to-Action fuer eigene Produkte, "
    "Events oder Services. Wenn ein Abschnitt hauptsaechlich dazu auffordert, "
    "ausserhalb des redaktionellen Inhalts etwas zu kaufen, zu abonnieren, zu "
    "unterstuetzen, zu bewerten/folgen, ein Event zu besuchen, einen Shop/Link "
    "zu nutzen oder ein anderes Angebot zu konsumieren, ist er Promotion. "
    "Bezahlter oder limitierter Zugang zu einem eigenen Angebot, ein Link in "
    "Shownotes zu diesem Angebot oder die Aufforderung, ein eigenes Event, "
    "Produkt, Abo, Netzwerk oder anderes Format zu nutzen, ist Promotion auch "
    "dann, wenn es informativ formuliert ist. "
    "Kapitel, die nur Details eines eigenen Angebots, Events, Produkts, Abos "
    "oder anderen eigenen Formats liefern, sind ebenfalls Promotion, auch "
    "wenn der konkrete Kauf- oder Nutzungsaufruf erst in einem benachbarten "
    "Kapitel steht. "
    "Neutrale Erwaehnungen von Plattformen, Tools, Apps, Diensten oder "
    "Anbietern sind keine Promotion, wenn sie nur erklaert werden und nicht "
    "dazu auffordern, sie zu kaufen, zu abonnieren, zu unterstuetzen oder zu "
    "nutzen. "
    "Behandle eigene Angebote, eigene Events und andere eigene Podcasts genauso "
    "als Promotion; sie sind nicht redaktionell, nur weil sie vom Podcast selbst "
    "stammen. "
    "Erkenne das semantisch in jeder Sprache; Titel dafuer 'Sponsor: ...' und "
    "isSponsor true, auch wenn der Promo-Abschnitt am Anfang, Ende oder ueber "
    "fast die ganze kurze Folge laeuft. isSponsor false ist nur fuer "
    "redaktionellen Inhalt ohne solches Call-to-Action-Ziel erlaubt.\n"
)
PROMOTION_SEGMENTATION_RULE = (
    "- Wenn redaktioneller Inhalt in Promotion, Eigenpromo oder einen "
    "Call-to-Action uebergeht, beginne dort ein eigenes Sponsor-Kapitel; "
    "mische redaktionellen Inhalt und Promotion nicht im selben Kapitel.\n"
)
CHAPTER_GRAMMAR = r'''
root ::= "{" ws "\"chapters\"" ws ":" ws "[" ws (chapter ("," ws chapter)*)? "]" ws "}" ws
chapter ::= "{" ws "\"startSeconds\"" ws ":" ws integer "," ws "\"title\"" ws ":" ws nonemptystring "," ws "\"isSponsor\"" ws ":" ws boolean ws "}" ws
nonemptystring ::= "\"" [^"\\] ([^"\\] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F]))* "\"" ws
integer ::= ("-"? ([0-9] | [1-9] [0-9]*)) ws
boolean ::= ("true" | "false") ws
ws ::= [ \t\n\r]*
'''

CLASSIFIED_CHAPTER_GRAMMAR = r'''
root ::= "{" ws "\"chapters\"" ws ":" ws "[" ws (chapter ("," ws chapter)*)? "]" ws "}" ws
chapter ::= "{" ws "\"startSeconds\"" ws ":" ws integer "," ws "\"endSeconds\"" ws ":" ws integer "," ws "\"title\"" ws ":" ws nonemptystring "," ws "\"isSponsor\"" ws ":" ws boolean ws "}" ws
nonemptystring ::= "\"" [^"\\] ([^"\\] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F]))* "\"" ws
integer ::= ("-"? ([0-9] | [1-9] [0-9]*)) ws
boolean ::= ("true" | "false") ws
ws ::= [ \t\n\r]*
'''


def parse_time(value):
    h, m, rest = value.split(":")
    s, ms = rest.split(",")
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000


def format_model_second(seconds):
    return f"{int(round(float(seconds)))}s"


def format_model_second_range(start, end):
    return f"{format_model_second(start)}-{format_model_second(end)}"


def parse_srt(path):
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    cues = []
    blocks = re.split(r"\n\s*\n", text.strip())
    for block in blocks:
        lines = [line.strip() for line in block.splitlines() if line.strip()]
        if len(lines) < 2:
            continue
        time_line = next((line for line in lines if "-->" in line), None)
        if not time_line:
            continue
        start_raw, end_raw = [part.strip() for part in time_line.split("-->")]
        time_index = lines.index(time_line)
        cue_text = " ".join(lines[time_index + 1 :]).strip()
        if cue_text:
            cues.append(
                {
                    "start": parse_time(start_raw),
                    "end": parse_time(end_raw),
                    "text": re.sub(r"\s+", " ", cue_text),
                }
            )
    return cues


def build_prompt(cues, title=None, feed=None):
    duration = cues[-1]["end"] if cues else 0
    prompt = "Erstelle die finale Kapitel-Liste aus dem vollstaendigen Podcast-Transkript.\n"
    prompt += f"Gesamtdauer: {int(duration)} Sekunden.\n\n"
    prompt += "Regeln:\n"
    prompt += "- Nutze das gesamte Transkript als Kontext; erfinde keine Inhalte.\n"
    prompt += "- Ein Kapitel darf sehr lang sein, auch 40 Minuten oder laenger, wenn der Inhalt wirklich ein zusammenhaengender Themenblock ist.\n"
    prompt += "- Unterteile nicht nach Dauer, sondern nur bei echten, fuer Hoerer nuetzlichen Themen-, Segment- oder Skip-Wechseln.\n"
    prompt += "- Erzeuge keine eigenen Kapitelstarts fuer kurze Begruessungen, Meta-Einleitungen, Ueberleitungen, Fuellsaetze oder einzelne Service-Details, wenn sie zum selben Nutzenthema gehoeren.\n"
    prompt += "- Ein einzelnes Kapitel ueber fast die ganze Folge ist nur erlaubt, wenn das Transkript wirklich keinen eigenen Nutzensprung, keine neue Hauptfrage, kein Fazit und kein skip-wuerdiges Segment enthaelt.\n"
    prompt += "- Wenn ein Gespraech mehrere Hauptfragen, Argumente, Methoden, Studien, konkrete Beispiele, Empfehlungen oder ein Schlusssegment behandelt, muessen die Kapitelstarts diese Wechsel sichtbar machen.\n"
    prompt += SPONSOR_RULE
    prompt += PROMOTION_SEGMENTATION_RULE
    prompt += "- Titel in der Sprache des Transkripts.\n"
    prompt += "- Titel muessen fuer Hoerer bei der Kapitelauswahl nuetzlich sein: konkrete Sache, Person, Ort, Frage, Messwert, Methode oder zentrale These nennen.\n"
    prompt += "- Keine reinen Kategorie-, Schlagwort- oder Oberbegriff-Titel; der Titel muss erkennen lassen, welche konkrete Frage, Behauptung, Ursache, Folge oder Entscheidung im Abschnitt behandelt wird.\n"
    prompt += "- Beschreibe nicht den Sprechakt wie Begruessung, Einleitung, Ankuendigung, Ueberblick oder Diskussion, wenn der Abschnitt konkrete Inhalte nennt; benenne dann die angekuendigte Sache selbst.\n"
    prompt += "- Keine vagen Meta-Titel und keine einzelnen Satzfragmente.\n"
    prompt += "- startSeconds als Sekunden ab Podcast-Anfang (Ganzzahl).\n"
    prompt += f"- Das erste Kapitel beginnt bei 0; das letzte Kapitel endet automatisch bei der Gesamtdauer {int(duration)}.\n"
    prompt += "- Gib nur Kapitelstarts aus; Endzeiten werden deterministisch aus dem naechsten startSeconds berechnet.\n\n"
    if title or feed:
        prompt += "Podcast-Kontext:\n"
        if feed:
            prompt += f"Podcast: {feed}\n"
        if title:
            prompt += f"Episode: {title}\n"
        prompt += "Nutze diesen Kontext nur, wenn der Transkriptabschnitt ihn stuetzt.\n\n"
    prompt += f"Transkript (0s-{format_model_second(duration)}):\n"
    for cue in cues:
        prompt += f"[{format_model_second(cue['start'])}] {cue['text']}\n"
    prompt += "\nAntworte ausschliesslich mit einem JSON-Objekt. Es enthaelt genau ein Feld \"chapters\" als Array. Jeder Eintrag enthaelt nur \"startSeconds\" als Ganzzahl ab Podcast-Anfang, \"title\" als nicht leeren String und \"isSponsor\" als Boolean. Erzeuge kein \"endSeconds\"-Feld; Kapitelenden werden aus dem naechsten startSeconds berechnet. Verwende keine Beispielwerte.\n"
    prompt += "Schliesse das JSON-Objekt sofort und beende danach die Antwort.\n"
    return prompt


def build_sponsor_classification_prompt(chapters, cues, title=None, feed=None):
    duration = cues[-1]["end"] if cues else 0
    prompt = "Klassifiziere die bestehenden Podcast-Kapitel semantisch als skip-wuerdige Promotion oder redaktionellen Inhalt.\n"
    prompt += f"Gesamtdauer: {int(duration)} Sekunden.\n\n"
    prompt += "Regeln:\n"
    prompt += "- Aendere keine Kapitelgrenzen und lasse die Anzahl der Kapitel exakt gleich.\n"
    prompt += "- Nutze startSeconds und endSeconds exakt wie in der bestehenden Kapitel-Liste.\n"
    prompt += "- Nutze das Transkript als Kontext; erfinde keine Inhalte.\n"
    prompt += SPONSOR_RULE
    prompt += "- Fuer Promotion: isSponsor true und Titel mit 'Sponsor: ...'.\n"
    prompt += "- Fuer redaktionellen Inhalt: isSponsor false und keinen Sponsor-Prefix.\n"
    prompt += "- Audio-Kapitel wie Intro, Jingle oder Sound-Sample bleiben isSponsor false, ausser der umgebende Transkript-Kontext macht sie selbst zur Promotion.\n\n"
    if title or feed:
        prompt += "Podcast-Kontext:\n"
        if feed:
            prompt += f"Podcast: {feed}\n"
        if title:
            prompt += f"Episode: {title}\n"
        prompt += "Nutze diesen Kontext nur, wenn der Transkriptabschnitt ihn stuetzt.\n\n"
    prompt += "Bestehende Kapitel:\n"
    for chapter in chapters:
        prompt += (
            f"[{format_model_second_range(chapter['startSeconds'], chapter['endSeconds'])}] "
            f"{chapter['title']}, isSponsor: {str(chapter.get('isSponsor', False)).lower()}\n"
        )
    prompt += f"\nTranskript (0s-{format_model_second(duration)}):\n"
    for cue in cues:
        prompt += f"[{format_model_second(cue['start'])}] {cue['text']}\n"
    prompt += "\n\nAntworte ausschliesslich mit einem JSON-Objekt. Es enthaelt genau ein Feld \"chapters\" als Array. Jeder Eintrag enthaelt \"startSeconds\" und \"endSeconds\" unveraendert aus der bestehenden Kapitel-Liste, \"title\" als nicht leeren String und \"isSponsor\" als Boolean. Verwende keine Beispielwerte.\n"
    return prompt


def first_json_object(text):
    start = None
    depth = 0
    in_string = False
    escaped = False
    for index, char in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            if depth == 0:
                start = index
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0 and start is not None:
                return text[start : index + 1]
    return None


def validate(chapters, duration):
    issues = []
    if not chapters:
        return ["no chapters"]
    boundary_tolerance = max(2.0, min(6.0, duration * 0.0025))
    if abs(chapters[0].get("startSeconds", 0)) > boundary_tolerance:
        issues.append("first chapter does not start at 0")
    for left, right in zip(chapters, chapters[1:]):
        if abs(left.get("endSeconds", 0) - right.get("startSeconds", 0)) > boundary_tolerance:
            issues.append("non-contiguous boundaries")
            break
    if abs(chapters[-1].get("endSeconds", 0) - int(duration)) > boundary_tolerance:
        issues.append("last chapter does not end at duration")
    for chapter in chapters:
        if chapter.get("endSeconds", 0) <= chapter.get("startSeconds", 0):
            issues.append("non-positive chapter duration")
            break
        if len(chapter.get("title", "").split()) > 14:
            issues.append("verbose title")
            break
    if len(chapters) == 1 and duration >= 600:
        issues.append("single full-episode chapter")
    return issues


def chapters_from_starts(generated, duration):
    chapters = []
    for index, chapter in enumerate(generated):
        end = generated[index + 1]["startSeconds"] if index + 1 < len(generated) else int(duration)
        chapters.append(
            {
                "startSeconds": chapter["startSeconds"],
                "endSeconds": end,
                "title": chapter["title"],
                "isSponsor": chapter["isSponsor"],
            }
        )
    return chapters


def local_context_tokens(prompt_characters):
    return 32_768


def max_tokens_for_duration(duration):
    return 4096


def normalize_max_tokens(configured, duration):
    return configured or max_tokens_for_duration(duration)


def run_model(llama_cli, model_path, srt_path, output_dir, context, max_tokens, timeout):
    cues = parse_srt(srt_path)
    duration = cues[-1]["end"] if cues else 0
    prompt = build_prompt(cues)
    output_dir.mkdir(parents=True, exist_ok=True)
    prompt_path = output_dir / f"{Path(srt_path).stem}.prompt.txt"
    grammar_path = output_dir / "chapters.gbnf"
    prompt_path.write_text(prompt, encoding="utf-8")
    grammar_path.write_text(CHAPTER_GRAMMAR.strip() + "\n", encoding="utf-8")

    effective_context = context or local_context_tokens(len(prompt))
    command = [
        llama_cli,
        "-m",
        model_path,
        "-c",
        str(effective_context),
        "-n",
        str(normalize_max_tokens(max_tokens, duration)),
        "-ngl",
        "99",
        "--flash-attn",
        "auto",
        "--no-display-prompt",
        "--no-context-shift",
        "--temp",
        "0",
        "--top-k",
        "1",
        "--seed",
        "42",
        "--reasoning",
        "off",
        "--grammar-file",
        str(grammar_path),
        "-sys",
        SYSTEM_PROMPT,
        "-f",
        str(prompt_path),
    ]
    started = time.monotonic()
    proc = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
    elapsed = time.monotonic() - started
    stdout_path = output_dir / f"{Path(srt_path).stem}.stdout.txt"
    stderr_path = output_dir / f"{Path(srt_path).stem}.stderr.txt"
    stdout_path.write_text(proc.stdout, encoding="utf-8", errors="replace")
    stderr_path.write_text(proc.stderr, encoding="utf-8", errors="replace")
    parsed = None
    parse_error = None
    obj = first_json_object(proc.stdout)
    if obj:
        try:
            parsed = json.loads(obj)
        except Exception as error:
            parse_error = str(error)
    else:
        parse_error = "no JSON object"
    generated = parsed.get("chapters", []) if isinstance(parsed, dict) else []
    chapters = chapters_from_starts(generated, duration) if parsed else []
    result = {
        "srt": str(srt_path),
        "durationSeconds": duration,
        "cueCount": len(cues),
        "promptCharacters": len(prompt),
        "contextTokens": effective_context,
        "maxTokens": normalize_max_tokens(max_tokens, duration),
        "elapsedSeconds": elapsed,
        "returnCode": proc.returncode,
        "parseError": parse_error,
        "chapterCount": len(chapters),
        "sponsorCount": sum(1 for chapter in chapters if chapter.get("isSponsor")),
        "issues": validate(chapters, duration) if parsed else [parse_error or "parse failed"],
        "generatedStarts": generated,
        "chapters": chapters,
    }
    (output_dir / f"{Path(srt_path).stem}.result.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return result


def run_chat_json_python(llm, prompt, grammar_text, max_tokens):
    from llama_cpp import LlamaGrammar

    grammar = LlamaGrammar.from_string(grammar_text)
    started = time.monotonic()
    output = ""
    token_chunks = 0
    stream = llm.create_chat_completion(
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        max_tokens=max_tokens,
        temperature=0.0,
        top_k=1,
        top_p=1.0,
        min_p=0.0,
        seed=42,
        grammar=grammar,
        stream=True,
    )
    try:
        for chunk in stream:
            delta = chunk["choices"][0].get("delta", {})
            piece = delta.get("content") or ""
            if piece:
                output += piece
                token_chunks += 1
                if first_json_object(output):
                    break
    finally:
        close = getattr(stream, "close", None)
        if close:
            close()
    return output, token_chunks, time.monotonic() - started


def validate_classified_chapters(original, classified):
    if len(original) != len(classified):
        return "classifier changed chapter count"
    for left, right in zip(original, classified):
        if left.get("startSeconds") != right.get("startSeconds"):
            return "classifier changed startSeconds"
        if left.get("endSeconds") != right.get("endSeconds"):
            return "classifier changed endSeconds"
    return None


def classify_sponsors_python(llm, chapters, cues, output_dir, stem):
    prompt = build_sponsor_classification_prompt(chapters, cues)
    prompt_path = output_dir / f"{stem}.classifier.prompt.txt"
    prompt_path.write_text(prompt, encoding="utf-8")
    output, token_chunks, elapsed = run_chat_json_python(
        llm,
        prompt,
        CLASSIFIED_CHAPTER_GRAMMAR,
        min(2048, max(512, len(chapters) * 120)),
    )
    stdout_path = output_dir / f"{stem}.classifier.stdout.txt"
    stdout_path.write_text(output, encoding="utf-8", errors="replace")
    obj = first_json_object(output)
    if not obj:
        return chapters, {
            "issue": "classifier produced no JSON object",
            "elapsedSeconds": elapsed,
            "tokenChunks": token_chunks,
        }
    try:
        parsed = json.loads(obj)
    except Exception as error:
        return chapters, {
            "issue": f"classifier parse error: {error}",
            "elapsedSeconds": elapsed,
            "tokenChunks": token_chunks,
        }
    classified = parsed.get("chapters", []) if isinstance(parsed, dict) else []
    issue = validate_classified_chapters(chapters, classified)
    if issue:
        return chapters, {
            "issue": issue,
            "elapsedSeconds": elapsed,
            "tokenChunks": token_chunks,
        }
    return classified, {
        "issue": None,
        "elapsedSeconds": elapsed,
        "tokenChunks": token_chunks,
    }


def run_model_python(llm, srt_path, output_dir, context, max_tokens, classify_sponsors):
    cues = parse_srt(srt_path)
    duration = cues[-1]["end"] if cues else 0
    prompt = build_prompt(cues)
    output_dir.mkdir(parents=True, exist_ok=True)
    prompt_path = output_dir / f"{Path(srt_path).stem}.prompt.txt"
    prompt_path.write_text(prompt, encoding="utf-8")

    effective_context = context or local_context_tokens(len(prompt))
    generation_limit = normalize_max_tokens(max_tokens, duration)
    output, token_chunks, elapsed = run_chat_json_python(
        llm, prompt, CHAPTER_GRAMMAR, generation_limit
    )

    stdout_path = output_dir / f"{Path(srt_path).stem}.stdout.txt"
    stdout_path.write_text(output, encoding="utf-8", errors="replace")
    parsed = None
    parse_error = None
    obj = first_json_object(output)
    if obj:
        try:
            parsed = json.loads(obj)
        except Exception as error:
            parse_error = str(error)
    else:
        parse_error = "no JSON object"
    generated = parsed.get("chapters", []) if isinstance(parsed, dict) else []
    chapters = chapters_from_starts(generated, duration) if parsed else []
    classifier = None
    if parsed and classify_sponsors and chapters:
        chapters, classifier = classify_sponsors_python(
            llm, chapters, cues, output_dir, Path(srt_path).stem
        )
    result = {
        "srt": str(srt_path),
        "durationSeconds": duration,
        "cueCount": len(cues),
        "promptCharacters": len(prompt),
        "contextTokens": effective_context,
        "maxTokens": generation_limit,
        "elapsedSeconds": elapsed,
        "tokenChunks": token_chunks,
        "sponsorClassifier": classifier,
        "parseError": parse_error,
        "chapterCount": len(chapters),
        "sponsorCount": sum(1 for chapter in chapters if chapter.get("isSponsor")),
        "issues": (
            validate(chapters, duration)
            + ([classifier["issue"]] if classifier and classifier.get("issue") else [])
            if parsed
            else [parse_error or "parse failed"]
        ),
        "generatedStarts": generated,
        "chapters": chapters,
    }
    (output_dir / f"{Path(srt_path).stem}.result.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--llama-cli")
    parser.add_argument("--model", required=True)
    parser.add_argument("--model-name", required=True)
    parser.add_argument("--srt", action="append", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--context", type=int, default=0)
    parser.add_argument("--max-tokens", type=int, default=0)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--chat-format")
    parser.add_argument("--skip-sponsor-classifier", action="store_true")
    args = parser.parse_args()

    output_dir = Path(args.out) / args.model_name
    prompts = [build_prompt(parse_srt(srt)) for srt in args.srt]
    run_context = args.context or local_context_tokens(max(map(len, prompts)))
    summary = {
        "modelName": args.model_name,
        "modelPath": args.model,
        "contextTokens": run_context,
        "results": [],
    }
    llm = None
    if not args.llama_cli:
        from llama_cpp import Llama

        load_started = time.monotonic()
        print(f"LOAD {args.model_name} ctx={run_context}", flush=True)
        llm = Llama(
            model_path=args.model,
            n_ctx=run_context,
            n_batch=2048,
            n_ubatch=512,
            n_gpu_layers=-1,
            flash_attn=True,
            seed=42,
            chat_format=args.chat_format,
            verbose=False,
        )
        summary["loadSeconds"] = time.monotonic() - load_started
    for srt in args.srt:
        print(f"RUN {args.model_name} {Path(srt).name}", flush=True)
        try:
            if llm:
                result = run_model_python(
                    llm,
                    srt,
                    output_dir,
                    run_context,
                    args.max_tokens,
                    classify_sponsors=not args.skip_sponsor_classifier,
                )
            else:
                result = run_model(
                    args.llama_cli,
                    args.model,
                    srt,
                    output_dir,
                    run_context,
                    args.max_tokens,
                    args.timeout,
                )
        except subprocess.TimeoutExpired:
            result = {"srt": srt, "timeout": True, "issues": ["timeout"]}
        summary["results"].append(result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    summary_path = output_dir / "summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
