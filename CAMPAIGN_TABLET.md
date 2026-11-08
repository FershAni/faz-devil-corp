# Кампания и полевой планшет

## Запуск

Откройте `project.godot` в Godot 4.7.2 и запустите проект клавишей **F6** из `MainMenu.tscn` или **F5** из любой сцены. В **СОЗДАТЬ ИГРУ** выберите один из трёх слотов. Свободный слот создаёт кампанию с первым днём. Занятый показывает день, прогресс квоты и уют. Оба варианта запускают сессию на четыре места. При доступном Steam меню создаёт Steam-лобби. При запуске с `--offline` или без Steam доступны локальный профиль и ENet.

Через **Esc → Сохранить** хост может записать кампанию в один из трёх слотов. Если выбран другой занятый слот, повторное нажатие подтверждает перезапись. После успешной записи автосохранения идут в выбранный слот.

**Tab** открывает планшет во время игры. **R** внутри планшета нужно удерживать три секунды. Хост расходует одну батарею из слотов снаряжения 1–3 и публикует звук замены. Запасную батарею можно купить в существующем магазине. Фонарик и планшет показывают заряд раздельно.

## Сцены в инспекторе

1. В **Project Settings → Autoload** сохраните порядок `SteamNet`, `GameState`, `SaveManager`. Последний загружает кампанию после сброса состояния новой сессии. В **Input Map** действие `toggle_tablet` использует Tab, а `reload_battery` использует R.
2. Откройте `scenes/ui/MainMenu.tscn`. Узел `HostButton` открывает `NetMenu/Root/SaveSlots`. Каждый `SlotN` имеет фиксированный индекс от 1 до 3. Существующая сцена `World` и её анимация продолжают работать под меню.
3. Откройте `scenes/game/Game.tscn`. Сохраните имена `Game`, `Players`, `Spawner` и `UI/Tablet` одинаковыми на всех машинах. `Spawner.spawn_path` указывает на `Players`. `Game` передаёт ссылки на мир, дневную смену и вторжение в `Tablet.configure()`.
4. В `scenes/ui/Tablet.tscn` назначьте `TabletManager.gd` корневому `CanvasLayer`, а `TabletUI.gd` узлу `Root`. Порядок отрисовки внутри `Device` важен. `BackBufferCopy` копирует кадр после отрисовки интерфейса, затем `CRT` применяет `TabletScreen.gdshader`. У `CRT` установите **Mouse → Filter → Ignore**. Панель использует 82% ширины и 80% высоты окна, то есть примерно 65% его площади.
5. В `Pizzeria/DaytimeProps` задавайте каждой покупке устойчивый `prop_id`. Положение сохраняется в координатах этого контейнера. `SecurityOffice` строится скриптом пиццерии. Камера с внутренним ID `5` соответствует кнопке **CAM 05** и цели генератора.

```text
/root
├── SteamNet
├── GameState
├── SaveManager
└── MainMenu [Control · MainMenu.gd]
    ├── World [Node3D · animated backdrop]
    ├── MenuBox [VBoxContainer]
    │   ├── HostButton
    │   └── JoinGameButton
    └── NetMenu [CanvasLayer]
        └── Root [Control]
            ├── Panel [host / search controls]
            ├── SaveSlots [PanelContainer]
            │   └── Margin/Slots [VBoxContainer]
            │       ├── Heading
            │       ├── Slot1
            │       ├── Slot2
            │       └── Slot3
            └── SidePanel [lobbies / friends]

/root/Game [Node3D · game.gd]
├── Players [Node3D]
│   └── Player<peer_id> [spawned by host]
│       ├── Sync [owner replicates avatar movement]
│       └── SpawnGate [host controls spawn visibility]
├── Spawner [MultiplayerSpawner]
├── Level [LevelGenerator.gd · walls, doors, scrap]
├── Pizzeria
│   ├── DaytimeProps
│   └── SecurityOffice [runtime · CCTV SubViewport]
├── Daytime [DaytimeManager.gd]
├── HubInvasion [HubInvasion.gd]
└── UI
    └── Tablet [CanvasLayer · TabletManager.gd]
        └── Root [Control · TabletUI.gd]
            ├── Dim
            └── Device [Panel]
                ├── Margin/Column
                │   ├── Header [Title, Battery, Close]
                │   ├── Rule
                │   ├── Body [HBoxContainer]
                │   │   ├── Roster [VBoxContainer · runtime crew rows]
                │   │   └── Views [Control · views built by TabletUI]
                │   │       ├── Night [TabletMap, Scan Area, Ping Transport]
                │   │       ├── CCTV [Feed, Camera Matrix, Play Audio, EMP]
                │   │       └── Daytime [Orders, Diagnostics, Stage Controls]
                │   └── Footer
                ├── Readback [BackBufferCopy]
                └── CRT [ColorRect · ShaderMaterial]
```

## Что хранит слот

- `user://saves/<host_steam_id>/slot_1.cfg` … `slot_3.cfg`. Для ENet без Steam используется профиль `offline`. На диске сохраняются день, индекс квоты, цель, выручка от груза, долг, уют, касса, последние итоги смены, ожидающее вторжение и кошельки по SteamID. Для офлайн-хоста сохраняется локальный кошелёк.
- Запись декора в `decorations_json` содержит `item_id`, массив `grid_position` из трёх координат и `damaged`. Исходная мебель сохраняет поломки отдельно. Купленные объекты восстанавливаются по ID из каталога сцены.
- Дневной отчёт и продажа груза выполняют синхронную запись на хосте перед публикацией результата. При сбое продажи выплата и переход дня откатываются. Дневная смена ждёт повторной записи. `.bak` хранит предыдущую версию и используется при прерывании замены основного файла. Личные заряды, аватары и незавершённые вылазки создаются заново при открытии кампании.
- После сетевой аутентификации `SaveManager.sync_global_game_state` передаёт надёжный снимок. Новый клиент подтверждает его после готовности сцены `Game`. Только затем хост открывает этому пиру видимость аватаров и создаёт его персонажа. Владельцы аватаров начинают отправлять движение новому клиенту после подтверждения, что у него уже появились соответствующие узлы. [Godot MultiplayerSynchronizer](https://docs.godotengine.org/en/4.7/classes/class_multiplayersynchronizer.html)

## Команды планшета

| Фаза | Действие | Серверный результат |
| --- | --- | --- |
| Night Scavenge | **Scan Area** | 2% заряда. Открывает контуры стен, проёмы и лом в пределах 15 м от позиции игрока, которую видит хост. Исследованные ячейки живут до смены карты. |
| Night Scavenge | **Ping Transport** | Маяк транспорта на 10 секунд для всей команды. |
| Hub Invasion | **Play Audio** | 4% заряда. Пространственная запись смеха в выбранном секторе отвлекает The Glitch до его выхода к генератору. |
| Hub Invasion | **EMP Trigger** | 10% заряда. CAM 05 очищает сеть, когда The Glitch находится на генераторе. |
| Daytime Shift | **Vent Cooling** | 8% заряда. Охлаждает исправный установленный аниматроник и использует общий таймер охлаждения с кнопкой у сцены. |

Дневные таймеры, ремонты и температура берутся из `DaytimeManager`. Диагностика показывает 100% для исправного объекта и 0% для неисправного по существующей двоичной модели обслуживания. Локальная камера включает размытие глубины резкости в Forward+ при открытии планшета. CRT получает время ответа хоста и расстояние до угрозы. Игровая симуляция продолжает работать при открытом интерфейсе.

Проект использует GodotSteam 4.23.2 и тестовый Steam App ID 480 из `application/config/steam_app_id`. Для публичного релиза требуются App ID игры, сборка GodotSteam с исправлением подмены peer ID и проверка подключения между Steam-аккаунтами. [Отчёт о подмене peer ID](https://www.openwall.com/lists/oss-security/2026/11/04/11)

