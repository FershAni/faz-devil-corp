import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def prepare_post(platform, version, notes, release_url, project_url):
    if platform == "windows":
        title = f"🖥️ Faz Devil Corp {version} · Windows"
        subtitle = "Архив · EXE + DLL"
        download = "Скачать EXE в ZIP"
        asset = "FazDevilCorp-Windows-x64.zip"
    else:
        title = f"📱 Faz Devil Corp {version} · Android"
        subtitle = "Тестовая сборка · APK"
        download = "Скачать APK"
        asset = "FazDevilCorp-Android-Test.apk"

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
    tag = release_url.rsplit("/", 1)[-1]
    buttons = {"inline_keyboard": [
        [{"text": download, "url": f"{project_url}/releases/download/{tag}/{asset}"}],
        [{"text": "GitHub проекта", "url": project_url}],
    ]}
    return caption, buttons


def main():
    platform = sys.argv[1]
    if platform not in ("windows", "android"):
        raise SystemExit("Unknown release platform")
    if not os.getenv("BOT_TOKEN") or not os.getenv("CHAT_ID"):
        raise SystemExit("Configure TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID.")
    caption, buttons = prepare_post(
        platform, os.environ["VERSION"].removeprefix("v"), os.environ["NOTES"],
        os.environ["RELEASE_URL"], os.environ["PROJECT_URL"],
    )
    photo = Path(__file__).parent / "release-images" / f"{platform}.jpg"
    result = subprocess.run(
        ["curl", "-s", "--max-time", "60",
         "--form-string", f"chat_id={os.environ['CHAT_ID']}",
         "--form-string", f"caption={caption}",
         "--form-string", "parse_mode=HTML",
         "--form-string", f"reply_markup={json.dumps(buttons)}",
         "-F", f"photo=@{photo};type=image/jpeg",
         f"https://api.telegram.org/bot{os.environ['BOT_TOKEN']}/sendPhoto"],
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

    message = response["result"]
    username = message["chat"].get("username")
    message_id = message["message_id"]
    link = f"https://t.me/{username}/{message_id}" if username else f"ID {message_id}"
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
        summary.write(f"Telegram ({platform}): {link}\n")


if __name__ == "__main__":
    main()
