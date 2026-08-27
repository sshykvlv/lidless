# Papercuts

## 2026-08-26 22:20 — GPT-5.6 Sol
Инвентаризировал существующие build/install/release-файлы перед планированием → общий цикл чтения попытался открыть предполагаемые `uninstall.sh` и `entitlements.plist`, которых в репозитории нет, и добавил два шумных `sed`-сообщения. В будущих проходах сначала брать фактический список через `rg --files`, затем читать только существующие пути.

## 2026-08-26 22:27 — GPT-5.6 Sol
Проверял релизные потребители из `dev/lidless` как предполагаемый отдельный репозиторий → каталог оказался частью git-root `/Users/sashayakovlev`, и `git status` напечатал огромный список всего домашнего каталога. Перед repo-командами в соседних проектах сначала проверять `git rev-parse --show-toplevel`; лендинг Lidless не имеет собственного remote и не должен входить в git-релизный план.

## 2026-08-26 22:31 — GPT-5.6 Sol
Проверял команды нового XcodeGen-плана → `xcodegen generate --project` принимает каталог назначения, хотя имя флага легко принять за путь к `.xcodeproj`. Плановая команда с `/tmp/Lidless-contract.xcodeproj` создала бы неверное ожидание пути; использовать отдельный каталог и затем `<каталог>/Lidless.xcodeproj`.

## 2026-08-26 22:32 — GPT-5.6 Sol
Вносил несколько самопроверочных исправлений в длинный implementation plan одним `apply_patch` → весь патч отклонился из-за одного неточного Markdown-якоря возле XPC-раздела. Для документов такого размера применять независимые маленькие патчи с контекстом из свежего `sed`, чтобы одна разница не блокировала остальные правки.

## 2026-08-26 22:34 — GPT-5.6 Sol
Запускал терминологическую проверку покрытия двух plan-файлов → сохранил оба пути в одну строковую переменную и передал её `rg` в кавычках, поэтому `rg` воспринял их как один несуществующий путь и напечатал ложный список missing. Для нескольких файлов использовать массив аргументов или безопасный glob, а не одну quoted-строку.

## 2026-08-26 22:35 — GPT-5.6 Sol
Запускал обязательный независимый `codex exec` challenge для архитектурного плана → `/usr/local/bin/codex` завершился с `spawn .../vendor/aarch64-apple-darwin/codex/codex ENOENT`: глобальный npm-пакет не имеет рабочего Darwin vendor-бинарника. Сначала `find` показал `x86_64-apple-darwin/codex/codex`, но прямой fallback вернул пустой вывод, после чего тот же путь уже отсутствовал при `ls`/`file`; challenge не состоялся. Глобальную установку Codex нужно переустановить с корректным arm64 vendor bundle и проверять непустой вывод/exit, а не считать прямой fallback успешным.

## 2026-08-26 22:49 — GPT-5.6 Sol
Объединил три финальных Markdown-check в один JavaScript `functions.exec` с насыщенным shell-экранированием → V8 отклонил wrapper с `SyntaxError: Invalid or unexpected token` до запуска команд. Для regex-heavy shell-проверок использовать отдельные короткие `exec_command` вызовы или заранее проверенные строки вместо сложного `Promise.all`-wrapper.

## 2026-08-26 22:52 — GPT-5.6 Sol
Готовил `.worktrees/` по workflow и опирался на `rg --files`, который без `--hidden` не показал tracked `.gitignore` → `apply_patch Add File` фактически заменил 23 существующие ignore-строки одной, и отдельный commit успел уйти в remote. Ошибка обнаружена сразу по появившимся untracked build-артефактам; восстановил содержимое из `HEAD^`, добавив только новые ignore-правила, без удаления пользовательских файлов. Перед созданием любого dotfile всегда проверять `git ls-files <path>` и `test -e`, а не `rg --files` по умолчанию.

## 2026-08-26 23:03 — GPT-5.6 Sol
Добавлял XcodeGen-каркас и полностью заменял старый `build.sh` одним патчем → `apply_patch` отверг запрос, потому что один файл нельзя одновременно пометить `Delete File` и `Add File` в пределах одного патча. Конфигурационные файлы и скрипт нужно патчить отдельными операциями либо заменять скрипт через обычный `Update File`.

## 2026-08-26 23:04 — GPT-5.6 Sol
После замены `build.sh` через отдельные Delete/Add операции запустил его напрямую → новый файл потерял executable bit и завершился `permission denied` до Xcode-сборки. После полных замен скриптов нужно сразу восстанавливать и проверять режим `+x` до запуска.

## 2026-08-26 23:05 — GPT-5.6 Sol
Запускал первый XCTest после генерации проекта с намеренно ещё не реализованным `BuildMarker` → пустой каталог `Sources/LidlessCore` не породил Swift-модуль, поэтому компилятор остановился раньше на `unable to resolve module dependency: LidlessCore`. Для test-first каркаса статической библиотеки нужен хотя бы пустой module-root файл, прежде чем можно получить предметный RED теста.

## 2026-08-26 23:06 — GPT-5.6 Sol
Повторял test-first сборку после появления Core-модуля → Swift 6 остановил весь scheme на bootstrap-приложении: глобальная константа `delegate` имела internal-доступ при private-типе `BootstrapAppDelegate`. Пометил lifetime-константу `private`, чтобы тестовый scheme мог дойти до целевого RED.

## 2026-08-26 23:07 — GPT-5.6 Sol
Запускал точечный unit-тест через схему, где приложение было помечено `all` → Xcode параллельно собирал app/helper и отменил тест из-за unrelated app build errors. Для hostless `LidlessCore`-тестов схема должна собирать app только для run/profile/archive/analyze, а test action — только `LidlessTests` и его Core-зависимость.

## 2026-08-26 23:07 — GPT-5.6 Sol
Генерировал `.build/Lidless.xcodeproj` из корневого `project.yml` → XcodeGen корректно разрешил source groups, но оставил `info.path`, entitlements и `$SRCROOT` post-build относительно каталога с `.xcodeproj`, из-за чего искался `.build/Config/Lidless-Info.plist`. Для non-source путей в проекте под `.build` требуется явный `../Config/...`.

## 2026-08-26 23:08 — GPT-5.6 Sol
Проверял universal app/helper после успешной Release-сборки → вызвал `lipo -verify_arch arm64 x86_64 <file>`, хотя эта операция требует входной файл до команды, и wrapper завершился `unknown architecture specification flag`. Использовать `lipo <file> -verify_arch arm64 x86_64` и оставлять проверку внутри build gate.

## 2026-08-26 23:09 — GPT-5.6 Sol
Проверял metadata первого universal XcodeGen bundle → `info.path` без `info.properties` заставил XcodeGen молча перезаписать исходный plist дефолтами `1.0/1`, одновременно убрав `LSUIElement` и icon keys, хотя build settings были `1.1.0`. Все обязательные Info.plist свойства нужно декларативно держать в `project.yml` и проверять уже в собранном bundle.

## 2026-08-26 23:10 — GPT-5.6 Sol
Добавлял Info.plist properties и papercut одной правкой → лишний пустой hunk-маркер перед вторым файлом сделал весь `apply_patch` невалидным. В многофайловых патчах после последней строки hunk сразу начинать следующий `Update File`, не вставляя отдельный `@@` без контекста.

## 2026-08-26 23:11 — GPT-5.6 Sol
Исправил Xcode build path на `../Config` и повторил генерацию → XcodeGen трактовал тот же путь относительно spec и создал `Lidless-Info.plist` с entitlements в соседнем `.worktrees/Config`, тогда как Xcode трактовал его относительно `.build/Lidless.xcodeproj`. Удалил ровно эти два generated-файла; generation path оставил `Config/...`, а build path задал отдельно через `INFOPLIST_FILE` и `CODE_SIGN_ENTITLEMENTS`.

## 2026-08-26 23:11 — GPT-5.6 Sol
Metadata gate нашёл отсутствующий `LSUIElement`, но `set -e` не остановил `build_app` на ложном `[[ ... ]]` внутри функции, вызванной из ветки `case`, поэтому wrapper продолжил подпись и установку локального артефакта. Критические bundle-проверки теперь используют helper с явным сообщением и `return 1`, а не полагаются на неоднозначную Bash `errexit`-семантику.

## 2026-08-26 23:13 — GPT-5.6 Sol
Включил Apple Development signing после RED-проверки отсутствующего Team ID → XcodeGen `entitlements.path` имел приоритет над явным `CODE_SIGN_ENTITLEMENTS` и снова указывал Xcode на несуществующий `.build/Config/Lidless.entitlements`. Убрал дублирующий XcodeGen entitlements-блок; tracked plist остаётся, а его build path задаётся единственным явным setting.

## 2026-08-26 23:20 — GPT-5.6 Sol
Компилировал POSIX atomic-journal слой на Xcode 26.6 → и квалифицированный `Darwin.open(...)`, и затем прямой неквалифицированный `open(...)` в Xcode target разрешались в недоступную variadic C-функцию, хотя standalone `swiftc` видел overlay. Надёжное разрешение — сначала присвоить `Darwin.open` явно типизированной 2- или 3-аргументной function reference и вызвать её; остальные неvariadic syscalls можно оставить квалифицированными.

## 2026-08-26 23:29 — GPT-5.6 Sol
Сверял существующие Core-типы перед реализацией XPC → дважды угадал устаревшие имена файлов (`PowerPolicy.swift`, затем `PowerSource.swift`) вместо актуального `PowerSample.swift`, из-за чего read-only команда оборвалась до остальных файлов. После `rg --files` нужно использовать только найденные пути, не подменять инвентаризацию предположением о структуре.

## 2026-08-26 23:31 — GPT-5.6 Sol
Компилировал failable `NSSecureCoding` initializer, который делегирует в throwing initializer → форма `try? self.init(...)` в Swift 6 была разобрана как использование `self` до обязательной делегации. Для такого перехода нужен явный `do { try self.init(...) } catch { return nil }`.

## 2026-08-26 23:36 — GPT-5.6 Sol
Явно типизировал allowed-class наборы для `NSXPCInterface.setClasses` как `Set<AnyHashable>`, затем попробовал contextual literals → Swift 6 не принимает Class metatypes ни через обычный `Set` initializer, ни прямо в вызове импортированного API. Рабочий bridge для Objective-C `NSSet<Class>` — собрать `NSSet(array: [AnyClass])` и явно привести к импортированному `Set<AnyHashable>`.

## 2026-08-26 23:38 — GPT-5.6 Sol
Компилировал изолированную unsigned XPC-probe fixture → Swift потребовал `private` у top-level `proxy`, потому что inferred-тип ссылается на private Objective-C protocol; кроме того, `|| true` после диагностического `codesign | rg` распространился на всю `&&`-цепочку и замаскировал exit code компилятора. Fixture-compile и необязательную metadata-диагностику нужно запускать отдельными shell-строками.

## 2026-08-26 23:39 — GPT-5.6 Sol
Проверял наличие Swift formatter config и самого formatter одной `&&`-цепочкой → ожидаемо пустой `rg` завершил команду до проверки инструмента. Независимые диагностические проверки нужно разделять строками или явно обрабатывать допустимый no-match.

## 2026-08-26 23:44 — GPT-5.6 Sol
Запустил зелёные `@MainActor` coordinator tests с синхронным `XCTestCase.setUp()` → Xcode 26 выпустил actor-isolation warnings для каждой инициализации, потому что legacy sync override остаётся nonisolated даже у actor-аннотированного test class. Async-throwing `setUp()` сохраняет main-actor isolation и убирает предупреждения.

## 2026-08-26 23:48 — GPT-5.6 Sol
Собирал IOKit notification source по C-header spelling → Swift overlay помечает `kCFRunLoopCommonModes` недоступным и требует `CFRunLoopMode.commonModes`, хотя C API и документация используют старое имя. В Swift-вызовах `CFRunLoopAddSource/RemoveSource` нужен `.commonModes`.

## 2026-08-26 23:49 — GPT-5.6 Sol
Добавил cleanup в `deinit` у `@MainActor` IOKit/XPC/Timer adapters → Swift 6 рассматривает обычный destructor как nonisolated и запрещает читать non-Sendable Foundation/CoreFoundation свойства. Для main-thread cleanup на текущем toolchain нужен `isolated deinit`, а не снятие cleanup или unchecked Sendable у системных объектов.

## 2026-08-26 23:55 — GPT-5.6 Sol
Компилировал legacy-permission table tests → массив octal literals вывелся как `[Int]`, а fixture намеренно принимает `UInt16` как POSIX mode width, поэтому focused test остановился до выполнения. Для таблиц mode нужен явный element type `UInt16`.

## 2026-08-26 23:58 — GPT-5.6 Sol
Добавлял публичный authoritative-observation метод сразу после `HelperEngine.status()` → patch context попал до закрывающей скобки метода, и компилятор увидел `public` в local scope. При вставке рядом с короткими `queue.sync` методами нужно перечитать границы обеих закрывающих скобок до сборки.

## 2026-08-27 00:13 — GPT-5.6 Sol
Собирал menu lifecycle против macOS 26 SDK → `SMAppService.unregister()` импортируется как async, хотя старые примеры и исходный план показывают синхронный вызов; одновременно локальная копия IUO `helperClient` сохранила Optional-тип внутри async refresh. Нужны явный `await` и `guard let` при snapshot захвате клиента.

## 2026-08-27 00:17 — GPT-5.6 Sol
Проверял exit code bounded CLI через zsh-переменную `status` → zsh резервирует её как read-only special parameter, и успешные предшествующие static checks закончились ошибкой harness. Для exit code нужны task-specific имена вроде `lidless_exit`.

## 2026-08-27 00:28 — GPT-5.6 Sol
Форматировал standalone Swift smoke-control fixture с `switch` cases в виде array destructuring (`case ["battery", let value]`) → Swift не поддерживает pattern matching содержимого Array и formatter завершился до build. Для bounded CLI сначала проверять `arguments.count` и индексированные значения.

## 2026-08-27 00:28 — GPT-5.6 Sol
Форматировал UI-правку через `swift-format` → Xcode toolchain содержит formatter, но не добавляет его в shell `PATH`, поэтому команда завершилась `command not found`. В этом проекте вызывать formatter через `xcrun swift-format`.

## 2026-08-27 00:29 — GPT-5.6 Sol
Повторно проверял архитектуры перед локальной установкой → по памяти указал стандартный путь `Contents/Library/LaunchServices/LidlessHelper`, но проект кладёт daemon в `Contents/Library/HelperTools`. Брать вложенный путь из build gate или сначала сверять bundle через `rg --files`.

## 2026-08-27 00:37 — GPT-5.6 Sol
Компилировал IPv4 policy с `compactMap(UInt8.init)` → Swift 6 выбрал неоднозначный zero-argument overload вместо `Substring`-конвертера. Для numeric conversion в higher-order functions нужен явный closure `compactMap { UInt8($0) }`.

## 2026-08-27 00:42 — GPT-5.6 Sol
Сравнивал canonical file URLs напрямую в mount policy → Foundation считает URL с одинаковым `.path`, но разным directory/trailing-slash hint неравными, поэтому валидный read-only fixture был отклонён. Для уже canonicalized локальных путей сравнивать `.path`, а containment проверять с компонентной границей.

## 2026-08-27 00:47 — GPT-5.6 Sol
Компилировал `@Sendable` detach action из плана → closure захватила не-Sendable existential `DiskImageAttaching` и injected `FileManager`, поэтому Swift 6 остановил обе universal slices. Контракт attacher должен явно быть `Sendable` с проверяемой реализацией, а stateless `FileManager.default` лучше получать внутри сериализованного cleanup action, не захватывать instance.

## 2026-08-27 00:50 — GPT-5.6 Sol
Проверял read-only fixture через поиск literal mount path в выводе `/sbin/mount` → `hdiutil` вернул путь под `/var`, а mount table нормализовал его через `/private/var`, поэтому `grep` завершил `set -e` smoke-test без полезного сообщения. Проверять `WritableVolume=false` через структурированный `diskutil info -plist`.

## 2026-08-27 00:52 — GPT-5.6 Sol
Добавил trap для удаления строго проверенного `mktemp` smoke-каталога через `rm -rf` → command safety layer отклонил весь скрипт до запуска как `rm -f style`, несмотря на узкую validated цель. Для одноразовых каталогов в этом окружении использовать `rm -R` без force после prefix-check.

## 2026-08-27 01:05 — GPT-5.6 Sol
Компилировал Security-framework validation по API names из плана → `kSecCSCheckAllArchitectures` импортируется как raw global, не `SecCSFlags.checkAllArchitectures`, а документированный `kSecCodeSignatureRuntime` из `CSCommon.h` вообще не экспортируется Swift overlay. Строить `SecCSFlags(rawValue:)` из первого global и проверять документированный runtime bit `0x10000` явно.

## 2026-08-27 01:10 — GPT-5.6 Sol
Отправлял межпроцессное подтверждение обновления через современный `NotificationCenter.post(...deliverImmediately:)` spelling → у `DistributedNotificationCenter` Swift overlay сохраняет legacy `postNotificationName`, поэтому universal build остановился на extra argument. Использовать его специализированный четырёхаргументный метод.

## 2026-08-27 01:14 — GPT-5.6 Sol
Возобновлял universal build после сжатия контекста по сохранённому process id → PTY-сессия уже была закрыта, а итоговый exit status оказался недоступен. После такого handoff сразу перепроверять сборку новой командой, не полагаясь на старый session id.

## 2026-08-27 01:15 — GPT-5.6 Sol
Собирал callback `DistributedNotificationCenter` под Swift 6 strict concurrency → передача целого Foundation `Notification` внутрь `@MainActor Task` была признана потенциальной гонкой. Извлекать из callback только необходимое Sendable-значение до перехода на actor.

## 2026-08-27 01:17 — GPT-5.6 Sol
Запускал `swift-format lint` на каталогах как formatter-команду → lint требует отдельный `--recursive`, а после исправления выдал большой накопленный style debt в старых файлах. Проверять только изменённые Swift-файлы, чтобы не смешивать текущую работу с существующим форматированием.

## 2026-08-27 01:18 — GPT-5.6 Sol
Механически переименовывал повторяющийся test helper через patch с неверным числом одинаковых hunks → весь patch ожидаемо не применился. Перед массовой заменой сначала считать точные вхождения через `rg`.

## 2026-08-27 01:24 — GPT-5.6 Sol
Заменял `release.sh` одним patch через delete+add → patch engine не принимает две операции над одним путём. Для полной замены существующего файла использовать один `Update File` hunk.

## 2026-08-27 01:27 — GPT-5.6 Sol
Запустил ShellCheck сразу на новых release-скриптах и старом `build.sh` → общий вызов завершился ненулевым статусом как из-за новых замечаний, так и из-за давно существующих `rm -rf`/declare-and-assign предупреждений. Разделять lint по файлам или сразу устранять безопасно локализуемый старый долг.

## 2026-08-27 01:31 — GPT-5.6 Sol
Подключал обязательный `gsd-code-review` workflow → `SKILL.md` ссылается на `~/.Codex/get-shit-done/workflows/code-review.md`, которого нет ни в `.Codex`, ни в `.agents`. Пакету нужен самодостаточный workflow-файл или корректный актуальный путь.

## 2026-08-27 01:50 — GPT-5.6 Sol
Проверял компиляцию приложения через ожидаемую команду `./build.sh build` → скрипт не имеет общего build-action и завершился только usage-подсказкой. Для обычной Debug-сборки здесь нужен `./build.sh smoke-app`, а список действий стоит сделать заметнее в README или `./build.sh --help`.

## 2026-08-27 01:54 — GPT-5.6 Sol
Добавлял RED-тест для нового source-файла одновременно с записью пути в `project.yml` → XcodeGen отклонил spec раньше компиляции, потому что файл ещё не существовал. Для compile-fail TDD с XcodeGen сначала нужен пустой source placeholder, затем тест на отсутствующие символы.

## 2026-08-27 02:01 — GPT-5.6 Sol
Создавал тестовый Downloads-каталог через короткий `FileManager.createDirectory(at:)` → в доступном Foundation overlay нет такого convenience overload, и compile-fail скрыл ожидаемый RED assertion. Всегда передавать `withIntermediateDirectories` явно.

## 2026-08-27 02:08 — GPT-5.6 Sol
Запускал обязательный `gsd-ship` для оформления PR → `SKILL.md` ссылается на `~/.Codex/get-shit-done/workflows/ship.md`, которого нет. Ship-пакету нужен самодостаточный workflow-файл или актуальный путь; до исправления остаётся ручной эквивалент с теми же gate-проверками.
