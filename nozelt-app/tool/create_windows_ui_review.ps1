$ErrorActionPreference = 'Stop'
$taskApp = Split-Path -Parent $PSScriptRoot
$taskReview = Join-Path (Split-Path -Parent $taskApp) 'output\ui-review'
$taskImages = Join-Path $taskReview 'images'
New-Item -ItemType Directory -Force -Path $taskImages | Out-Null
$taskTitles = @{
    home='Главная'; proxies='Прокси'; routing='Маршрутизация'; connections='Программы';
    logs='Логи'; settings='Настройки'; settings_lower='Настройки: нижняя часть';
    profile_menu='Меню профиля'; profile_dialog='Редактор профиля';
    add_profile='Добавление подписки'; add_links='Импорт ссылок';
    proxy_settings='Параметры прокси'; routing_menu='Меню маршрутизации';
    process_rules='Правила процессов'; routing_settings='Параметры маршрутизации';
    routing_config='Редактор конфига'; geo_tags='Теги GeoIP';
    connections_expanded='Соединения программы'; connection_details='Все подключения';
    connections_filtered='Пустой результат поиска'; mtu_dialog='Изменение MTU';
    diagnostics='Диагностика'; geo_tags_empty='Поиск GeoIP: нет результатов';
    versions_tooltip='Подсказка версий'; navigation_tooltip='Подсказка навигации';
    logs_filtered='Логи: нет результатов'; sidebar_minimum='Панель после сужения';
    sidebar_wide='Панель после расширения'; sidebar_before_breakpoint='Панель: 959 px';
    sidebar_after_breakpoint='Панель: 960 px'
}
$taskCards = foreach ($taskFile in Get-ChildItem (Join-Path $taskApp 'test\goldens\audit') -Filter '*.png' | Sort-Object Name) {
    Copy-Item -LiteralPath $taskFile.FullName -Destination $taskImages -Force
    $taskGroup, $taskKey = $taskFile.BaseName -split '_',2
    $taskCaption = $taskTitles[$taskKey]
    if (-not $taskCaption) { $taskCaption = $taskKey }
    $taskTitle = [System.Net.WebUtility]::HtmlEncode($taskCaption)
    $taskName = [System.Net.WebUtility]::HtmlEncode($taskFile.Name)
    "<article data-group='$taskGroup'><h2>$taskTitle <small>$taskGroup</small></h2><a href='images/$taskName' target='_blank'><img src='images/$taskName' loading='lazy' alt='$taskTitle'></a></article>"
}
Copy-Item -LiteralPath (Join-Path $taskApp 'build\system_tray_menu.png') -Destination $taskImages -Force
Copy-Item -LiteralPath (Join-Path $taskApp 'build\process_explorer.png') -Destination $taskImages -Force
$taskCards += "<article data-group='native'><h2>Настоящее меню Windows <small>native</small></h2><a href='images/system_tray_menu.png' target='_blank'><img class='native' src='images/system_tray_menu.png' alt='Системное меню'></a><p>Изолированный Win32-тест того же механизма меню. Без владельческой отрисовки.</p></article>"
$taskCards += "<article data-group='native'><h2>Извлечение иконки EXE <small>native</small></h2><img class='native' src='images/process_explorer.png' alt='Значок Explorer'><p>PNG, полученный нативным загрузчиком из запущенного explorer.exe.</p></article>"
$taskHtml = @'
<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nozelt — проверка интерфейса Windows</title>
<style>
:root{color-scheme:dark;font:15px 'Segoe UI',sans-serif;background:#080c11;color:#f4f7fb}body{max-width:1560px;margin:auto;padding:32px}h1{font-size:30px;margin:0 0 12px}p{color:#a8b3c1;line-height:1.6;max-width:980px}nav{position:sticky;top:0;z-index:1;background:#080c11ee;padding:16px 0;display:flex;gap:8px;flex-wrap:wrap}button{font:inherit;background:#141b23;border:1px solid #27313d;border-radius:10px;padding:10px 16px;color:inherit;cursor:pointer}button.active{background:#07323f;border-color:#08c7f4;color:#08c7f4}main{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:24px}article{background:#10141a;border:1px solid #27313d;border-radius:16px;overflow:hidden;padding:16px}h2{margin:0 0 12px;font-size:18px}small{font-size:12px;color:#8f9baa;margin-left:10px}img{display:block;width:100%;height:auto;border-radius:6px}img.native{width:auto;max-width:100%;image-rendering:auto}article[hidden]{display:none}a{color:#08c7f4}@media(max-width:900px){main{grid-template-columns:1fr}body{padding:18px}}
</style>
<h1>Nozelt · Windows UI · итерация 3 · 04.10.2026</h1>
<p>Шесть основных страниц, редакторы, меню и диалоги. Normal — 1180×760; compact — 720×520; scaled — DPI и текст 125%; text — минимум окна с текстом 125%; resize — панель после последовательных изменений ширины без принудительной перерисовки. Android — эталон общей разметки 412×915, отрисованный тестовым Flutter на Windows; его emoji не представляют шрифт реального телефона. Нажмите изображение для просмотра в полном размере.</p>
<p>Профили, пинг, трафик и соединения на Flutter-снимках — тестовые данные. Значки процессов в golden-тестах показывают резервное состояние без нативного хоста. Меню Windows и значок Explorer получены отдельными настоящими нативными тестами. Работающий Nozelt и TUN эти проверки не переключают.</p>
<nav><button class="active" data-filter="normal">Обычное окно</button><button data-filter="compact">Минимальное окно</button><button data-filter="scaled">DPI / текст 125%</button><button data-filter="text">Минимальное + текст 125%</button><button data-filter="resize">После изменения ширины</button><button data-filter="android">Android</button><button data-filter="native">Windows native</button><button data-filter="all">Все</button></nav>
<main>__CARDS__</main>
<script>function filter(group){document.querySelectorAll('article').forEach(el=>el.hidden=group!=='all'&&el.dataset.group!==group);document.querySelectorAll('button').forEach(el=>el.classList.toggle('active',el.dataset.filter===group))}document.querySelectorAll('button').forEach(el=>el.onclick=()=>filter(el.dataset.filter));filter('normal');</script>
</html>
'@
$taskHtml.Replace('__CARDS__', ($taskCards -join "`n")) | Set-Content -LiteralPath (Join-Path $taskReview 'index.html') -Encoding utf8
Write-Host "Review: $taskReview\index.html"
