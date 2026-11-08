import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ASSETS = {
    "windows": "FazDevilCorp-Windows-Setup.exe",
    "android": "FazDevilCorp-Android-Test.apk",
}


def prepare_post(platform, version, notes, download_url, project_url):
    if platform == "windows":
        title = f"🖥️ Faz Devil Corp {version} · Windows"
        subtitle = "Установщик · EXE"
        download = "Скачать EXE"
    else:
        title = f"📱 Faz Devil Corp {version} · Android"
        subtitle = "Тестовая сборка · APK"
        download = "Скачать APK"

    lines = [
        "• " + re.sub(r"^(?:[-*•]|\d+[.)])\s+", "", line.strip())
        for line in notes.splitlines() if line.strip()
    ]
    changes = "\n".join(lines)
    # Leave room for both headings and count emoji as two UTF-16 units.
    encoded = changes.encode("utf-16-le")
    if len(encoded) > 1700:
        changes = encoded[:1700].decode("utf-16-le", errors="ignore").rstrip()
        changes += "…\nПолный список изменений на GitHub."
    caption = (
        f"<b>{html.escape(title)}</b>\n{subtitle}\n\n"
        f"<b>Что изменилось</b>\n{html.escape(changes)}"
    )
    buttons = {"inline_keyboard": [
        [{"text": download, "url": download_url}],
        [{"text": "GitHub проекта", "url": project_url}],
    ]}
    return caption, buttons


def telegram(method, fields, attachment=None):
    args = ["curl", "-s", "--max-time", "180"]
    for key, value in fields.items():
        args.extend(["--form-string", f"{key}={value}"])
    if attachment:
        args.extend(["-F", f"{attachment[0]}=@{attachment[1]}"])
    result = subprocess.run(
        [*args, f"https://api.telegram.org/bot{os.environ['BOT_TOKEN']}/{method}"],
        capture_output=True,
    )
    if result.returncode:
        raise SystemExit(f"Telegram connection failed (curl exit {result.returncode}).")
    try:
        response = json.loads(result.stdout)
    except ValueError:
        raise SystemExit("Telegram returned an invalid response.") from None
    if not response.get("ok"):
        raise SystemExit(response.get("description", "Telegram rejected the post."))

    return response["result"]


def message_link(message):
    chat = message["chat"]
    message_id = message["message_id"]
    if chat.get("username"):
        return f"https://t.me/{chat['username']}/{message_id}"
    chat_id = str(chat["id"])
    if chat["type"] in ("channel", "supergroup") and chat_id.startswith("-100"):
        return f"https://t.me/c/{chat_id[4:]}/{message_id}"
    raise SystemExit("Use a Telegram channel or supergroup for message links.")


def summarize(label, link):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
        summary.write(f"{label}: {link}\n")


def main():
    platform = sys.argv[1]
    if platform not in ASSETS:
        raise SystemExit("Unknown release platform")
    if not all(os.getenv(name) for name in ("BOT_TOKEN", "CHAT_ID", "FILES_CHAT_ID")):
        raise SystemExit("Configure Telegram bot, announcement channel and files chat secrets.")
    version = os.environ["VERSION"].removeprefix("v")
    files_chat = telegram("getChat", {"chat_id": os.environ["FILES_CHAT_ID"]})
    if files_chat["type"] not in ("channel", "supergroup"):
        raise SystemExit("The files chat must be a Telegram channel or supergroup.")
    document = telegram("sendDocument", {
        "chat_id": files_chat["id"],
        "caption": f"Faz Devil Corp {version} · {platform.title()}",
    }, ("document", Path("release-files") / ASSETS[platform]))
    download_url = message_link(document)
    summarize(f"Файл ({platform})", download_url)

    caption, buttons = prepare_post(
        platform, version, os.environ["NOTES"], download_url, os.environ["PROJECT_URL"],
    )
    photo = Path(__file__).parent / "release-images" / f"{platform}.jpg"
    message = telegram("sendPhoto", {
        "chat_id": os.environ["CHAT_ID"],
        "caption": caption,
        "parse_mode": "HTML",
        "reply_markup": json.dumps(buttons),
    }, ("photo", photo))
    summarize(f"Telegram ({platform})", message_link(message))


if __name__ == "__main__":
    main()
