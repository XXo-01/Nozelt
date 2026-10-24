# Nozelt Windows: TUN, DNS и маршрутизация — 06.10.2026

**Статус: изменения реализованы, сборка-кандидат для изолированных испытаний.**
Этот отчёт не доказывает отсутствие любых утечек или уязвимостей. Системные
проверки новых WFP-фильтров с захватом пакетов ещё не выполнены. На рабочем ПК
действует Koala Clash: его процессы, TUN, маршруты, DNS и фильтры не менялись.
Nozelt TUN здесь не запускался. Активная portable-папка не обновлялась.

Пользователь уточнил политику: **сохранить явные правила «Напрямую» и устранить
случайные обходы VPN**. DIRECT намеренно показывает получателю настоящий внешний
IP. Сервер VPN всегда знает адрес своего клиента; bootstrap-резолвер видит
запросы имени VPN-сервера. Это необходимые/явные участники соединения.

## 1. Устройство подключения

Windows использует один общий Mihomo/Wintun/gVisor слой в `nozelt_core.dll`:
TUN, fake-IP DNS, правила процессов/доменов/IP/Geo и статистика соединений.
Mihomo-профиль выполняется внутри DLL. Для Xray/sing-box этот слой передаёт
прокси-трафик отдельному процессу через SOCKS5 на IPv4 loopback с новым случайным
паролем при запуске. Дочерний процесс находится в Job Object и привязан к
физическому интерфейсу. Общие DIRECT/REJECT-правила исполняются до SOCKS.

Новая последовательность подключения:

1. Проверить параметры Windows и права администратора; отклонить небезопасную
   сетевую конфигурацию и неподдерживаемый контекст правил.
2. Проверить инвентарь адаптеров. При активном распознанном чужом TUN, включая
   Koala/Meta Tunnel/Wintun/WireGuard, отказать до изменения WFP/маршрутов.
3. Атомарно включить собственную WFP-политику до появления маршрутов Nozelt.
4. Для внешнего ядра защитить частный SOCKS-порт, запустить процесс и проверить
   не просто открытый TCP-порт, а SOCKS-аутентификацию.
5. Создать общий TUN, найти его реальный LUID и добавить разрешение этого
   интерфейса одной WFP-транзакцией. Если идентификация не удалась, остановить
   frontend, сохранив блокировку.

Это описание реализованного порядка вызовов. Правильность фактических Windows
классификаций интерфейса должна быть подтверждена в VM.

## 2. Что было исправлено и добавлено

### Защита системной сети

- Одного `strict-route` недостаточно для защиты после падения хоста. Добавлен
  собственный WFP provider/sublayer с IPv4/IPv6 ALE CONNECT и RECV_ACCEPT.
  Отдельные постоянные фильтры переживают техническую остановку и падение
  процесса. Явное отключение/выход снимают только фильтры Nozelt.
- Базовая политика запрещает обход TUN. Разрешены loopback, точные AppID хоста
  Nozelt и выбранного внешнего ядра, интерфейс Nozelt, ограниченный DHCP.
  При IPv6=true добавлены ограниченные link-local NDP, без публичного ICMP
  исключения и IPv6 redirect. При IPv6=false физический IPv6 запрещён.
- Запреты являются hard block, разрешения soft permit: Nozelt не должен
  отменять запреты Windows Firewall. Это требует проверки арбитража с реальными
  фильтрами ОС/антивируса; модельные тесты не заменяют её.
- Добавлен явный запрет физического TCP/UDP DNS:53 даже для разрешённых
  Nozelt/Xray/sing-box. Loopback и DNS, входящий через разрешённый TUN, отделены.
- У SOCKS UDP нет самостоятельной аутентификации каждого UDP-пакета. Добавлены
  более приоритетные правила частного IPv4 relay-порта: посторонние приложения
  не могут использовать его для обхода своих правил процессов. Проверка
  IPv4-mapped IPv6 на настоящем Windows остаётся в матрице испытаний.
- Замена фильтров и снятие защиты выполняются транзакциями с rollback; не
  создаётся промежуточного состояния без своей политики. Перечисляются только
  собственные четыре ALE-слоя, без разбора фильтров Koala/других драйверов.
- Идентификаторы до 512 фильтров зарезервированы и воспроизводимы. Добавлены
  `nozelt-network-recovery.exe --release` и независимый
  `recover_windows_network.ps1`, использующий штатный `fwpuclnt.dll`.
  PowerShell-восстановление работает без EXE/DLL приложения, например после
  карантина Defender. Оно не сбрасывает общий firewall/DNS/маршруты.
- На новом запуске обнаруживается оставшаяся защита. UI сообщает, что VPN
  отключён, но сеть защищена; пункт «Выключить TUN» позволяет её снять.
  Цвет иконки по-прежнему относится к подключению, а tooltip отдельно
  описывает удерживаемую блокировку.

### DNS

- В Windows перехватываются **UDP и TCP** запросы на порт 53. Используется fake-IP.
- Обычное разрешение назначения, включая сайты из явных DIRECT-правил, идёт
  через выбранные зашифрованные IP-literal резолверы с `#PROXY`. DIRECT меняет
  путь прикладного трафика, а не переключает DNS к провайдеру интернета.
- Только имена транспортных серверов разрешаются отдельными выбранными
  зашифрованными bootstrap-резолверами на физическом интерфейсе.
  При недоступности выбранных резолверов системного/plaintext fallback нет.
- Для Xray bootstrap выделен внутренними DNS tags/inboundTag. Убрано широкое
  исключение по IP резолвера, которое могло отправлять туда сторонний трафик
  напрямую. Остальной встроенный DNS направлен через безопасный proxy/balancer;
  EDNS client IP удаляется, bootstrap domain match не переходит в иной fallback.
- Xray не подменяет выбранные DoT/DoQ случайным DoH. Если среди выбранных DNS
  нет HTTPS, профиль отклоняется с требованием настроить поддерживаемый DoH.
- В sing-box разделены proxy destination DNS и физический bootstrap. Для
  удалённых outbound-адресов задаётся bootstrap domain resolver, для DIRECT
  назначения — proxy DNS. Bind interface не ставится одновременно с detour.
- При IPv6=false Windows-конфигурация отключает не только AAAA DNS, но и
  общий IPv6; WFP-политика также закрывает физический IPv6.

### Маршрутизация

- Исправлен потерянный при импорте Clash YAML раздел маршрутизации. Один
  whitelist snapshot `providerRouting` сохраняет rules, proxy-groups,
  rule-providers, sub-rules и соответствие имён узлов в зашифрованном профиле.
  Контроллеры, DNS, listeners и прочие сервисы исходного YAML не импортируются.
- Метаданные сохраняются при добавлении файла/подписки/текста и при обновлении
  подписки. У старых профилей, ранее утративших эти данные, нужно обновить
  подписку либо повторно импортировать файл; восстановить удалённый оригинал
  без повторного получения невозможно.
- Режим «По правилам»: общие пользовательские правила и разрешённая LAN-политика
  идут перед правилами провайдера. Явный DIRECT/REJECT и terminal MATCH
  провайдера сохраняются. Если terminal отсутствует, остаётся MATCH,PROXY.
- Режим «Глобально»: правила провайдера больше не могут включить DIRECT;
  весь прикладной трафик отправляется в безопасный proxy/balancer.
- Имена provider-групп переименовываются без конфликта с Nozelt PROXY. Учтена
  грамматика MATCH, regex, логических правил, SUB-RULE и дополнительных IP
  параметров, включая `no-resolve`, при замене целевого имени.
- Из автоматических URL-test/fallback/load-balance групп убраны ветки,
  способные незаметно выбрать DIRECT/PASS/COMPATIBLE. То же сделано с Xray
  balancer fallback и sing-box URL-test. Без безопасного транспорта — отказ;
  явные ручные DIRECT-правила/выборы в provider select сохранены.
- Процессы Windows разрешаются в общем TUN для всех трёх ядер. Если настроена
  process policy (включая потенциальную classical rule-provider policy),
  неизвестный владелец блокируется до дальнейших правил. Короткое соединение
  больше не может из-за отсутствующего owner попасть в последующий DIRECT.
- Provider-правила процессов/user, исходного IP/порта и прежнего inbound из
  native sing-box/Xray не могут надёжно видеть исходный контекст после SOCKS.
  Они отклоняются с понятным сообщением; правила процессов необходимо задать
  на странице маршрутизации Nozelt, неподдерживаемые source/inbound условия
  следует удалить или переработать. Это ограничение
  архитектуры, а не подтверждение поддержки всех правил любых конфигураций.
- Дополнительно sing-box runner проверяет декодированные metadata rule sets:
  process/package и source IP/port predicates блокируются при первой загрузке SRS/JSON и при
  обновлениях удалённых списков. Недопустимое обновление не заменяет последний
  допустимый набор. Исходный DNS validator делегируется и не отключается.
  Для source predicates используется минимальное расширение metadata в
  локальной копии sing-box v1.14.2, описанное в `native-cores/third_party/sing-box/NOZELT.md`.
- При замене Xray TUN-inbound на внутренний SOCKS сохраняется включённый
  Nozelt sniffing: правила протоколов/доменов не теряют эту настройку.
- HTTP rule-provider требует HTTPS, скачивается через PROXY и получает
  собственный относительный cache path в portable core data. Arbitrary path
  исходного профиля не используется. Внешние local rule files отклоняются.
  Native sing-box remote rule sets используют HTTPS и защищённый download
  detour; local files отклоняются. В global mode неиспользуемые rule sets удалены.
- Простое изменение rules не останавливает внешний transport. Любая попытка
  изменить TUN/IPv6 через rules-only reload отклоняется: нужен защищённый
  restart. После reload проверяется актуальная идентичность TUN.

### Стабильность, перезапуск и интерфейс состояния

- После падения Xray/sing-box попытки восстановления больше не прекращаются
  после трёх ошибок: они продолжаются с задержкой 2/4/8/16/32 секунды,
  без частого бесконечного цикла. Изменение underlay сбрасывает задержку.
- Во время восстановления остаются общий TUN и защита. Ошибка обновления
  frontend не записывается как успешное восстановление.
- Flutter не разбирает штатное восстановление transport как «VPN погиб» после
  трёх опросов и не уничтожает сохранённый frontend. Показан статус восстановления.
- Опрос состояния/трафика использует последний готовый snapshot, когда native
  recovery удерживает lock. Долгая проверка дочернего ядра не блокирует эти
  вызовы на весь период startup timeout.
- Техническая остановка отделена от пользовательского выключения:
  `NozeltStopForRestart` сохраняет WFP и существующий in-process fake-IP pool.
  Замена конфигурации не должна открыть прямой интернет между Stop/Start.
- Перезапуск приложения из трея сохраняет блокировку и передаёт новому
  экземпляру `--connect-once`, если подключение/защита были активны. При ошибке
  запуска нового процесса старый пробует восстановить свой runtime.
  Полный перезапуск EXE пересоздаёт TUN и теряет RAM DNS/сессии: бесшовное
  сохранение всех соединений этим не обещается.
- После неудачного подключения UI сохраняет native сведения о защите и
  сообщает, как повторить подключение либо явно снять блокировку в трее.
  «Выйти» снимает также удерживаемую после ошибки защиту.

### TLS, журналы и зависимости

- Windows отказывается от `skip-cert-verify`, `allowInsecure`, `insecure=true`
  и аналогичного отключения проверки TLS в обычных/native профилях.
  Неверный сертификат нужно исправить; тихого обхода проверки больше нет.
  Это не превращает сознательно выбранный plaintext proxy-протокол в TLS.
- У внешних ядер принудительно ограничен уровень журналирования и отключены
  provider log-file/DNS log настройки; убраны provider API/metrics/experimental
  listeners/cache. URL userinfo/path/query и credential-bearing diagnostic
  objects очищаются перед попаданием в desktop log/export.
- Mihomo 1.19.32 / sing-box 1.14.2 / Xray 26.9.30 / Wintun 0.14.1 сохранены как
  доступные выбранные core-релизы, но **бинарники пересобраны с security overlays**:
  core Go 1.26.8; sing-box Go 1.26.8, x/crypto 0.56.0, grpc 1.83.2,
  chi 5.3.0, x/mod 0.40.0; Xray Go 1.27.1, compress 1.18.7,
  grpc `1.85.0-dev.0.20260825072537-93e31b48545e` (исправленный upstream commit).
  В common core также обновлены compress 1.18.7 и DHCP до исправленного commit.
- Сканер Go vulnerabilities обновлён для анализа Go 1.27. Три source scans
  с соответствующими build tags показывают **0 reachable и 0 imported-package
  vulnerabilities**. В каждой module graph остаётся уведомление об
  unmaintained `x/crypto/openpgp`, который не импортируется/не вызывается.
  Результат зависит от текущей базы и анализа: это не доказательство отсутствия
  неизвестных ошибок, ошибок конфигурации или уязвимостей Windows/Wintun.

## 3. Проверки и их точные пределы

Сборочные журналы находятся в `../output/security-audit/`. Host baseline содержит
локальные адреса и не включается в portable-архив/публичный отчёт.

| Проверка | Результат/что доказывает |
|---|---|
| Flutter analyze | Без замечаний после финальных исправлений |
| Полный Flutter suite | 158 тестов; включает общий Android UI reference и desktop goldens |
| Go with_gvisor | Пакеты core/networkguard/windowsdll проходят; WFP VM test пропущен |
| Go race core/windowsdll и sing-box runner | Прошли без обнаруженных гонок |
| Реальные Windows TCP/UDP owner APIs | Определён собственный процесс тестового сокета |
| Настоящие Mihomo matcher tests | Process case/boundary, domain exact/suffix/keyword, IPv4/IPv6 CIDR, порядок/default, unknown owner |
| Bundled Geo matcher | GEOIP CN fixture, GEOSITE Google fixture и проверка границы домена |
| Policy decision tests | Модель intended WFP allow/block, ownership/lifetime, DHCP, DNS, IPv6, private relay; НЕ фактическая классификация WFP |
| Native core config checks | 18 синтетических конфигураций: базовые probes + три ядра × два режима × IPv6, native provider rules/Geo/inline sets |
| Child lifecycle integration | Xray/sing-box по 3 цикла, SOCKS auth, 64 TCP блока/цикл, проверка данных и завершения процесса; получатель на этом ПК, без удалённого VPN/TUN |
| sing-box rule-set guard | Реальный upstream decoder для JSON/SRS и вложенных process/source rules; сохранение DNS validator; upstream initial/update commit hooks проходят |
| Recovery PowerShell | AST и C# compile проходят; Release на рабочем ПК НЕ выполнялся |
| Known Go vulnerabilities | Три source scans: 0 reachable/imported-package; один неиспользуемый OpenPGP module advisory |
| Release | DLL, recovery tool, native cores и Flutter portable собраны; приложение НЕ запущено |
| Локальный Defender | Custom scan готовой candidate-папки: угроз не найдено; remediation отключён только для этого сканирования, защита ОС включена, база 1.459.576.0 от 06.10.2026 |

Готовый кандидат: `../output/Nozelt-Windows-Security-r1-2026-10-06/`;
окончательный ZIP — `../output/Nozelt-Windows-Security-r1-final-2026-10-06.zip`.
Ранее созданный ZIP без `final` — промежуточная версия до дополнительной проверки
native source/rule-set контекста. В папке есть `SHA256SUMS.json` для всех файлов; manifest не включает собственный
хеш. Локальное сканирование Defender не гарантирует, что последующие обновления
сигнатур никогда не дадут ложного срабатывания. Исключения/отключение Defender
не использовались.

Добавлен opt-in `TestIsolatedWFPPolicyRoundTripAndRollback`, который реально
проверяет установку, provider enumeration и откат транзакции. Он **не запускался**:
требует disposable Windows VM без другого VPN, администратора и явной переменной
`NOZELT_WFP_TEST_DISPOSABLE_VM=I_ACCEPT_TEMPORARY_NETWORK_BLOCK`. На рабочем ПК
эта переменная не устанавливается. Read-only WFP schema test также пропущен,
поскольку текущий процесс не elevated.

## 4. Что остаётся подтвердить до обычного использования

1. В изолированной Windows проверить реальные WFP типы условий, четыре ALE
   слоя, арбитраж с Windows Firewall, LUID TUN и atomic rollback. Снять pcap с
   физического интерфейса и убедиться, что DNS:53 и непредусмотренный egress
   отсутствуют при создании/падении/замене TUN и удалении маршрута.
2. TCP/UDP/QUIC, IPv4/IPv6, system DNS, браузерный DoH, WebRTC/STUN, alternate
   DNS ports, loopback relay и IPv4-mapped IPv6. Явный DIRECT разрешён политикой;
   браузерный DoH приложения DIRECT является его собственным прямым трафиком.
3. Процессные DIRECT/PROXY/REJECT проверить реальными двумя программами,
   короткими UDP сокетами и сменой PID; сопоставить owner/rule/egress в pcap.
4. Провайдерные domain/IP/Geo/rule-set/selector/final правила проверить по
   удалённым контрольным адресам. Синтаксическая проверка ещё не доказывает
   выходной IP, а Geo списки не гарантируют точность географии каждого адреса.
   Snapshot Clash включает routing и существующие inline proxy nodes;
   конфигурации, требующие `proxy-providers` вместо этих узлов, полностью не
   поддерживаются и могут быть отклонены валидатором. Произвольные native
   конфигурации с потерянным source/inbound/process контекстом не принимаются.
5. Падение child и host, Defender quarantine, длительный offline, sleep/resume,
   DHCP renew и Ethernet/Wi-Fi switches; reauthorization уже существующих потоков.
   Persistent guard должен оставлять сеть закрытой до reconnect/explicit release.
6. Повторный вход в Windows, отключённый autostart, ручной release и новый EXE
   с тем же/новым путём. Потеря fake-IP RAM при полном restart может потребовать
   обновления DNS в приложениях; сохранение всех TCP-сессий не заявляется.
7. Скорость, CPU/RAM и packet loss при разных MTU/stack/UDP нагрузках на реальных
   серверах. MTU=9000 и stack default не менялись без измерений; прирост WAN
   скорости не измерен и не заявляется. Устранённые locks/retry/direct fallback
   улучшают контроль и поведение при отказах, но не заменяют benchmark.

Trusted Nozelt/core executables имеют разрешённый физический доступ, необходимый
для транспорта и явного DIRECT. Модель не защищает от взлома самого trusted
процесса, администратора, другого kernel driver, отказа BFE или атак ОС до
загрузки persistent filters. Детектор другого TUN — проверка известных типов/
имён адаптеров, не универсальный детектор всех продуктов VPN. Всё это нужно
учитывать при формулировке гарантий.

## 5. Основные файлы

- `../nozelt-core/networkguard/guard_windows.go`, `policy_windows_test.go`,
  `schema_windows_test.go`, `integration_windows_test.go` — WFP и проверки.
- `../nozelt-core/third_party/wf/` — Tailscale BSD-3-Clause WFP binding,
  локальные transaction/provider-layer enumeration extensions и описание версии.
- `../nozelt-core/windowsdll/native_process.go`, `frontend_policy.go`, `relay.go`,
  `recovery_backoff.go`, `log_privacy.go`, `main.go` — lifecycle/FFI/transport.
- `../nozelt-core/core/config.go`, `parse.go`, `routing_security_test.go` —
  validation, импорт provider routing, реальные routing matchers.
- `lib/src/core/config_builder.dart`, `multi_core_config_builder.dart`,
  `profile.dart`, `nozelt_engine.dart`, `models.dart`, `config_error.dart`,
  `windows_native_bridge.dart` — конфигурации/модели/ошибки/Windows FFI.
- `lib/src/state/profiles_provider.dart`, `engine_provider.dart`,
  `lib/main.dart`, `lib/src/core/windows_shell_bridge.dart`,
  `windows/runner/flutter_window.{cpp,h}` — persistence, recovery UI и трей.
- `lib/src/ui/diagnostics_screen.dart`, `widgets/connection_button.dart`,
  `lib/src/l10n/` — состояние защиты, восстановление и понятные ошибки.
- `scripts/recover_windows_network.ps1`, `../nozelt-core/cmd/network-recovery/`,
  `windows/CMakeLists.txt` — независимое восстановление и доставка в bundle.
- `test/windows_network_policy_test.dart`,
  `tool/validate_windows_core_configs.dart` — DNS/routing policy и native validation.
- `../native-cores/build_windows.ps1`, `../native-cores/singbox-runner/go.{mod,sum}`,
  `../nozelt-core/go.{mod,sum}` — воспроизводимые версии и security overlays.
- `../native-cores/singbox-runner/rule_set_guard_windows.go` и тесты — проверка
  process/source metadata при загрузке и обновлении списков, без изменений Android guard.
- `../native-cores/third_party/sing-box/` — pinned source v1.14.2 с единственным
  расширением source metadata; происхождение и изменения записаны в `NOZELT.md`.

## 6. Первичные технические источники

- [Microsoft: ALE layers](https://learn.microsoft.com/en-us/windows/win32/fwp/ale-layers),
  [filter arbitration](https://learn.microsoft.com/en-us/windows/win32/fwp/filter-arbitration),
  [ALE reauthorization](https://learn.microsoft.com/en-us/windows/win32/fwp/ale-re-authorization),
  [FWPM_FILTER_ENUM_TEMPLATE0](https://learn.microsoft.com/en-us/windows/win32/api/fwpmtypes/ns-fwpmtypes-fwpm_filter_enum_template0).
- [WireGuard Windows firewall source](https://git.zx2c4.com/wireguard-windows/tree/tunnel/firewall),
  [Tailscale wf](https://github.com/tailscale/wf).
- [Mihomo TUN](https://github.com/MetaCubeX/Meta-Docs/blob/main/docs/config/inbound/tun.en.md),
  [DNS](https://wiki.metacubex.one/en/config/dns/),
  [rule providers](https://wiki.metacubex.one/en/config/rule-providers/).
- [Xray DNS](https://xtls.github.io/config/dns.html),
  [sing-box TUN](https://sing-box.sagernet.org/configuration/inbound/tun/),
  [route](https://sing-box.sagernet.org/configuration/route/).
- [Go releases](https://go.dev/dl/), [govulncheck](https://go.dev/security/vuln/),
  [grpc GO-2026-6443](https://pkg.go.dev/vuln/GO-2026-6443),
  [compress GO-2026-5841](https://pkg.go.dev/vuln/GO-2026-5841),
  [DHCP GO-2026-6237](https://pkg.go.dev/vuln/GO-2026-6237),
  [OpenPGP GO-2026-5932](https://pkg.go.dev/vuln/GO-2026-5932).

## 7. Восстановление после аварии

Сначала закрыть Nozelt. Для **намеренного снятия его блокировки** запустить
`recover_windows_network.ps1` из portable-папки в PowerShell администратора,
либо `nozelt-network-recovery.exe --release` с теми же правами. После этого
непредусмотренный трафик Nozelt больше не блокируется: это явное выключение
защиты, а не исправление продолжающего работать VPN. На этом ПК сценарий не
запускался. Defender не отключался, исключения не добавлялись, файлы/профили
во внешние сервисы не отправлялись.

## 21.10.2026: защита больше не блокирует сеть после закрытия

По решению пользователя («при каком угодно отключении никакой блокировки не нужно») WFP-правила защиты создаются в динамической сессии (`wf.Options.Dynamic`), без флага `Persistent`. Windows удаляет их, как только закрывается сессия или завершается процесс Nozelt по любой причине: штатное отключение, выход, падение, завершение через диспетчер задач. Пока VPN работает, защита от утечек действует как раньше.

При первом опросе статуса ядро снимает правила, оставшиеся от прежних persistent-версий, если своей активной сессии нет. Выход из трея ждёт остановки ядра не дольше 10 секунд, затем приложение закрывается. Если отключение длится дольше 15 секунд, кнопка показывает «Ждём остановки ядра…».

Цена решения: при аварийном завершении трафик сразу идёт напрямую, мимо VPN, до следующего подключения. Тесты `networkguard` и `windowsdll` проходят; тест `core/TestFakeDNSOverUDPAndTCP` падает на этом ПК при работающем Nozelt TUN (DNS перехватывается туннелем) — пакет `core` не менялся.

## 22.10.2026: блокировка не остаётся после ошибок

Правило пользователя прежнее: когда Nozelt не подключён, интернет работает всегда.
Аудит нашёл пути, где динамическая WFP-сессия жила дольше подключения, хотя процесс
Nozelt оставался запущен:

- Неудачный старт или перезапуск (сервер недоступен, нет физической сети, ошибка
  ядра) раньше оставлял блокировку, а UI показывал «отключено». Теперь любой
  неудачный `startLocked` закрывает сессию защиты; Flutter дополнительно вызывает
  `stop()`, если ядро не дошло до состояния «работает».
- Повторное включение защиты при существующей сессии больше не открывает вторую
  сессию с тем же provider/sublayer: политика пересобирается внутри живой сессии
  (`Guard.Reset`).
- Отключение сначала закрывает собственную сессию (это снимает все её фильтры),
  а `Release()` только подчищает остатки старых persistent-сборок и не может
  оставить ПК без сети при своей ошибке.
- Если после ошибки перезагрузки правил TUN нельзя разрешить заново, сессия
  полностью останавливается вместе с блокировкой.
- Технический перезапуск держит блокировку не дольше 30 секунд: если новый
  запуск не пришёл, защита снимается.

Прочее:

- Пароль внутреннего SOCKS-порта отправляется только процессу Xray/sing-box,
  который действительно слушает этот порт (проверка владельца через
  `GetExtendedTcpTable`). Чужой процесс, занявший порт, ничего не получит.
- Ping на реальный IP больше не уходит напрямую мимо VPN: `disable-icmp-forwarding`
  включён по умолчанию (новый ключ настроек, старое сохранённое `false` не
  применяется). На Android это обязательное правило и в ядре.
- Адаптеры Teredo/IP-HTTPS/6to4 от Microsoft не считаются «другим VPN».
- `<invalid>` больше не принимается как физический интерфейс.
- «Перезапустить» в трее снова переподключает VPN (переменная
  `NOZELT_CONNECT_ON_START` передаётся новому процессу).
- Журнал Windows больше не замирает после 2000 строк (порядковый номер записи).
- Выбор сервера и закрытие соединений не подвешивают окно, пока ядро
  восстанавливает транспорт.
