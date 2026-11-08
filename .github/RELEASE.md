# Релиз из чата Codex

Пример запроса: «Выпусти тестовый релиз v0.3.0-beta.1 из изменений игрового меню. Опубликуй в GitHub и Telegram».

1. Проверь статус Git, выбери изменения по запросу и составь список для игроков на русском по сравнению с предыдущим релизом. Закоммить выбранные файлы и отправь коммит в GitHub. Workflow должен быть в основной ветке репозитория.
2. Проверь, что тег свободен. Выбери целый `android_version_code` больше, чем у предыдущего опубликованного APK (в исходном пресете сейчас 2). Передай GitHub CLI JSON через stdin, чтобы сохранить переносы строк в списке изменений.
3. Дождись завершения через `gh run watch <run-id> --exit-status`. В Summary есть URL GitHub и ссылки на оба поста для публичного Telegram-канала. Если упал только Telegram, сначала проверь, какие посты появились в канале, затем при необходимости перезапусти только упавшие jobs через `gh run rerun <run-id> --failed`.

```powershell
@{
  version = 'v0.3.0-beta.1'
  android_version_code = '3'
  notes = "- Исправлено открытие игрового меню."
  publish = 'true'
} | ConvertTo-Json -Compress | gh workflow run release.yml --ref main --json
```

Проверка без публикации: `gh workflow run release.yml --ref main -f publish=false`. В результате будет артефакт `faz-builds`. Windows поставляется как EXE-установщик Inno Setup со всеми нужными DLL. APK для проверки подписывается временным отладочным ключом.

## Настройка публикации

В **Settings → Secrets and variables → Actions** добавь:

| Secret | Значение |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Файл постоянного Android-ключа в Base64 |
| `ANDROID_KEYSTORE_USER` | Псевдоним ключа |
| `ANDROID_KEYSTORE_PASSWORD` | Пароль хранилища и ключа (одинаковый для Godot) |
| `TELEGRAM_BOT_TOKEN` | Токен бота |
| `TELEGRAM_CHAT_ID` | `@имя_канала` или числовой ID |

Чтобы APK устанавливался поверх существующей версии, используй тот же ключ и увеличивай код версии. Добавь бота в администраторы канала с правом публиковать сообщения. Telegram публикует две карточки со скриншотами, списком изменений и кнопками скачивания и GitHub. Скриншоты можно обновить перед релизом в .github/release-images/windows.jpg и .github/release-images/android.jpg.
