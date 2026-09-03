# AuctionatorFS
### _Патч для Firestorm 11.1.5 (The War Within)_

Auctionator — аддон для повседневного использования аукционного дома. Делает аукцион проще: наглядное отображение лотов, удобное размещение и управление аукционами.

Это пропатченная версия Auctionator v305, адаптированная для приватного сервера **Firestorm**, где ряд стандартных API-функций аукционного дома Blizzard не работает.

##### Версия: `305` (оригинал для Retail/Cata/Classic, патч для Firestorm 11.1.5)
##### Оригинальные авторы: `plusmouse`, `Borjamacare`
##### [Ссылка на оригинальную версию на CurseForge](https://www.curseforge.com/wow/addons/auctionator/files/7289934)

---

## Проблемы API на Firestorm (зачем нужен патч)

На Firestorm 11.1.5 следующие стандартные API-функции Blizzard сломаны:

| API-функция | Статус |
|---|---|
| `C_AuctionHouse.ReplicateItems()` | ✅ Работает! Возвращает данные мгновенно без события |
| `C_AuctionHouse.SendBrowseQuery()` | ❌ Не вызывает события и не возвращает результаты |
| `C_AuctionHouse.SendSearchQuery()` | ❌ Возвращает 0 результатов |
| `C_AuctionHouse.SearchForItemKeys()` | ⚠️ Работает визуально, но не заполняет кэш результатов API |
| `C_AuctionHouse.GetBrowseResults()` | ⚠️ Возвращает только то, что отображается в UI |
| `AuctionHouseFrame.SearchBar.SearchButton:Click()` | ✅ Запускает реальный поиск |
| `AuctionHouseFrame.BrowseResultsFrame.browseResults` | ✅ Содержит актуальные результаты |
| `C_AuctionHouse.RequestMoreBrowseResults()` | ✅ Работает для пагинации (500 предметов за запрос) |
| `C_AuctionHouse.HasFullBrowseResults()` | ✅ Определяет завершение загрузки |

---

## Изменения патча

### 1. IncrementalScan — полностью фоновый скан через ReplicateItems
**Файл:** `Source_ModernAH/IncrementalScan/Mixins/Frame.lua`

`C_AuctionHouse.ReplicateItems()` на Firestorm работает и возвращает данные мгновенно (без события `REPLICATE_ITEM_LIST_UPDATE`). Данные сохраняются в памяти при переключении вкладок. Это позволяет сканировать полностью в фоне:

- Вызов `ReplicateItems()` + чтение через `GetReplicateItemInfo()`/`GetReplicateItemLink()`
- Обработка батчами по 200 предметов с минимальной задержкой (0.01с) — не фризит UI
- Асинхронная загрузка данных предметов через `LoadItemData` для незакэшированных
- Пользователь может свободно пользоваться аукционом во время сканирования

### 2. FullScan — перенаправление на IncrementalScan
**Файл:** `Source_ModernAH/FullScan/Mixins/Frame.lua`

Кнопка Full Scan перенаправляет на IncrementalScan, который использует `ReplicateItems()` в фоновом режиме.

### 3. Database — ленивая десериализация CBOR
**Файл:** `Source/Database/Mixin.lua`

`AUCTIONATOR_PRICE_DATABASE` хранит данные по предметам в виде CBOR-строк. На Firestorm инициализация базы помечает записи как десериализованные (`version = 2`), но многие записи остаются сырыми строками, что вызывает краши в `SetPrice`/`GetPrice`.

Исправление: добавлена ленивая десериализация CBOR (с `pcall` и фоллбэком на `LibCBOR`) во всех функциях доступа к базе:
- `SetPrice`
- `GetPrice`
- `GetPriceHistory`
- `GetPriceAge`
- `GetMeanPrice`

### 4. IncrementalScan Frame XML
**Файл:** `Source_ModernAH/IncrementalScan/Frame.xml`

Удалён `<OnEvent method="OnEvent"/>` — обработка событий теперь через `SetScript` в Lua, чтобы избежать конфликтов с polling-подходом.

### 5. Поиск из списка покупок (Shopping) — локальный поиск по данным ReplicateItems
**Файлы:** `Source_ModernAH/Search/Mixins/DirectSearchProviderMixin.lua`, `Source_ModernAH/Search/Mixins/KeywordSearchProviderMixin.lua`, `Source_ModernAH/IncrementalScan/Mixins/Frame.lua`

`C_AuctionHouse.SendBrowseQuery()` на Firestorm не возвращает результатов, а обход через `SearchButton:Click()` выкидывает пользователя из вкладки Shopping в стандартный поиск — оба пути отброшены.

Вместо этого поиск работает локально по данным аукциона, которые уже собирает скан:
- Full Scan/IncrementalScan при завершении кэширует сырые данные `ReplicateItems` в `Auctionator.State.ReplicateCache` (имя, itemID, цена, количество, владелец, itemLink)
- Поиск по терму фильтрует кэш на клиенте: по подстроке имени (без регистра), качеству, min/max уровню; цена считается за единицу (`buyoutPrice / count`)
- Дубликаты одного предмета схлопываются в строку: `minPrice` = минимум, `totalQuantity` = сумма
- Если кэша нет (скан не запускали) — фоллбэк на живой проход по `GetReplicateItemInfo()`, при пустых данных делается `ReplicateItems()` и повтор через 3 секунды
- Результаты идут дальше по штатному конвейеру фильтров Auctionator (цена, ilvl, точный поиск, экспансия — всё клиентское)

Важно: поиск отражает состояние аукциона на момент последнего скана. Перед поиском актуальных цен запускайте Full Scan.

---

## Результаты сканирования

- ~36000 аукционов просканировано через ReplicateItems
- Сканирование полностью фоновое — не влияет на UI, можно пользоваться аукционом
- Обработка занимает несколько секунд (батчи по 200 предметов)
- Тултипы корректно отображают цены после сканирования

---

## Как использовать

1. Откройте Аукционный дом
2. Перейдите на вкладку **Buy** или **Sell**
3. Нажмите кнопку **Full Scan**
4. Сканирование запустится полностью в фоне

Можно сразу пользоваться аукционом — переключать вкладки, искать предметы, выставлять лоты. Сканирование не влияет на UI и завершится автоматически.

---

## Известные ограничения

- **Вкладка Buying (стандартный Browse Blizzard)** — поиск там скорее всего не работает, т.к. `SendSearchQuery`/`SendBrowseQuery` сломаны на Firestorm. Список покупок (Shopping) исправлен патчем №5
- **Поиск Shopping зависит от скана** — без свежего Full Scan результаты могут отставать от реальных лотов
- **Ошибка на вкладке Selling** — `TableKeys.lua:3: bad argument #1 to 'pairs'` может возникать при клике на предметы в сумке (не связано со сканированием)
- **Событие REPLICATE_ITEM_LIST_UPDATE** — не приходит, но данные доступны сразу после вызова `ReplicateItems()`

---

## Установка

1. Скачайте или клонируйте репозиторий
2. Поместите папку в `Interface/AddOns/` (переименуйте в `Auctionator`)
3. Перезапустите игру или `/reload`

---

## Лицензия

См. [LICENSE](LICENSE).
