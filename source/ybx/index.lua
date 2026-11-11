-- BEGIN SHARED SLEEP CARD
local SleepCard=(function()
-- Shared by the foreground app and the future lock-screen entry.
local S={size=48062,width=480,height=800}
local function uint(bytes,at,n)
  local value=0
  for i=n-1,0,-1 do value=value*256+bytes:byte(at+i) end
  return value
end
function S.valid(bytes)
  if type(bytes)~='string' or #bytes~=S.size or bytes:sub(1,2)~='BM' or bytes:sub(7,10)~='YBX1' then return false end
  local height=uint(bytes,23,4)
  if height>=0x80000000 then height=height-0x100000000 end
  if uint(bytes,3,4)~=#bytes or uint(bytes,11,4)~=62 or uint(bytes,15,4)~=40
    or uint(bytes,19,4)~=S.width or math.abs(height)~=S.height or uint(bytes,27,2)~=1
    or uint(bytes,29,2)~=1 or uint(bytes,31,4)~=0 then return false end
  local a,b=bytes:sub(55,57),bytes:sub(59,61)
  return (a=='\0\0\0' and b=='\255\255\255') or (b=='\0\0\0' and a=='\255\255\255')
end
local function slot(storage,json,name)
  local ok,meta,bytes=pcall(function()
    local raw=storage:read('ybx-sleep-'..name..'.json')
    if type(raw)~='string' or #raw>256 then error('metadata read') end
    local record=json:decode(raw)
    if type(record)~='table' or type(record.revision)~='number' or record.revision%1~=0
      or record.revision<0 or record.revision>=2147483647 then error('metadata format') end
    if record.revision==0 and record.size==0 then return nil end
    if record.size~=S.size then error('metadata size') end
    local data=storage:read('ybx-sleep-'..name..'.bmp')
    if not S.valid(data) then error('image read') end
    return record,data
  end)
  if not ok then return nil,'Cannot read sleep cache.' end
  if meta then return {name=name,revision=meta.revision,bytes=bytes} end
end
function S.initialize(storage,json)
  local ok,ready=pcall(function()
    local a=storage:read('ybx-sleep-a.json')
    local b=storage:read('ybx-sleep-b.json')
    -- Repair only a demonstrably unfinished initialization, never a committed cache.
    if type(a)=='string' and type(b)=='string' then return true end
    local survivor=type(a)=='string' and a or type(b)=='string' and b
    if survivor then
      local record=json:decode(survivor)
      if type(record)~='table' or record.revision~=0 or record.size~=0 then return false end
      local missing=type(a)=='string' and 'b' or 'a'
      if storage:size('ybx-sleep-'..missing..'.json') or storage:size('ybx-sleep-'..missing..'.bmp') then return false end
      return storage:write('ybx-sleep-'..missing..'.json',json:encode({revision=0,size=0}))
    end
    if storage:size('ybx-sleep-a.json') or storage:size('ybx-sleep-b.json') then return false end
    local empty=json:encode({revision=0,size=0})
    return storage:write('ybx-sleep-a.json',empty) and storage:write('ybx-sleep-b.json',empty)
  end)
  return ok and ready
end
function S.current(storage,json)
  local a,ae=slot(storage,json,'a')
  local b,be=slot(storage,json,'b')
  local active=not a and b or not b and a or a and b and (a.revision>=b.revision and a or b)
  return active,ae or be
end
function S.save(storage,json,bytes)
  if not S.valid(bytes) then return false,'Invalid YBX sleep card.' end
  local ok,saved,reason=pcall(function()
    local active,error=S.current(storage,json)
    if error then return false,error end
    local name=active and active.name=='a' and 'b' or 'a'
    local revision=active and active.revision+1 or 1
    if revision>=2147483647 then return false,'Sleep cache revision limit reached.' end
    local image='ybx-sleep-'..name..'.bmp'
    local metadata='ybx-sleep-'..name..'.json'
    if not storage:write(image,bytes) or storage:read(image)~=bytes then return false,'Cannot save sleep image.' end
    local encoded=json:encode({revision=revision,size=S.size})
    if not storage:write(metadata,encoded) or storage:read(metadata)~=encoded then return false,'Cannot commit sleep image.' end
    return true
  end)
  return ok and saved or false,ok and reason or 'Sleep cache storage error.'
end
return S
end)()
-- END SHARED SLEEP CARD
-- Independent client for the public YBX CrossPoint service contract.
-- Main server with its European and Portuguese mirrors (plugin 1.6.15). In Auto
-- mode a request that cannot reach one host moves on to the next one in turn, and
-- a working mirror stays preferred for five minutes; Main, Europe and Portugal
-- each use exactly one host.
local HOSTS={main='https://my.ybx.app',eu='https://emy.ybx.app',pt='https://pmy.ybx.app'}
local API_PATH='/api/v1/crosspoint'
local VERSION = '1.6.17'
local APP_VERSION = VERSION -- the app follows the CrossPoint plugin version
local c, message, buttons, busy = nil, '', {}, false

-- UI languages and the in-app keyboard. The stock reader has no Russian or
-- Kazakh keyboard, so Cyrillic search needs a keyboard drawn by the app.
local LANGS={{'en','English'},{'ru','Русский'},{'kk','Қазақша'}}
-- Columns: English, Russian, Kazakh. Written for this app's screens, not word for
-- word: Russian follows the wording of Russian e-reader and book-store apps,
-- Kazakh uses everyday Kazakh UI vocabulary. Brand names stay as they are.
-- Long diagnostic details (HTTP bodies, storage traces) stay English on purpose.
local STR={
 -- common
 back={'Back','Назад','Артқа'}, cancel={'Cancel','Отмена','Бас тарту'},
 settings={'Settings','Настройки','Баптаулар'}, close_app={'Close YBX','Закрыть YBX','YBX-ті жабу'},
 loading={'Loading','Загрузка','Жүктелуде'}, selected={'Selected','Выбрано','Таңдалған'},
 try_again={'Try again','Повторить','Қайталау'},
 msg_ok={'Done','Готово','Дайын'}, msg_check={'Please note','Обратите внимание','Назар аударыңыз'},
 nav_library={'Library','Библиотека','Кітапхана'}, nav_search={'Search','Поиск','Іздеу'},
 nav_activity={'Stats','Статистика','Статистика'},
 -- busy screen
 busy_title={'Updating','Обновление','Жаңартылуда'},
 busy_body={'Connecting to YBX','Связываемся с YBX','YBX-пен байланыс'},
 busy_hint={'Downloaded books are available without a network.','Скачанные книги доступны и без сети.','Жүктелген кітаптар желісіз де ашылады.'},
 busy_download={'Downloading','Скачивание','Жүктеп алу'},
 saving_book={'Saving the book…','Сохраняем книгу…','Кітап сақталуда…'},
 received_kib={'%d KB received','Получено %d КБ','%d КБ алынды'},
 keep_open={'Keep YBX open until the download finishes.','Не закрывайте YBX, пока идёт скачивание.','Жүктеу біткенше YBX-ті жаппаңыз.'},
 downloaded_kib={'Downloaded %d KB','Скачано %d КБ','%d КБ жүктелді'},
 -- welcome and pairing
 welcome_title={'All your books in one library','Все ваши книги в одной библиотеке','Барлық кітабыңыз бір кітапханада'},
 welcome_body={'Connect YBX to see your shelves and download books to this reader.','Подключите YBX, чтобы видеть свои полки и скачивать книги на это устройство.','Сөрелеріңізді көріп, кітаптарды осы құрылғыға жүктеу үшін YBX-ті қосыңыз.'},
 connect={'Connect YBX','Подключить YBX','YBX-ті қосу'},
 open_downloads={'Downloaded books','Скачанные книги','Жүктелген кітаптар'},
 pair_title={'Connect YBX','Подключение YBX','YBX-ті қосу'},
 pair_on_phone={'On your phone, open','Откройте на телефоне','Телефоныңызда ашыңыз'},
 pair_enter_code={'and enter this code','и введите код','және мына кодты енгізіңіз'},
 pair_check={'Check','Проверить','Тексеру'},
 pair_approve={'Confirm the sign-in on your phone, then tap Check.','Подтвердите вход на телефоне и нажмите «Проверить».','Телефонда кіруді растап, «Тексеру» түймесін басыңыз.'},
 pair_open={'Open my.ybx.app/pair on your phone.','Откройте my.ybx.app/pair на телефоне.','Телефоныңызда my.ybx.app/pair ашыңыз.'},
 pair_pending={'Not confirmed yet. Confirm on your phone and check again.','Вход ещё не подтверждён. Подтвердите его на телефоне и проверьте снова.','Кіру әлі расталмады. Телефонда растап, қайта тексеріңіз.'},
 pair_slow={'Too early. Wait a few seconds and check again.','Слишком рано. Подождите несколько секунд и проверьте снова.','Тым ерте. Бірнеше секунд күтіп, қайта тексеріңіз.'},
 pair_denied={'The code has expired or the sign-in was declined.','Код истёк или вход отклонён.','Кодтың мерзімі өтті немесе кіру қабылданбады.'},
 pair_code_expired={'Expired','Истёк','Мерзімі өтті'},
 pair_expired_title={'This code has expired','Срок действия кода истёк','Кодтың мерзімі өтті'},
 pair_expired_body={'Get a new code to connect.','Получите новый код, чтобы подключиться.','Қосылу үшін жаңа код алыңыз.'},
 pair_new_code={'Get a new code','Получить новый код','Жаңа код алу'},
 session_title={'Sign in again','Войдите снова','Қайта кіріңіз'},
 session_body={'Your YBX session has ended. Downloaded books are still available.','Сеанс YBX завершён. Скачанные книги по-прежнему доступны.','YBX сеансы аяқталды. Жүктелген кітаптар әлі де қолжетімді.'},
 connected={'Connected','Подключено','Қосылды'},
 paired_body={'Your library is ready','Библиотека готова','Кітапхана дайын'},
 open_library={'Open library','Открыть библиотеку','Кітапхананы ашу'},
 -- library and search
 catalog_title={'Your library','Ваша библиотека','Сіздің кітапханаңыз'},
 search_results={'Search results','Результаты поиска','Іздеу нәтижелері'},
 offline_sub={'Available offline','Доступны без сети','Желісіз қолжетімді'},
 filter={'Filter','Фильтр','Сүзгі'}, search_query={'Title or author','Название или автор','Атауы не авторы'},
 shelf_reading={'Reading','Читаю','Оқып жүрмін'}, shelf_all={'All books','Все книги','Барлық кітап'},
 shelf_device={'On device','На устройстве','Құрылғыда'}, shelf_want={'Want to read','Хочу прочитать','Оқығым келеді'},
 shelf_finished={'Finished','Прочитано','Оқылған'}, shelf_uploaded={'My uploads','Мои загрузки','Менің файлдарым'},
 shelf_label={'Shelf','Полка','Сөре'}, provider={'Service','Сервис','Сервис'},
 all_providers={'All services','Все сервисы','Барлық сервис'},
 apply_filters={'Show books','Показать книги','Кітаптарды көрсету'},
 in_library={'In your library','В библиотеке','Кітапханада'},
 no_books={'No books on this shelf yet','На этой полке пока нет книг','Бұл сөреде әзірге кітап жоқ'},
 try_other={'Pick another shelf or search by title or author.','Выберите другую полку или найдите книгу по названию или автору.','Басқа сөрені таңдаңыз немесе кітапты атауы не авторы бойынша іздеңіз.'},
 empty_offline={'No books on this device yet','На устройстве пока нет книг','Құрылғыда әзірге кітап жоқ'},
 empty_offline_cta={'Download a book from your library to read it without Wi-Fi.','Скачайте книгу из библиотеки, чтобы читать её без Wi-Fi.','Wi-Fi-сыз оқу үшін кітапханадан кітап жүктеп алыңыз.'},
 no_match={'No matching books','Ничего не найдено','Ештеңе табылмады'},
 no_match_body={'Check the spelling or try another title or author.','Проверьте написание или попробуйте другое название или автора.','Жазылуын тексеріңіз немесе басқа атау не автормен іздеңіз.'},
 find_book={'Find your next book','Найдите следующую книгу','Келесі кітабыңызды табыңыз'},
 find_book_body={'Search by title or author in all your connected services.','Ищите по названию или автору во всех подключённых сервисах.','Қосылған сервистердің бәрінен атауы не авторы бойынша іздеңіз.'},
 kb_title={'Search YBX','Поиск в YBX','YBX-тен іздеу'},
 -- book
 about_book={'About this book','О книге','Кітап туралы'},
 no_description={'This book has no description.','У этой книги нет описания.','Бұл кітаптың сипаттамасы жоқ.'},
 reading_progress={'Progress','Прочитано','Оқылғаны'},
 download={'Download','Скачать','Жүктеп алу'}, read_now={'Read','Читать','Оқу'},
 offline_yes={'Available offline','Скачана на устройство','Құрылғыға жүктелген'},
 offline_no={'Not downloaded','Не скачана','Жүктелмеген'},
 book_actions={'Book actions','Действия с книгой','Кітаппен әрекеттер'},
 remove_download={'Remove download','Удалить с устройства','Құрылғыдан өшіру'},
 keep_book={'Keep book','Оставить','Қалдыру'},
 remove_q={'Remove from this device?','Удалить книгу с устройства?','Кітапты құрылғыдан өшіру керек пе?'},
 remove_body={'The book stays in your YBX library. Only the file on this reader is deleted.','Книга останется в библиотеке YBX — удалится только файл на устройстве.','Кітап YBX кітапханасында қалады, тек құрылғыдағы файлы өшіріледі.'},
 removed={'Book removed from this device.','Книга удалена с устройства.','Кітап құрылғыдан өшірілді.'},
 downloaded={'Downloaded','Скачано','Жүктелді'},
 ready={'Ready to read','Можно читать','Оқуға дайын'},
 ready_body={'The book is saved on this reader. Reading progress will sync later.','Книга сохранена на устройстве. Прогресс чтения синхронизируется позже.','Кітап құрылғыға сақталды. Оқу барысы кейін синхрондалады.'},
 back_to_library={'Back to library','К библиотеке','Кітапханаға оралу'},
 failed_title={'Could not save this book','Не удалось сохранить книгу','Кітапты сақтау мүмкін болмады'},
 failed_body={'The download did not finish. Your other books are unchanged.','Скачивание прервалось. Остальные книги не затронуты.','Жүктеу аяқталмады. Басқа кітаптарыңыз орнында.'},
 technical={'Technical details','Подробности','Толығырақ'},
 check_storage={'Check storage','Проверить память','Жадты тексеру'},
 details_title={'Download details','Подробности','Толығырақ'},
 -- settings
 settings_account={'Account','Аккаунт','Аккаунт'},
 settings_sleep={'Sleep screen','Экран сна','Ұйқы экраны'},
 settings_reading={'Reading sync','Синхронизация чтения','Оқуды синхрондау'},
 settings_kosync={'KOSync','KOSync','KOSync'},
 settings_help={'Help & diagnostics','Помощь и диагностика','Анықтама'},
 settings_language={'Language','Язык','Тіл'},
 settings_keyboard={'Keyboard','Клавиатура','Пернетақта'},
 settings_kb_kk={'Kazakh layout','Казахская раскладка','Қазақша пернетақта'},
 settings_kb_kk_sub={'Adds ҚА: ә і ң ғ ү ұ қ ө һ','Добавляет ҚА: ә і ң ғ ү ұ қ ө һ','ҚА қосылады: ә і ң ғ ү ұ қ ө һ'},
 settings_reader_cp={'Firmware: CrossPoint','Прошивка: CrossPoint','Микробағдарлама: CrossPoint'},
 settings_reader_stock={'Firmware: Licorice','Прошивка: Licorice','Микробағдарлама: Licorice'},
 -- account
 account_not_connected={'Not connected','Не подключено','Қосылмаған'},
 account_connected={'Connected to YBX','Подключено к YBX','YBX-ке қосылған'},
 account_manage={'Book services and your library are managed at my.ybx.app.','Сервисы и библиотека настраиваются на my.ybx.app.','Сервистер мен кітапхана my.ybx.app сайтында бапталады.'},
 account_signout={'Sign out on this reader','Выйти на этом устройстве','Осы құрылғыда шығу'},
 account_disconnect={'Disconnect this device','Отвязать устройство','Құрылғыны ажырату'},
 account_books_stay={'Downloaded books stay on this reader.','Скачанные книги останутся на устройстве.','Жүктелген кітаптар құрылғыда қалады.'},
 signout_q={'Sign out on this reader?','Выйти на этом устройстве?','Осы құрылғыда шығасыз ба?'},
 signout_body={'This reader forgets the sign-in. Other devices stay connected, and downloaded books are kept.','Устройство забудет вход. Другие устройства останутся подключены, скачанные книги сохранятся.','Құрылғы кіру деректерін ұмытады. Басқа құрылғылар қосулы қалады, жүктелген кітаптар сақталады.'},
 disconnect_q={'Disconnect this device?','Отвязать устройство?','Құрылғыны ажыратасыз ба?'},
 disconnect_body={'This reader loses access to YBX. To come back, connect it with a new code. Downloaded books are kept.','Устройство потеряет доступ к YBX. Чтобы вернуться, подключите его по новому коду. Скачанные книги сохранятся.','Құрылғы YBX-ке қолжетімділігін жоғалтады. Қайта қосу үшін жаңа код керек. Жүктелген кітаптар сақталады.'},
 signout={'Sign out','Выйти','Шығу'}, disconnect={'Disconnect','Отвязать','Ажырату'},
 disconnected={'This device is disconnected from YBX.','Устройство отвязано от YBX.','Құрылғы YBX-тен ажыратылды.'},
 account_kept={'Could not reset this reader\'s YBX settings; account unchanged.','Не удалось сбросить настройки YBX на устройстве, поэтому аккаунт не изменён.','Құрылғыдағы YBX баптауларын тазалау мүмкін болмады, сондықтан аккаунт өзгерген жоқ.'},
 connect_first={'Connect your YBX account first.','Сначала подключите аккаунт YBX.','Алдымен YBX аккаунтын қосыңыз.'},
 -- stats
 activity_today={'Today','Сегодня','Бүгін'},
 activity_time={'Reading time','Время чтения','Оқу уақыты'},
 activity_streak={'Days in a row','Дней подряд','Қатарынан күн'},
 activity_week={'This week','За неделю','Осы аптада'}, activity_goal={'Yearly goal','Цель на год','Жылдық мақсат'},
 activity_calendar={'Calendar','Календарь','Күнтізбе'}, activity_awards={'Achievements','Достижения','Жетістіктер'},
 activity_unavailable={'No reading stats yet','Статистики пока нет','Әзірге статистика жоқ'},
 activity_try_later={'Try again later. Downloaded books can still be read.','Попробуйте позже. Скачанные книги можно читать и сейчас.','Кейінірек көріңіз. Жүктелген кітаптарды қазір де оқуға болады.'},
 min={' min',' мин',' мин'},
 calendar_hint={'A dot marks days with reading','Точкой отмечены дни с чтением','Нүкте — оқыған күн белгісі'},
 select_day={'Select a day','Выберите день','Күнді таңдаңыз'},
 view_day={'Open day','Открыть день','Күнді ашу'},
 calendar_unavailable={'Calendar unavailable','Календарь недоступен','Күнтізбе қолжетімсіз'},
 calendar_retry={'Open Stats again and retry.','Откройте статистику снова и повторите.','Статистиканы қайта ашып, қайталап көріңіз.'},
 calendar_no_date={'The server did not send today\'s date.','Сервер не прислал сегодняшнюю дату.','Сервер бүгінгі күнді жібермеді.'},
 calendar_title={'Reading day','День чтения','Оқу күні'},
 recorded={'Time read this day','Время чтения за день','Осы күнгі оқу уақыты'},
 day_note={'Only the daily total is shown, not separate sessions.','Показано только общее время за день, без отдельных сеансов.','Тек күндік жалпы уақыт көрсетіледі, жеке сеанстар емес.'},
 awards_none={'No achievements yet','Достижений пока нет','Әзірге жетістік жоқ'},
 awards_hint={'Achievements you earn and the next ones to reach will appear here.','Здесь появятся полученные и следующие достижения.','Мұнда алған және келесі жетістіктеріңіз шығады.'},
 earned={'Earned','Получено','Алынды'}, upcoming={'Up next','Впереди','Алда'},
 award_title={'Achievement','Достижение','Жетістік'},
 -- sleep screen
 sleep_preview={'Refresh to see a preview','Обновите, чтобы увидеть','Көру үшін жаңартыңыз'},
 sleep_use={'Use YBX sleep screen','Экран сна YBX','YBX ұйқы экраны'},
 sleep_refresh_card={'Refresh picture','Обновить картинку','Суретті жаңарту'},
 sleep_refresh_opts={'Auto refresh','Автообновление','Автожаңарту'},
 sleep_before={'Refresh before sleep','Обновлять перед сном','Ұйықтар алдында жаңарту'},
 sleep_restore={'Restore usual sleep screen','Вернуть обычный экран сна','Әдеттегі ұйқы экранын қайтару'},
 sleep_hint_cp={'In the firmware sleep settings choose Custom or Cover + Custom.','В настройках сна прошивки выберите Custom или Cover + Custom.','Микробағдарламаның ұйқы баптауларында Custom не Cover + Custom таңдаңыз.'},
 sleep_hint_stock={'Confirm on the device. Off wallpaper must be set to Default.','Подтвердите выбор на устройстве. Обои выключения (Off wallpaper) должны быть Default.','Құрылғыда растаңыз. Off wallpaper параметрі Default болуы керек.'},
 sleep_opts_cp={'Uses saved Wi-Fi when the battery is above 20%. Quick Resume skips the refresh. The current picture is kept.','Работает через сохранённую сеть Wi-Fi при заряде выше 20%. При Quick Resume обновление пропускается. Текущая картинка сохраняется.','Заряд 20%-дан жоғары болса, сақталған Wi-Fi арқылы жұмыс істейді. Quick Resume кезінде жаңарту өткізіледі. Қазіргі сурет сақталады.'},
 sleep_opts_stock={'Experimental on Licorice: it depends on network access while the reader sleeps. If it fails, the current picture is kept.','На Licorice работает экспериментально и зависит от доступа к сети во сне. При ошибке остаётся текущая картинка.','Licorice-те тәжірибелік режимде, ұйқы кезіндегі желіге байланысты. Қате болса, қазіргі сурет қалады.'},
 sleep_need_card={'Refresh the picture first.','Сначала обновите картинку.','Алдымен суретті жаңартыңыз.'},
 sleep_selected_cp={'Selected. Choose Custom in the firmware sleep settings.','Выбрано. В настройках сна прошивки выберите Custom.','Таңдалды. Микробағдарламаның ұйқы баптауларында Custom таңдаңыз.'},
 sleep_confirm_stock={'Confirm on the device. Off wallpaper must be Default.','Подтвердите на устройстве. Обои выключения должны быть Default.','Құрылғыда растаңыз. Off wallpaper Default болуы керек.'},
 sleep_select_failed={'Could not set the YBX sleep screen.','Не удалось установить экран сна YBX.','YBX ұйқы экранын орнату мүмкін болмады.'},
 sleep_restored={'Usual sleep screen restored.','Обычный экран сна возвращён.','Әдеттегі ұйқы экраны қайтарылды.'},
 sleep_restore_requested={'Usual sleep screen requested.','Запрошен обычный экран сна.','Әдеттегі ұйқы экраны сұралды.'},
 sleep_restore_failed={'Could not restore the usual sleep screen.','Не удалось вернуть обычный экран сна.','Әдеттегі ұйқы экранын қайтару мүмкін болмады.'},
 sleep_not_ours={'YBX is not the current sleep screen.','Сейчас экран сна не от YBX.','Қазір ұйқы экраны YBX емес.'},
 sleep_setting_saved={'Auto refresh setting saved.','Настройка автообновления сохранена.','Автожаңарту баптауы сақталды.'},
 sleep_setting_failed={'Could not save the auto refresh setting.','Не удалось сохранить настройку автообновления.','Автожаңарту баптауын сақтау мүмкін болмады.'},
 sleep_busy={'Wait a moment before refreshing the picture.','Подождите немного перед обновлением картинки.','Суретті жаңартпас бұрын сәл күтіңіз.'},
 sleep_cache_failed={'Could not prepare storage for the picture.','Не удалось подготовить память для картинки.','Сурет үшін жадты дайындау мүмкін болмады.'},
 sleep_refresh_failed={'Could not refresh the picture (HTTP %d). The previous one is kept.','Не удалось обновить картинку (HTTP %d). Оставлена прежняя.','Суретті жаңарту мүмкін болмады (HTTP %d). Бұрынғысы қалды.'},
 sleep_incomplete={'The picture arrived incomplete. The previous one is kept.','Картинка пришла не полностью. Оставлена прежняя.','Сурет толық келмеді. Бұрынғысы қалды.'},
 sleep_too_big={'The picture is too large. The previous one is kept.','Картинка слишком большая. Оставлена прежняя.','Сурет тым үлкен. Бұрынғысы қалды.'},
 sleep_saved={'Sleep screen picture updated.','Картинка для экрана сна обновлена.','Ұйқы экранының суреті жаңартылды.'},
 sleep_save_failed={'Could not save the picture. The previous one is kept.','Не удалось сохранить картинку. Оставлена прежняя.','Суретті сақтау мүмкін болмады. Бұрынғысы қалды.'},
 -- reading sync
 sync_intro={'Reading progress is sent when you open YBX. Anything not sent stays queued.','Прогресс чтения отправляется при открытии YBX. Неотправленное ждёт в очереди.','Оқу барысы YBX ашылғанда жіберіледі. Жіберілмегені кезекте тұрады.'},
 sync_before_sleep={'Sync before sleep','Синхронизировать перед сном','Ұйықтар алдында синхрондау'},
 sync_now={'Sync now','Синхронизировать','Қазір синхрондау'},
 sync_note={'Open downloaded books through YBX so their progress reaches your library. Sync before sleep needs over 20% battery.','Открывайте скачанные книги через YBX, чтобы прогресс попадал в библиотеку. Синхронизация перед сном работает при заряде выше 20%.','Оқу барысы кітапханаға түсуі үшін жүктелген кітаптарды YBX арқылы ашыңыз. Ұйықтар алдында синхрондау үшін заряд 20%-дан жоғары болуы керек.'},
 sync_stock_title={'Not available on stock firmware','Недоступно на этой прошивке','Бұл микробағдарламада жоқ'},
 sync_stock_body={'Licorice does not tell YBX about reading sessions. You can still see your stats from the cloud.','Licorice не сообщает YBX о сеансах чтения. Статистику из облака смотреть можно.','Licorice YBX-ке оқу сеанстары туралы хабарламайды. Бұлттағы статистиканы көруге болады.'},
 sync_downloads={'Send download reports','Отправить отчёты о скачивании','Жүктеу есептерін жіберу'},
 sync_saved={'Reading sync setting saved.','Настройка синхронизации сохранена.','Синхрондау баптауы сақталды.'},
 sync_save_failed={'Could not save the sync setting.','Не удалось сохранить настройку синхронизации.','Синхрондау баптауын сақтау мүмкін болмады.'},
 sync_none={'Nothing to send.','Отправлять нечего.','Жіберетін ештеңе жоқ.'},
 sync_done={'Reading progress synced.','Прогресс чтения синхронизирован.','Оқу барысы синхрондалды.'},
 sync_reported={'Download reported. Still queued: %d','Отчёт о скачивании отправлен. В очереди: %d','Жүктеу есебі жіберілді. Кезекте: %d'},
 sync_pending={'Report not sent yet (HTTP %d). It will be retried.','Отчёт пока не отправлен (HTTP %d). Повторим позже.','Есеп әлі жіберілмеді (HTTP %d). Кейін қайталанады.'},
 sync_sd_error={'Sent, but the memory card could not be updated. It will be resent.','Отправлено, но не удалось записать на карту памяти. Отправим ещё раз.','Жіберілді, бірақ жад картасына жазу мүмкін болмады. Қайта жіберіледі.'},
 sync_queue_error={'The reading progress queue is damaged. Reports are kept.','Очередь прогресса чтения повреждена. Данные сохранены.','Оқу барысының кезегі бүлінген. Деректер сақталды.'},
 sync_needs_cp={'Reading sync needs the CrossPoint firmware.','Синхронизация чтения работает только на прошивке CrossPoint.','Оқуды синхрондау тек CrossPoint микробағдарламасында жұмыс істейді.'},
 sync_track_failed={'Could not enable progress tracking. Check the memory card.','Не удалось включить учёт прогресса. Проверьте карту памяти.','Оқу барысын есепке алуды қосу мүмкін болмады. Жад картасын тексеріңіз.'},
 saved_queue_full={'Book saved, but the download report could not be queued.','Книга сохранена, но отчёт о скачивании не поставлен в очередь.','Кітап сақталды, бірақ жүктеу есебі кезекке қойылмады.'},
 -- KOSync
 kosync_hint={'Sync your reading position','Синхронизация места в книге','Кітаптағы орынды синхрондау'},
 kosync_intro={'Get a separate key, then enter it by hand in the KOSync settings on this reader.','Получите отдельный ключ и введите его вручную в настройках KOSync на устройстве.','Жеке кілт алып, оны құрылғының KOSync баптауларына қолмен енгізіңіз.'},
 kosync_get={'Get setup details','Получить данные','Деректерді алу'},
 kosync_server={'Server:','Сервер:','Сервер:'},
 kosync_user={'Username: ybx','Логин: ybx','Логин: ybx'}, kosync_pass={'Password:','Пароль:','Құпиясөз:'},
 kosync_reveal={'Reveal credentials','Показать пароль','Құпиясөзді көрсету'},
 kosync_hide={'Hide credentials','Скрыть пароль','Құпиясөзді жасыру'},
 kosync_invalid={'The server sent an invalid key.','Сервер прислал неверный ключ.','Сервер қате кілт жіберді.'},
 -- help
 support_title={'Help & diagnostics','Помощь и диагностика','Анықтама'},
 check_device_storage={'Check device storage','Проверить память','Жадты тексеру'},
 retry_reports={'Resend reports','Отправить отчёты повторно','Есептерді қайта жіберу'},
 conn_help={'Connection problems','Проблемы с подключением','Қосылу мәселелері'},
 about_title={'About','О приложении','Қолданба туралы'},
 update_check={'Check for updates','Проверить обновление','Жаңартуды тексеру'},
 update_checking={'Checking for updates…','Проверяем обновления…','Жаңартулар тексерілуде…'},
 update_none={'You have the latest version','У вас последняя версия','Сізде соңғы нұсқа'},
 update_none_body={'YBX XTApp is up to date.','YBX XTApp обновлён.','YBX XTApp жаңартылған.'},
 update_check_failed={'Could not check for updates','Не удалось проверить обновление','Жаңартуды тексеру мүмкін болмады'},
 update_available={'YBX %s is available','Доступна YBX %s','YBX %s қолжетімді'},
 update_available_body={'Version %s, %d KB. Update?','Версия %s, %d КБ. Обновить?','Нұсқа %s, %d КБ. Жаңарту керек пе?'},
 update_now={'Update','Обновить','Жаңарту'},
 update_later={'Later','Позже','Кейінірек'},
 update_downloading={'Downloading update… %d%%','Скачиваем обновление… %d%%','Жаңарту жүктелуде… %d%%'},
 update_download_failed={'Could not download the update. Try again.','Не удалось скачать обновление, попробуйте ещё раз.','Жаңартуды жүктеу мүмкін болмады, қайталап көріңіз.'},
 update_title={'Update','Обновление','Жаңарту'},
 update_ready_title={'Update ready','Обновление готово','Жаңарту дайын'},
 update_saved={'Package saved: %s','Пакет сохранён: %s','Пакет сақталды: %s'},
 update_saved_hint={'Open All Files and install it — books and settings stay.','Откройте All Files и установите его — книги и настройки сохранятся.','All Files ашып орнатыңыз — кітаптар мен параметрлер сақталады.'},
 update_install={'Install saved update','Установить обновление','Сақталған жаңартуды орнату'},
 update_close={'Close update','Закрыть','Жабу'},
 last_error={'Last download error','Последняя ошибка скачивания','Соңғы жүктеу қатесі'},
 storage_check={'Storage check','Проверка памяти','Жадты тексеру'},
 storage_test={'Test download storage','Проверка памяти для книг','Кітаптар жадын тексеру'},
 storage_body={'YBX creates, extends, reads and deletes a small temporary file. Your books are not touched.','YBX создаст, допишет, прочитает и удалит небольшой временный файл. Ваши книги не затрагиваются.','YBX шағын уақытша файл жасап, толықтырып, оқып, өшіреді. Кітаптарыңызға тиіспейді.'},
 run_check={'Run storage check','Начать проверку','Тексеруді бастау'},
 storage_ok={'Create, append, read and remove: OK','Создание, дозапись, чтение и удаление: OK','Жасау, толықтыру, оқу және өшіру: OK'},
 storage_failed={'Storage test failed: ','Проверка не пройдена: ','Тексеру сәтсіз: '},
 offline_title={'Connect to Wi-Fi','Подключитесь к Wi-Fi','Wi-Fi-ға қосылыңыз'},
 offline_body={'Turn on Wi-Fi in the reader settings, then come back to YBX. Downloaded books open without a network.','Включите Wi-Fi в настройках устройства и вернитесь в YBX. Скачанные книги открываются и без сети.','Құрылғы баптауларында Wi-Fi-ды қосып, YBX-ке оралыңыз. Жүктелген кітаптар желісіз де ашылады.'},
 offline_retry={'Try to connect again','Подключиться снова','Қайта қосылу'},
 about_body={'An independent client for YBX. The YBX name and icon belong to YBX. ybx.app','Независимый клиент YBX. Название и значок YBX принадлежат YBX. ybx.app','YBX-тің тәуелсіз клиенті. YBX атауы мен белгішесі YBX-ке тиесілі. ybx.app'},
 -- errors
 err_no_network={'No network. Check Wi-Fi.','Нет сети. Проверьте Wi-Fi.','Желі жоқ. Wi-Fi-ды тексеріңіз.'},
 err_rate={'Too many requests. Wait a minute and try again.','Слишком много запросов. Подождите минуту и повторите.','Сұраныс тым көп. Бір минут күтіп, қайталаңыз.'},
 err_wait={'Wait a little before trying again.','Подождите немного и повторите.','Сәл күтіп, қайталаңыз.'},
 err_no_response={'The server did not respond. Try again.','Сервер не ответил. Попробуйте ещё раз.','Сервер жауап бермеді. Қайталап көріңіз.'},
 err_timeout={'The request timed out. Try again.','Сервер долго не отвечает. Попробуйте ещё раз.','Сервер ұзақ жауап бермеді. Қайталап көріңіз.'},
 err_download_timeout={'The download timed out. Try again.','Скачивание прервалось по тайм-ауту. Попробуйте ещё раз.','Жүктеу уақыты бітті. Қайталап көріңіз.'},
 err_request={'Could not send the request: ','Не удалось отправить запрос: ','Сұранысты жіберу мүмкін болмады: '},
 err_http={'Server error (HTTP %d): ','Ошибка сервера (HTTP %d): ','Сервер қатесі (HTTP %d): '},
 err_source={'This store is not connected yet. Connect it at ybx.app.','Этот магазин ещё не подключён. Подключите его на ybx.app.','Бұл дүкен әлі қосылмаған. Оны ybx.app сайтында қосыңыз.'},
 err_catalog={'The server sent an invalid book list.','Сервер прислал некорректный список книг.','Сервер кітаптар тізімін қате жіберді.'},
 err_too_big={'This book is larger than the 8 MB firmware download limit.','Книга больше 8 МБ — это предел скачивания в прошивке.','Кітап 8 МБ-тан үлкен — бұл микробағдарламадағы жүктеу шегі.'},
 err_too_big_32={'This book is larger than the 32 MB limit.','Книга больше допустимых 32 МБ.','Кітап рұқсат етілген 32 МБ-тан үлкен.'},
 err_no_slot={'No free file name for the download.','Нет свободного имени файла для скачивания.','Жүктеу үшін бос файл атауы жоқ.'},
 err_full={'The download list is full (32 books). Remove a book first.','Список скачанных заполнен (32 книги). Сначала удалите книгу.','Жүктелгендер тізімі толы (32 кітап). Алдымен бір кітапты өшіріңіз.'},
 err_already={'Already downloaded. Tap Read.','Уже скачана. Нажмите «Читать».','Жүктеліп қойған. «Оқу» түймесін басыңыз.'},
 err_first={'Download this book first.','Сначала скачайте книгу.','Алдымен кітапты жүктеп алыңыз.'},
 err_open={'Could not open the book: ','Не удалось открыть книгу: ','Кітапты ашу мүмкін болмады: '},
 err_book_id={'This book has an invalid ID.','У книги неверный идентификатор.','Кітаптың идентификаторы қате.'},
 err_no_local={'This book is not on the device.','Этой книги нет на устройстве.','Бұл кітап құрылғыда жоқ.'},
 err_remove={'Could not delete the book file.','Не удалось удалить файл книги.','Кітап файлын өшіру мүмкін болмады.'},
 err_remove_meta={'Could not clear reading data. The book is kept.','Не удалось очистить данные чтения. Книга оставлена.','Оқу деректерін тазалау мүмкін болмады. Кітап қалды.'},
 err_https={'The download link is not secure (HTTPS required).','Ссылка на скачивание небезопасна (нужен HTTPS).','Жүктеу сілтемесі қауіпсіз емес (HTTPS керек).'},
 err_create={'Could not create the download file.','Не удалось создать файл для скачивания.','Жүктеу файлын жасау мүмкін болмады.'},
 err_append={'This firmware cannot write downloads in parts.','Эта прошивка не умеет дописывать файлы при скачивании.','Бұл микробағдарлама файлды бөліктеп жаза алмайды.'},
 cancelled={'Cancelled','Отменено','Тоқтатылды'},
 download_cancelled={'Download cancelled.','Скачивание отменено.','Жүктеу тоқтатылды.'},
 -- keyboard
 kb_shift={'Shift','Регистр','Регистр'}, kb_space={'Space','Пробел','Бос орын'},
 kb_backspace={'Delete','Удалить','Өшіру'},
 kb_ok={'OK','Готово','Дайын'}, kb_more={'123','123','123'}, kb_abc={'abc','абв','әбв'},
 -- stats additions (plugin profile parity)
 activity_books_year={'Books in %s','Книг за %s','%s ж. кітап'},
 goal_ahead={'Ahead of plan by %s','Опережаете план на %s','Жоспардан %s алдасыз'},
 goal_behind={'Behind plan by %s','Отстаёте от плана на %s','Жоспардан %s артта қалдыңыз'},
 goal_on_track={'On track for your goal','Идёте по плану','Жоспар бойынша келесіз'},
 continue_reading={'Continue reading','Продолжить чтение','Оқуды жалғастыру'},
 continue_none={'Nothing in progress','Сейчас ничего не читаете','Қазір оқып жатқан кітап жоқ'},
 continue_none_body={'Start a book from your YBX library and it will appear here.','Начните книгу из библиотеки YBX — она появится здесь.','YBX кітапханасынан кітап бастаңыз, ол осында шығады.'},
 book_stats_title={'Reading stats','Статистика книги','Кітап статистикасы'},
 active_time={'Time read','Время чтения','Оқу уақыты'}, sessions={'Sessions','Сеансы','Сеанстар'},
 started={'Started','Начало','Басталды'}, finished={'Finished','Окончание','Аяқталды'},
 data_sources={'Data: ','Данные: ','Дереккөз: '}, open_book={'Open book','Открыть книгу','Кітапты ашу'},
 -- KOSync additions
 kosync_https={'If the reader handles HTTPS: https://%s/api/v1/crosspoint/kosync','Если ридер поддерживает HTTPS: https://%s/api/v1/crosspoint/kosync','Ридер HTTPS қолдаса: https://%s/api/v1/crosspoint/kosync'},
 kosync_check={'Check key','Проверить ключ','Кілтті тексеру'},
 kosync_ok={'The server accepts this key. Check syncing on the reader itself.','Сервер принимает ключ. Проверьте синхронизацию на самом ридере.','Сервер кілтті қабылдады. Синхрондауды ридердің өзінде тексеріңіз.'},
 kosync_rejected={'The server did not accept the key (HTTP %d). Get a new one.','Сервер не принял ключ (HTTP %d). Получите новый.','Сервер кілтті қабылдамады (HTTP %d). Жаңасын алыңыз.'},
 clippings_title={'Quotes and notes','Цитаты и заметки','Дәйексөздер мен жазбалар'},
 clippings_intro={'A separate key lets KOSync send your quotes and notes to YBX. It only works if this firmware\'s KOSync syncs quotes.','Отдельный ключ позволяет KOSync отправлять цитаты и заметки в YBX. Работает, только если KOSync в прошивке умеет синхронизировать цитаты.','Жеке кілт арқылы KOSync дәйексөздер мен жазбаларды YBX-ке жібере алады. Микробағдарламадағы KOSync дәйексөздерді синхрондай алса ғана жұмыс істейді.'},
 clippings_note={'Enter it in the KOSync settings in place of the reading-position key.','Введите его в настройках KOSync вместо ключа для позиции чтения.','Оны KOSync баптауларында оқу орны кілтінің орнына енгізіңіз.'},
 clippings_get={'Get quotes key','Получить ключ цитат','Дәйексөз кілтін алу'},
 clippings_revoke={'Revoke quotes key','Отозвать ключ цитат','Дәйексөз кілтін қайтарып алу'},
 clippings_revoked={'Quotes key revoked.','Ключ цитат отозван.','Дәйексөз кілті қайтарып алынды.'},
 clippings_invalid={'The server sent an unsuitable quotes key.','Сервер прислал неподходящий ключ цитат.','Сервер жарамсыз дәйексөз кілтін жіберді.'},
 -- server mirror
 server={'Server','Сервер','Сервер'},
 server_auto={'Auto','Авто','Авто'}, server_main={'Main','Основной','Негізгі'}, server_eu={'Europe','Европа','Еуропа'},
 server_pt={'Portugal','Португалия','Португалия'},
 server_note={'If sleep refresh or sync before sleep is on, turn it off and on again.','Если включены автообновление или синхронизация перед сном, выключите и включите их снова.','Автожаңарту не ұйықтар алдындағы синхрондау қосулы болса, оны өшіріп, қайта қосыңыз.'},
 err_removed={'This reader was removed in your YBX account. Sign out in Settings > Account and connect it again.','Это устройство удалено в кабинете YBX. Выйдите в «Настройки → Аккаунт» и подключите его заново.','Бұл құрылғы YBX кабинетінде жойылған. «Баптаулар → Аккаунт» бөлімінде шығып, қайта қосыңыз.'},
 err_unavailable={'The library is temporarily unavailable. Try again later.','Библиотека временно недоступна. Попробуйте позже.','Кітапхана уақытша қолжетімсіз. Кейінірек көріңіз.'},
 -- connecting stores
 stores_title={'Connect stores','Подключение магазинов','Дүкендерді қосу'},
 stores_body={'Yandex Books, WB Books and LitRes are connected on the YBX website. Scan the code with your phone:','Яндекс Книги, WB Книги и ЛитРес подключаются на сайте YBX. Отсканируйте код телефоном:','Яндекс Книги, WB Книги және ЛитРес YBX сайтында қосылады. Кодты телефонмен сканерлеңіз:'},
 stores_steps={'Sign in to YBX, connect a store, then come back and refresh the library.','Войдите в YBX, подключите магазин, затем вернитесь и обновите библиотеку.','YBX-ке кіріп, дүкенді қосыңыз, содан кейін оралып, кітапхананы жаңартыңыз.'},
 stores_refresh={'Refresh library','Обновить библиотеку','Кітапхананы жаңарту'},
 stores_how={'How to connect','Как подключить','Қалай қосуға болады'},
 unavailable={'No details available.','Подробностей нет.','Мәлімет жоқ.'},
}
-- Messages that report success get a "Done" title instead of "Please note".
local OK_MESSAGES={removed=true,disconnected=true,sleep_selected_cp=true,sleep_restored=true,sleep_restore_requested=true,
 sleep_setting_saved=true,sync_saved=true,kosync_ok=true,clippings_revoked=true,sync_done=true,sync_reported=true,sleep_saved=true,sync_none=true}
local WEEKDAYS={{'Mo','Tu','We','Th','Fr','Sa','Su'},{'Пн','Вт','Ср','Чт','Пт','Сб','Вс'},{'Дс','Сс','Ср','Бс','Жм','Сн','Жс'}}
local MONTHS={
 {'January','February','March','April','May','June','July','August','September','October','November','December'},
 {'Январь','Февраль','Март','Апрель','Май','Июнь','Июль','Август','Сентябрь','Октябрь','Ноябрь','Декабрь'},
 {'Қаңтар','Ақпан','Наурыз','Сәуір','Мамыр','Маусым','Шілде','Тамыз','Қыркүйек','Қазан','Қараша','Желтоқсан'}}
local MONTHS_KK_OF={'қаңтар','ақпан','наурыз','сәуір','мамыр','маусым','шілде','тамыз','қыркүйек','қазан','қараша','желтоқсан'}
local MONTHS_OF={'января','февраля','марта','апреля','мая','июня','июля','августа','сентября','октября','ноября','декабря'}
local PROVIDERS={yandex={'Yandex Books','Яндекс Книги','Яндекс Книги'},wb={'WB Books','WB Книги','WB Книги'},litres={'LitRes','ЛитРес','ЛитРес'}}
-- Short names for the store buttons on the Library screen.
local STORES={{'yandex',{'Yandex','Яндекс','Яндекс'}},{'wb',{'WB','WB','WB'}},{'litres',{'LitRes','ЛитРес','ЛитРес'}}}

local lang='en'
local lang_at=1
local function lang_code() return LANGS[lang_at][1] end
local kb_open
local function T(key,...)
  local e=STR[key]
  local v=e and e[lang_at] or key
  if select('#',...)>0 then return string.format(v,...) end
  return v
end
-- Helpers grouped in one table: the main chunk is close to Lua's 200-local limit.
local F={}
-- Book file names: "<Author> - <Title>.epub". The firmware's storage rules are
-- not fully known (an early probe said no spaces; Cyrillic is untested), so
-- every candidate is tried with an empty write first and the first name the
-- reader accepts is used:
--   1) "Ремарк Эрих Мария - Три товарища.epub"
--   2) "Ремарк_Эрих_Мария_-_Три_товарища.epub"      (spaces refused)
--   3) "Remark_Erikh_Mariya_-_Tri_tovarishcha.epub" (non-ASCII refused)
--   4) the legacy numbered name
-- A name already taken by another book gets " (2)", " (3)" ... appended.
local NAMES = {}
do
  local TR = {
    ['а']='a',['б']='b',['в']='v',['г']='g',['д']='d',['е']='e',['ё']='yo',['ж']='zh',['з']='z',['и']='i',['й']='y',
    ['к']='k',['л']='l',['м']='m',['н']='n',['о']='o',['п']='p',['р']='r',['с']='s',['т']='t',['у']='u',['ф']='f',
    ['х']='kh',['ц']='ts',['ч']='ch',['ш']='sh',['щ']='shch',['ъ']='',['ы']='y',['ь']='',['э']='e',['ю']='yu',['я']='ya',
    ['ә']='a',['і']='i',['ң']='ng',['ғ']='gh',['ү']='u',['ұ']='u',['қ']='q',['ө']='o',['һ']='h',
  }
  local UP = {}
  do
    local up, lo = 'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯӘІҢҒҮҰҚӨҺ', 'абвгдеёжзийклмнопрстуфхцчшщъыьэюяәіңғүұқөһ'
    local los = {}
    for _, cp in utf8.codes(lo) do los[#los + 1] = utf8.char(cp) end
    local i = 0
    for _, cp in utf8.codes(up) do i = i + 1; UP[utf8.char(cp)] = los[i] end
  end
  local function cut(s, chars)
    if not utf8.len(s) then return '' end
    local stop = utf8.offset(s, chars + 1)
    return stop and s:sub(1, stop - 1) or s
  end
  -- Drop characters FAT and the firmware cannot take; collapse spaces.
  function NAMES.clean(s, chars)
    s = tostring(s or '')
    if not utf8.len(s) then return '' end
    local out = {}
    for _, cp in utf8.codes(s) do
      local ch = utf8.char(cp)
      if cp < 32 or cp == 127 or ch:find('^[\\/:%*%?"<>|]$') then ch = ' ' end
      out[#out + 1] = ch
    end
    s = table.concat(out):gsub('%s+', ' '):gsub('^[%s%.]+', ''):gsub('[%s%.]+$', '')
    s = cut(s, chars):gsub('[%s%.]+$', '')
    return s
  end
  function NAMES.translit(s)
    local out = {}
    for _, cp in utf8.codes(s) do
      local ch = utf8.char(cp)
      if cp < 128 then out[#out + 1] = ch
      else
        local lower = UP[ch]
        local t = TR[lower or ch]
        if t and lower and t ~= '' then t = t:sub(1, 1):upper() .. t:sub(2) end
        out[#out + 1] = t or ''
      end
    end
    return table.concat(out)
  end
  -- Name candidates for a book, most readable first.
  function NAMES.candidates(author, title, legacy)
    author, title = NAMES.clean(author, 60), NAMES.clean(title, 100)
    if title == '' then title = 'book' end
    -- keep the name under 170 bytes (Cyrillic is 2 bytes a letter) by
    -- shortening the title, then the author
    local function join() return author ~= '' and (author .. ' - ' .. title) or title end
    while #join() > 170 and utf8.len(title) > 20 do title = cut(title, utf8.len(title) - 4):gsub('[%s%.]+$', '') end
    while #join() > 170 and utf8.len(author) > 10 do author = cut(author, utf8.len(author) - 4):gsub('[%s%.]+$', '') end
    local base = join()
    local under = base:gsub(' ', '_')
    local latin = NAMES.translit(under):gsub('[^%w%-_%.%(%)]', ''):gsub('_+', '_'):gsub('^_', '')
    local list, seen = {}, {}
    for _, b in ipairs { base, under, latin ~= '' and latin or nil } do
      if b and not seen[b] and #b <= 180 then seen[b] = true; list[#list + 1] = b end
    end
    if legacy then list[#list + 1] = legacy:gsub('%.epub$', '') end
    return list
  end
  -- A name is usable when it is free and an empty write to it succeeds (and,
  -- when given, a sidecar name succeeds in a second tree).
  local function free(service, name)
    local ok, size = pcall(function() return service:size(name) end)
    return ok and not size
  end
  local function writable(service, name)
    if not free(service, name) then return false end
    local ok, done = pcall(function() return service:write(name, '') end)
    local good = ok and done ~= false and done ~= nil
    if good then
      local okz, size = pcall(function() return service:size(name) end)
      good = okz and size == 0
    end
    pcall(function() service:remove(name) end)
    return good
  end
  function NAMES.pick(service, author, title, legacy, sidecar_service, sidecar_suffix)
    for i, base in ipairs(NAMES.candidates(author, title, legacy)) do
      local is_legacy = legacy and i == #NAMES.candidates(author, title, legacy)
      for n = 1, is_legacy and 1 or 9 do
        local suffix = n == 1 and '' or (base:find(' ', 1, true) and (' (' .. n .. ')') or ('_(' .. n .. ')'))
        local name = base .. suffix .. '.epub'
        if writable(service, name) and (not sidecar_service or writable(sidecar_service, name .. sidecar_suffix)) then return name end
        if not free(service, name) then -- taken: try the next number
        else break end                    -- refused: try the next style
      end
    end
  end
  -- Names stored in app state are trusted only if they look like file names.
  function NAMES.valid(name)
    return type(name) == 'string' and #name <= 200 and name:sub(-5) == '.epub' and utf8.len(name) ~= nil
      and not name:find('[/\\]') and not name:find('^%.')
  end
end
function F.month_name(ym)
  local y,m=tostring(ym or ''):match('^(%d%d%d%d)%-(%d%d)$');m=tonumber(m)
  if not m or m<1 or m>12 then return tostring(ym or '') end
  return MONTHS[lang_at][m]..' '..y
end
function F.day_name(ymd)
  local y,m,d=tostring(ymd or ''):match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$');m=tonumber(m);d=tonumber(d)
  if not m or m<1 or m>12 then return tostring(ymd or '') end
  if lang_at==2 then return d..' '..MONTHS_OF[m]..' '..y end
  if lang_at==3 then return y..' жылғы '..d..' '..MONTHS_KK_OF[m] end
  return MONTHS[1][m]..' '..d..', '..y
end
-- "3 книги" / "5 книг"; Kazakh and English need no plural forms here.
function F.books_count(n)
  n=math.floor(n)
  if lang_at==2 then
    local m10,m100=n%10,n%100
    local w=(m10==1 and m100~=11) and 'книгу' or (m10>=2 and m10<=4 and (m100<10 or m100>=20)) and 'книги' or 'книг'
    return n..' '..w
  elseif lang_at==3 then return n..' кітапқа' end
  return n..(n==1 and ' book' or ' books')
end
-- 135 -> "2 h 15 min" / "2 ч 15 мин" / "2 сағ 15 мин"
function F.duration(n)
  if not n then return '—' end
  n=math.floor(n)
  local h,m=n//60,n%60
  local hu=({' h',' ч',' сағ'})[lang_at];local mu=({' min',' мин',' мин'})[lang_at]
  if h==0 then return m..mu end
  return h..hu..(m>0 and (' '..m..mu) or '')
end
-- Unix seconds -> "YYYY-MM-DD" without os.date (absent on the reader).
function F.iso_date(sec)
  if type(sec)~='number' or sec<=0 or sec>4102444800 then return nil end
  local z=sec//86400+719468;local era=z//146097;local doe=z-era*146097
  local yoe=(doe-doe//1460+doe//36524-doe//146096)//365;local doy=doe-(365*yoe+yoe//4-yoe//100)
  local mp=(5*doy+2)//153;local d=doy-(153*mp+2)//5+1;local m=mp<10 and mp+3 or mp-9
  return string.format('%04d-%02d-%02d',yoe+era*400+(m<=2 and 1 or 0),m,d)
end
function F.source_name(src)
  if src=='ybx_reader' or src=='reader' then return 'YBX' end
  local p=PROVIDERS[src];return p and p[lang_at] or src
end
function F.provider_name(id) local p=PROVIDERS[id];return p and p[lang_at] or nil end
-- Cyrillic upper case, since string.upper only folds ASCII here.
local CASE={['а']='А',['б']='Б',['в']='В',['г']='Г',['д']='Д',['е']='Е',['ё']='Ё',['ж']='Ж',['з']='З',['и']='И',['й']='Й',['к']='К',['л']='Л',['м']='М',['н']='Н',['о']='О',['п']='П',['р']='Р',['с']='С',['т']='Т',['у']='У',['ф']='Ф',['х']='Х',['ц']='Ц',['ч']='Ч',['ш']='Ш',['щ']='Щ',['ъ']='Ъ',['ы']='Ы',['ь']='Ь',['э']='Э',['ю']='Ю',['я']='Я',['ә']='Ә',['і']='І',['ң']='Ң',['ғ']='Ғ',['ү']='Ү',['ұ']='Ұ',['қ']='Қ',['ө']='Ө',['һ']='Һ'}
-- Keyboard layouts. Russian is always available, Kazakh is optional (settings).
local KB_ROWS={
  en={ {'q','w','e','r','t','y','u','i','o','p'}, {'a','s','d','f','g','h','j','k','l'}, {'z','x','c','v','b','n','m'} },
  -- Standard ЙЦУКЕН rows; ё closes the third row so no row exceeds 12 keys.
  ru={ {'й','ц','у','к','е','н','г','ш','щ','з','х','ъ'}, {'ф','ы','в','а','п','р','о','л','д','ж','э'}, {'я','ч','с','м','и','т','ь','б','ю','ё'} },
}
-- Kazakh is the Russian pad plus its own row of nine letters on top, so the
-- Kazakh keys stay as wide as the Latin ones instead of squeezing 17 per row.
KB_ROWS.kk=KB_ROWS.ru
local KB_EXTRA={kk={'ә','і','ң','ғ','ү','ұ','қ','ө','һ'}}
local KB_NAMES={en={'EN','English'},ru={'РУ','Русский'},kk={'ҚА','Қазақша'}}

local token, pairing, items, page, shelf, query = '', nil, {}, 1, 'reading', ''
local selected, selected_index, view = nil, 1, 'home'
local download_file, download_bytes, download_prefix = nil, 0, ''
local download_native = false
-- On stock 2.21 ctx.storage and ctx.files are different trees and only
-- ctx.files has append; system.open('file') reads the files tree. EPUBs live
-- there. CrossPoint has no ctx.files, so storage is used.
local book_store, book_save = nil, 'storage'
local events = {}
local auto_reader_sync = false
local reader_supported
local clear_partial
local function header(resp,name)
  for k,v in pairs(resp.headers or {}) do if tostring(k):lower()==name then return v end end
  return nil -- explicit: tonumber() of no value raises an error
end
local retry_at, request_id, active = 0, 0, nil
local request_started = 0
local ui={focus=false,tab='Library',data={},loaded=false,local_page=1,download_error=nil,notice='',auto_library=false,credentials=nil,reveal=false,month=nil,day=nil,award_page=1}
local pair_qr
local drawn_view, return_view = nil, 'catalog'
local function short_utf8(value,count)
  local text=tostring(value or '')
  if not utf8.len(text) then return '' end
  local stop=utf8.offset(text,count+1)
  return stop and text:sub(1,stop-1) or text
end
local function now() return c.clock:millis() end
local mirror={host=nil,keep_until=0}
local function server_mode() local m=c and c.state.server;return (m=='main' or m=='eu' or m=='pt') and m or 'auto' end
local function api_host()
  local m=server_mode()
  if m=='auto' then return mirror.host~=nil and mirror.keep_until>(now() or 0) and mirror.host or HOSTS.main end
  return HOSTS[m]
end
-- Addresses handed to the firmware are kept, so they follow only an explicit choice.
local function fixed_host() local m=server_mode();return m=='auto' and HOSTS.main or HOSTS[m] end
local function host_of(url) for _,h in pairs(HOSTS) do if url:sub(1,#h+1)==h..'/' then return h end end end
local function note_host(h)
  if server_mode()~='auto' or not h then return end
  if h==HOSTS.main then mirror.host=nil;mirror.keep_until=0 else mirror.host=h;mirror.keep_until=(now() or 0)+5*60*1000 end
end
-- Auto moves along this list on a connection failure only, so every host is
-- tried once per request. The plain-HTTP KOSync address follows the same keys.
F.auto_order={HOSTS.main,HOSTS.eu,HOSTS.pt}
F.sync_hosts={main='http://sync.ybx.app',eu='http://esync.ybx.app',pt='http://psync.ybx.app'}
function F.next_host(h) for i,x in ipairs(F.auto_order) do if x==h then return F.auto_order[i%#F.auto_order+1] end end end
-- Keep the radio awake while the app is talking: the reader drops Wi-Fi when it
-- looks idle, which kills a long EPUB transfer mid-body (the community network
-- apps all do this). The argument is milliseconds; refresh at most every 30 s.
local wifi_kept_at=nil
local function keep_wifi(force)
  local t=now()
  if not force and t and wifi_kept_at and t-wifi_kept_at<30000 then return end
  wifi_kept_at=t
  pcall(function() c.net:keep_wifi(5*60*1000) end)
end
-- The host allocates a fresh Lua string for every delivered chunk. If its
-- collector only runs on ticks, a fast transfer fills the heap and the host
-- stops delivering (observed: 887529 of 1215209 bytes in 1.9 s). Collect from
-- the download callback when the firmware exposes collectgarbage.
local gc=collectgarbage
local function heap_kb()
  if not gc then return nil end
  local ok,kb=pcall(gc,'count')
  return ok and type(kb)=='number' and math.floor(kb) or nil
end
local function tick_rate(fast)
  pcall(function() c:set_tick(fast and 100 or 1000) end)
end
local function redraw(s) if s then message=short_utf8(s,256);ui.message_ok=false;ui.message_key=nil end; c:invalidate() end
-- A translated status message; success keys get a "Done" title.
local function say(key,...) redraw(T(key,...));ui.message_ok=OK_MESSAGES[key] or false;ui.message_key=key end
local function encode(s)
  return (tostring(s):gsub('[^%w%-_%.~]',function(x) return string.format('%%%02X',string.byte(x)) end))
end
local function event_id()
  return string.format('%08x%08x%08x%08x',math.random(0,0x7fffffff),math.random(0,0x7fffffff),
    math.random(0,0x7fffffff),math.random(0,0x7fffffff))
end
-- YBX /events rejects anything but `<8 hex>-<decimal digits>` with HTTP 400.
-- The native plugin mints the same shape from a per-boot nonce plus a counter.
local wire_event_serial=0
local function valid_wire_event_id(value)
  if type(value)~='string' or #value>24 or not value:match('^[0-9a-fA-F]+%-%d+$') then return false end
  return #(value:match('^[0-9a-fA-F]+'))==8
end
local function wire_event_id()
  wire_event_serial=wire_event_serial+1
  return string.format('%08x-%d',math.random(0,0x7fffffff),wire_event_serial)
end
-- Library cache. Shelf pages, stats, achievements and the calendar are kept on
-- the SD card so screens open at once, even right after launch; a quiet
-- background request then refreshes what is on screen, and idle time is used
-- to prefetch the next pages. Only a cache miss shows the blocking loader.
local CACHE_FILE='ybx-cache.json'
local cache={pages={},order={}}
local fresh={}          -- keys refreshed during this session
local bg={id=0}         -- the single background request
local function quiet_cancel()
  if bg.handle then pcall(function() bg.handle:cancel() end) end
  bg.id=bg.id+1;bg.handle=nil;bg.started=nil
end
local function clean_items(raw)
  if type(raw)~='table' then return nil end
  local list={}
  for i,item in ipairs(raw) do
    if i>3 then break end
    if type(item)=='table' and (type(item.id)=='string' or type(item.id)=='number') and #tostring(item.id)<=256 then
      list[#list+1]={id=tostring(item.id),title=short_utf8(item.title or item.id,96),author=short_utf8(item.author,64),description=short_utf8(item.description,768),percent=type(item.percent)=='number' and math.max(0,math.min(100,item.percent)) or nil}
    end
  end
  return list
end
local function items_signature(list)
  local parts={}
  for _,item in ipairs(list or {}) do parts[#parts+1]=item.id..'\1'..(item.title or '')..'\1'..tostring(item.percent) end
  return table.concat(parts,'\2')
end
local function cache_save()
  pcall(function()
    c.storage:write(CACHE_FILE,c.json:encode({owner=c.state.event_owner,pages=cache.pages,order=cache.order,
      profile=cache.profile,awards=cache.awards,month=cache.month,days=cache.days}))
  end)
end
local function cache_clear()
  cache={pages={},order={}};fresh={};quiet_cancel();ui.book_details=nil
  pcall(function() c.storage:write(CACHE_FILE,'') end)
end
local function cache_load()
  cache={pages={},order={}};fresh={}
  local ok,value=pcall(function()
    local raw=c.storage:read(CACHE_FILE)
    return type(raw)=='string' and #raw>2 and #raw<=65536 and c.json:decode(raw) or nil
  end)
  if not ok or type(value)~='table' or value.owner~=c.state.event_owner then return end
  for _,key in ipairs(type(value.order)=='table' and value.order or {}) do
    local list=type(key)=='string' and #key<=48 and type(value.pages)=='table' and clean_items(value.pages[key])
    if list and not cache.pages[key] and #cache.order<10 then cache.pages[key]=list;cache.order[#cache.order+1]=key end
  end
  if type(value.profile)=='table' then cache.profile=value.profile end
  if type(value.awards)=='table' then cache.awards=value.awards end
  if type(value.month)=='string' and value.month:match('^%d%d%d%d%-%d%d$') and type(value.days)=='table' then cache.month=value.month;cache.days=value.days end
end
local function cache_put(key,list)
  if not cache.pages[key] then cache.order[#cache.order+1]=key end
  cache.pages[key]=list;fresh[key]=true
  while #cache.order>10 do cache.pages[table.remove(cache.order,1)]=nil end
  cache_save()
end
local function save_token(value)
  if value~=token then
    local cleared,saved=pcall(function() return c.storage:write('ybx-stock-sleep.json','') end)
    if not cleared or not saved then say('account_kept');return false end
    if type(rawget(c,'crosspoint_sleep_refresh'))=='function' then
      local ok,cleared=pcall(c.crosspoint_sleep_refresh,nil)
      if not ok or not cleared then say('account_kept');return false end
    end
    if type(rawget(c,'crosspoint_reader_upload'))=='function' then
      local ok,cleared=pcall(c.crosspoint_reader_upload,nil)
      if not ok or not cleared then say('account_kept');return false end
    end
    events={};c.state.event_owner=event_id()
  end
  ui.credentials=nil;ui.reveal=false;ui.data={};ui.loaded=false;ui.library_cache=nil;ui.auto_library=false;items={}
  if value~=token then cache_clear() end
  token=value; c.state.token=value; c:save_state()
  if reader_supported() then pcall(function() c.storage:write('reader-owner.txt',token~='' and c.state.event_owner or '') end) end
  return true
end
local function request(path, body, auth, done, headers, on_data, save, timeout)
  if busy then return end
  if now()<retry_at then say('err_wait'); return end
  quiet_cancel()
  headers=headers or {}
  if auth then headers.Authorization='Bearer '..token end
  if type(body)=='table' then headers['Content-Type']='application/json' end
  busy=true; selected_index=1; keep_wifi(true); request_started=now(); request_id=request_id+1
  local generation=request_id
  local received=false
  redraw('')
  local function send(url,hops)
    local ok, handle, err=pcall(function()
      return c.net:request({url=url,method=body and 'POST' or 'GET',on_data=on_data and function(ctx,chunk)
        if generation==request_id and busy then received=true;on_data(ctx,chunk) end
      end or nil,
        body=type(body)=='string' and body or body and c.json:encode(body) or nil,headers=headers,timeout_ms=timeout or 30000,save=save},function(_,resp)
        if generation~=request_id then return end
        local status=type(resp)=='table' and tonumber(resp.status) or 0
        local host=host_of(url)
        -- Unreachable host: move on to the next one (Auto mode, nothing received yet).
        if status<=0 and host and hops<#F.auto_order-1 and not received and not save and server_mode()=='auto' then
          request_started=now();send(F.next_host(host)..url:sub(#host+1),hops+1);return
        end
        busy=false; active=nil
        if type(resp)~='table' then say('err_no_response'); return end
        if status>0 then note_host(host) end
        if (status==401 or status==403) and auth then if download_file then clear_partial() end; if not save_token('') then return end; view='expired'; redraw(''); return end
        if status==429 then
          if download_file then clear_partial() end
          local seconds=tonumber(header(resp,'retry-after')) or 60
          retry_at=now()+math.max(1,math.min(seconds,3600))*1000
          say('err_rate'); return
        end
        done(resp,status)
      end)
    end)
    if not ok or not handle then
      if generation==request_id then request_id=request_id+1;busy=false;if download_file then clear_partial() end;redraw(T('err_request')..tostring(err or handle)) end
    elseif generation==request_id and busy then active=handle
    else pcall(function() handle:cancel() end) end
  end
  send(path:sub(1,8)=='https://' and path or api_host()..API_PATH..path,0)
end
local function decode(resp)
  if type(resp.body)~='string' then return {} end
  local ok,value=pcall(function() return c.json:decode(resp.body) end)
  return ok and type(value)=='table' and value or {}
end
-- A background GET: no loader, no busy flag, dropped as soon as a foreground
-- request starts. done() receives the decoded body of a 200 response.
local function quiet(path,done)
  if busy or bg.handle or token=='' or now()<retry_at then return false end
  bg.id=bg.id+1;local gen=bg.id;local finished=false
  keep_wifi()
  local ok,handle=pcall(function()
    local url=api_host()..API_PATH..path
    return c.net:request({url=url,method='GET',headers={Authorization='Bearer '..token},timeout_ms=20000},function(_,resp)
      finished=true
      if gen~=bg.id then return end
      bg.handle=nil;bg.started=nil
      if type(resp)~='table' then return end
      local status=tonumber(resp.status) or 0
      if status>0 then note_host(host_of(url)) end
      if status==401 or status==403 then if save_token('') then view='expired';redraw('') end;return end
      if status==429 then retry_at=now()+math.max(1,math.min(tonumber(header(resp,'retry-after')) or 60,3600))*1000;return end
      if status==200 then done(decode(resp)) end
    end)
  end)
  if not ok or not handle then return false end
  if not finished and gen==bg.id then bg.handle=handle;bg.started=now() end
  return true
end
local function failure(resp,status)
  local data=decode(resp)
  if status==409 then say('err_source')
  elseif status==404 and tostring(header(resp,'x-ybx-device-removed') or ''):lower()=='true' then say('err_removed')
  elseif status==502 or status==503 or status==504 then say('err_unavailable')
  elseif status==0 then say('err_no_network')
  -- CrossPoint reports 'error'; stock Licorice names the same field 'err'.
  else redraw(T('err_http',status)..tostring(data.error or data.err or '-')) end
end
-- Match the native plugin's best-effort Unix time (zero when unset).
local function epoch()
  local ok,t=pcall(function() return c.clock:now() end)
  local value=ok and type(t)=='table' and math.tointeger(t.epoch_sec)
  return value and value>=0 and value<=4102444800 and value or 0
end
local function persist_events()
  local ok,result=pcall(function()
    return c.storage:write('ybx-events.json',c.json:encode({owner=c.state.event_owner,events=events}))
  end)
  return ok and result
end
local function queue_download_event()
  if #events>=16 then return false end
  events[#events+1]={event='book.downloaded',event_id=wire_event_id(),ts=epoch()}
  if not persist_events() then table.remove(events);return false end
  return true
end
local function sync_events()
  local event=events[1]
  if not event then say('sync_none');return end
  if token=='' then say('connect_first');return end
  request('/events?v='..VERSION,event,true,function(resp,status)
    if status>=200 and status<300 then
      local sent=table.remove(events,1)
      if not persist_events() then
        table.insert(events,1,sent);say('sync_sd_error');return
      end
      -- One event per action keeps network use bounded and cancellable.
      say('sync_reported',#events)
    else say('sync_pending',status) end
  end)
end
reader_supported=function()
  local ok,value=pcall(function() return c.crosspoint_reader_events end)
  return ok and value==true
end
local function reader_book_map()
  local ok,value=pcall(function()
    local raw=c.storage:read('reader-books.json')
    return type(raw)=='string' and #raw<=32768 and c.json:decode(raw)
  end)
  if not ok or type(value)~='table' or type(value.owner)~='string' or type(value.books)~='table' then return nil end
  local result={}
  if ok and type(value)=='table' and value.owner==c.state.event_owner and type(value.books)=='table' then
    local count=0
    for file,id in pairs(value.books) do
      if count>=17 then break end
      if NAMES.valid(file) and type(id)=='string' and #id<=256 then
        result[file]=id;count=count+1
      end
    end
  end
  return result
end
local function remember_reader_book(file,id)
  if not c.state.reader_files then return false end
  local needed={[file]=true}
  local raw=c.storage:read('reader-events.jsonl')
  if type(raw)~='string' or #raw>10240 or (#raw>0 and raw:sub(-1)~='\n') then return false end
  local count=0
  for line in raw:gmatch('(.-)\n') do
    count=count+1;if count>16 then return false end
    local ok,event=pcall(function() return c.json:decode(line) end)
    if ok and type(event)=='table' and event.owner==c.state.event_owner and type(event.file)=='string' then needed[event.file]=true end
  end
  local books=reader_book_map()
  if not books then return false end
  for name in pairs(books) do if not needed[name] then books[name]=nil end end
  for _,book in ipairs(c.state.downloads) do if needed[book.file] then books[book.file]=book.id end end
  books[file]=id
  local encoded=c.json:encode({owner=c.state.event_owner,books=books})
  return #encoded<=32768 and c.storage:write('reader-books.json',encoded)
end
local function sync_reader_events()
  if not reader_supported() then say('sync_needs_cp');return end
  if token=='' then say('connect_first');return end
  local filename='reader-events.jsonl'
  local ok,raw=pcall(function() return c.storage:read(filename) end)
  if not ok or type(raw)~='string' then say('sync_queue_error');return end
  if type(raw)~='string' or #raw>10240 or (#raw>0 and raw:sub(-1)~='\n') then say('sync_queue_error');return end
  local map=reader_book_map()
  if not map then say('sync_queue_error');return end
  local offset,count=1,0
  for line in raw:gmatch('(.-)\n') do
      count=count+1;if count>16 then say('sync_queue_error');return end
      local next_offset=offset+#line+1
      local decoded,event=pcall(function() return #line<640 and c.json:decode(line) end)
      local book
      if decoded and type(event)=='table' and event.owner==c.state.event_owner then
        for _,item in ipairs(c.state.downloads) do if item.file==event.file then book=item;break end end
        if not book and map[event.file] then book={id=map[event.file]} end
        if not book then say('sync_queue_error');return end
      end
      local valid=book and type(event.event_id)=='string' and #event.event_id<=24 and event.event_id:match('^[0-9a-f]+%-%d+$')
        and type(event.ts)=='number' and event.ts>=0 and event.ts<=4102444800
      local body=valid and {event=event.event,event_id=event.event_id,ts=event.ts,book_id=book.id}
      if valid and event.event=='reader.session' then
        valid=type(event.doc)=='string' and #event.doc==32 and event.doc:match('^[0-9a-f]+$')
          and type(event.start)=='number' and event.start>0 and event.start<=4102444800
          and type(event.duration)=='number' and event.duration>=10 and event.duration<=4294967295
          and type(event.progress_bp)=='number' and event.progress_bp>=0 and event.progress_bp<=10000
        if valid then body.doc=event.doc;body.start=event.start;body.duration=event.duration;body.progress_bp=event.progress_bp end
      elseif valid and event.event=='reader.exit' then
        valid=type(event.percent)=='number' and event.percent>=0 and event.percent<=100
        if valid then body.percent=event.percent end
      elseif valid then valid=event.event=='reader.open' end
      if valid then
        request('/events?v='..VERSION,body,true,function(_,status)
          if status<200 or status>=300 then say('sync_pending',status);return end
          -- Reader and XTApp activities are exclusive; guard against a changed snapshot anyway.
          local removed,result=pcall(function()
            if c.storage:read(filename)~=raw then return false end
            return c.storage:write(filename,raw:sub(next_offset))
          end)
          if not removed or not result then say('sync_sd_error');return end
          sync_reader_events()
        end)
        return
      end
      offset=next_offset
  end
  if #raw>0 then pcall(function() c.storage:write(filename,'') end) end
  say('sync_done')
end
local function refresh_sleep_card()
  if token=='' then say('connect_first');return end
  if busy or now()<retry_at then say('sleep_busy');return end
  if not c.state.sleep_cache_initialized then
    if not SleepCard.initialize(c.storage,c.json) then say('sleep_cache_failed');return end
    c.state.sleep_cache_initialized=true;c:save_state()
  end
  local data=''
  local generation=request_id+1
  request('/sleep-image?w=480&h=800&v='..VERSION,nil,true,function(resp,status)
    if status~=200 then say('sleep_refresh_failed',status);return end
    local expected=tonumber(header(resp,'content-length'))
    if expected and expected~=#data then say('sleep_incomplete');return end
    local saved=SleepCard.save(c.storage,c.json,data)
    say(saved and 'sleep_saved' or 'sleep_save_failed')
  end,nil,function(_,chunk)
    if generation~=request_id then return end
    if type(chunk)~='string' or #chunk>SleepCard.size-#data then
      request_id=request_id+1
      if active then pcall(function() active:cancel() end) end
      active=nil;busy=false;data='';say('sleep_too_big');return
    end
    request_started=now();data=data..chunk
  end)
end
local function pair()
  request('/auth/device',{client_id='crosspoint'},false,function(resp,status)
    local data=decode(resp)
    if status<200 or status>=300 or type(data.device_code)~='string' or type(data.user_code)~='string' then failure(resp,status); return end
    pairing={code=data.device_code,user=data.user_code,interval=math.max(5,tonumber(data.interval) or 5),
      expires=now()+math.max(1,tonumber(data.expires_in) or 600)*1000,next_poll=0}
    if pair_qr then pcall(function() pair_qr:release() end);pair_qr=nil end
    local link=data.verification_uri_complete
    if type(link)~='string' or #link>256 or not host_of(link) then link=HOSTS.main..'/pair?code='..encode(data.user_code) end
    local ok,qr=pcall(function() return c.qr:encode(link) end)
    pair_qr=ok and qr or nil
    view='pair'; redraw('')
  end)
end
local catalog
local function poll()
  if not pairing then return end
  if now()>=pairing.expires then pairing=nil; view='pair_expired'; redraw(''); return end
  if now()<pairing.next_poll then say('pair_slow'); return end
  pairing.next_poll=now()+pairing.interval*1000
  request('/auth/token',{grant_type='urn:ietf:params:oauth:grant-type:device_code',device_code=pairing.code},false,function(resp,status)
    local data=decode(resp)
    if status>=200 and status<300 and type(data.access_token)=='string' and #data.access_token>0 and #data.access_token<=4096 then
      if not save_token(data.access_token) then return end;pairing=nil;view='paired';redraw('');return
    end
    if data.error=='authorization_pending' then say('pair_pending')
    elseif data.error=='slow_down' then pairing.interval=pairing.interval+5; pairing.next_poll=now()+pairing.interval*1000; say('pair_slow')
    elseif data.error=='expired_token' or data.error=='access_denied' then pairing=nil; view='pair_expired'; say('pair_denied')
    else failure(resp,status) end
  end)
end
local function catalog_path(sh,pg,q)
  local paths={yandex='/catalog?shelf=all',wb='/wb/catalog?stock=1',litres='/litres/catalog?stock=1'}
  local path=(paths[sh] or '/catalog/all?kind='..sh)..'&page='..pg..'&limit=3&v='..VERSION
  if q~='' then path=path..'&q='..encode(q) end
  return path
end
local function page_key(sh,pg) return sh..'|'..pg end
local function show_page(list)
  items=list;ui.loaded=true
  if query=='' then ui.library_cache={items=items,page=page,shelf=shelf} end
  view='catalog';selected_index=1;redraw('')
  F.update_auto()
end
-- Refresh one shelf page in the background; redraw only if it changed and is
-- still the page on screen.
local function revalidate_page(sh,pg)
  local key=page_key(sh,pg)
  return quiet(catalog_path(sh,pg,''),function(data)
    local list=clean_items(data.items)
    if not list then return end
    local before=items_signature(cache.pages[key])
    cache_put(key,list)
    if view=='catalog' and query=='' and shelf==sh and page==pg and message=='' and items_signature(list)~=before then show_page(list) end
  end)
end
catalog=function(force)
  ui.auto_library=false
  local key=query=='' and page_key(shelf,page) or nil
  local cached=key and cache.pages[key]
  if cached and force~=true then
    show_page(cached)
    if not fresh[key] then revalidate_page(shelf,page) end
    return
  end
  request(catalog_path(shelf,page,query),nil,true,function(resp,status)
    if status~=200 then failure(resp,status); return end
    local data=decode(resp)
    local list=clean_items(data.items)
    if not list then say('err_catalog'); return end
    if key then cache_put(key,list) end
    show_page(list)
  end)
end
local function search()
  kb_open(T('kb_title'),query,function(text)
    if type(text)=='string' and text:match('%S') then query=short_utf8(text,128);ui.tab='Search';shelf='all';page=1;catalog()
    else view='search';ui.focus=false;redraw('') end
  end,'search')
  buttons={}
  redraw('')
end
clear_partial=function()
  if download_file then pcall(function() book_store:remove(download_file) end) end
  download_file=nil; c.state.pending=nil; c:save_state()
  tick_rate(false)
end
local function local_book(id)
  for _,book in ipairs(c.state.downloads or {}) do
    if book.id==id then
      local ok,size=pcall(function() return book_store:size(book.file) end)
      if ok and size and size>4 then return book.file end
    end
  end
end
local function open_book()
  local file=local_book(selected.id)
  if not file then redraw(T('err_first')); return end
  if reader_supported() and token~='' then
    local tracked,result=pcall(function()
      return remember_reader_book(file,selected.id) and c.storage:write('reader-owner.txt',c.state.event_owner) and c.storage:write(file..'.track',c.state.event_owner)
    end)
    if not tracked or not result then say('sync_track_failed');return end
  end
  local ok,result,err=pcall(function() return c.system:open('file',{name=file}) end)
  if not ok or not result then redraw(T('err_open')..tostring(err or result)) end
end
local function append_service()
  local candidates={book_store}
  local ok,service=pcall(function() return c.storage end)
  if ok and service then candidates[#candidates+1]=service end
  for _,service in ipairs(candidates) do
    if service then
      local found,fn=pcall(function() return service.append end)
      if found and type(fn)=='function' then return service,fn end
    end
  end
end
local function storage_error(ok,result,reason)
  if not ok then
    local detail=tostring(result)
    if detail:find('nil value',1,true) or detail:find('Unsupported',1,true) then return 'Append API unavailable on this firmware.' end
    return 'Storage exception: '..short_utf8(detail,110)
  end
  return 'Storage: '..short_utf8(reason or 'append returned no success',110)
end
-- Stock saves into the app sandbox but the visible name can differ from the one
-- requested. Copy a same-size entry to the expected name so the reader still
-- gets the book, and return the listing for the failure details either way.
local function adopt_saved(target,total,storage,append)
  if not (storage and append) then return nil end
  local ok,entries=pcall(function() return book_store:list() end)
  if not ok or type(entries)~='table' then return nil end
  local names={}
  for _,entry in ipairs(entries) do
    if type(entry)=='table' and type(entry.name)=='string' then
      names[#names+1]=entry.name
      local looks_ours=entry.name:sub(-5)=='.epub' or entry.name:sub(-9)=='~xtapp.dl'
      if looks_ours and entry.name~=target and total and entry.size==total then
        local copied=pcall(function()
          assert(book_store:write(target,''))
          local offset=0
          while offset<entry.size do
            local chunk=book_store:read(entry.name,offset,math.min(65536,entry.size-offset))
            assert(type(chunk)=='string' and #chunk>0)
            assert(append(storage,target,chunk))
            offset=offset+#chunk
          end
        end)
        if copied then return entry.name,names end
      end
    end
  end
  return nil,names
end
local function download()
  ui.download_error=nil
  local storage,append=append_service()
  -- Stream through ctx.storage whenever the bounded append path exists; the
  -- firmware save only remains for hosts without an append method.
  local native_save=rawget(c,'crosspoint_reader_events')==nil
  if not native_save and not (storage and append) then ui.download_error=T('err_append')..' (Append API unavailable on this firmware.)';view='download_error';redraw('');return end
  if download_file then clear_partial() end
  if not selected or type(selected.id)~='string' or #selected.id>256 then say('err_book_id');return end
  if local_book(selected.id) then say('err_already');return end
  if #(c.state.downloads or {})>=32 then say('err_full');return end
  local counter=tonumber(c.state.next_file) or 1
  local filename
  for _=1,512 do
    filename='ybx-'..counter..'.epub';counter=counter+1
    local ok,size=pcall(function() return book_store:size(filename) end)
    if ok and not size then break end
    filename=nil
  end
  if not filename then say('err_no_slot');return end
  -- "<Author> - <Title>.epub", or the first variant the reader accepts; on
  -- CrossPoint the reading tracker's "<name>.track" must fit ctx.storage too
  filename=NAMES.pick(book_store,selected.author,selected.title,filename,reader_supported() and c.storage or nil,'.track') or filename
  c.state.next_file=counter; c.state.pending=filename;c:save_state()
  download_file=filename
  download_native=native_save
  tick_rate(true)
  local tried_native=false
  local tried_stream=false
  local item={id=selected.id,title=short_utf8(selected.title,64),author=short_utf8(selected.author,64),file=filename}
  local function fetch(url,auth,hops)
    download_bytes=0;download_prefix=''
    if not native_save then
      local ok,result=pcall(function() return book_store:write(filename,'') end)
      if not ok or not result then clear_partial();ui.download_error=T('err_create');view='download_error';redraw('');return end
    end
    local write_error=nil
    local started=now()
    local chunks=0
    local function elapsed() return now()-started end
    request(url,nil,auth,function(resp,status)
      local location=header(resp,'location')
      if (status==301 or status==302 or status==303 or status==307 or status==308) and type(location)=='string' and hops<5 then
        if location:sub(1,1)=='/' and location:sub(1,2)~='//' then
          location=(url:match('^(https://[^/]+)') or api_host())..location
        end
        if location:sub(1,8)~='https://' then clear_partial();say('err_https');return end
        fetch(location,host_of(location)~=nil,hops+1);return
      end
      local reason=native_save and (type(resp.err)=='string' and resp.err or type(resp.error)=='string' and resp.error) or nil
      if native_save and status==200 then
        local probed=nil
        local function probe()
          local ok,size,prefix=pcall(function() return book_store:size(filename),book_store:read(filename,0,4) end)
          probed=ok and size or nil
          if ok and type(size)=='number' then download_bytes=size;download_prefix=type(prefix)=='string' and prefix:sub(1,4) or '' end
        end
        probe()
        local listing
        if download_bytes<4 or download_prefix~='PK\3\4' then
          local adopted,names=adopt_saved(filename,tonumber(header(resp,'content-length')),storage,append)
          if adopted then probe() end
          listing=names
        end
        if download_bytes<4 or download_prefix~='PK\3\4' then
          -- The save reported success but nothing readable appeared: report the
          -- firmware byte count and the app sandbox listing instead of a blank HTTP 200.
          if not tried_stream and append then
            tried_stream=true;native_save=false;download_native=false
            pcall(function() book_store:remove(filename) end)
            fetch(url,auth,hops)
            return
          end
          local saved=tonumber(resp.saved) or (resp.saved==true and tonumber(header(resp,'content-length'))) or nil
          local seen=(probed==nil and 'file missing' or ('app sees '..download_bytes..' B'))
            ..(saved and (', firmware saved '..saved..' B') or '')
          local files=type(listing)=='table' and #listing>0
            and (', files: '..table.concat(listing,', ',1,math.min(#listing,6))) or ', files: none'
          clear_partial();ui.download_error='Download failed (HTTP '..status..'; '..seen..(reason and (', '..reason) or '')..files..').'
          view='download_error';redraw('');return
        end
        if download_bytes>32*1024*1024 then write_error=T('err_too_big_32') end
      end
      -- Stock Licorice aborts a native save above 8 MiB and reports limit_exceeded.
      if not write_error and reason=='limit_exceeded' then
        write_error=T('err_too_big')
      end
      if write_error or status~=200 or download_bytes<4 or download_prefix~='PK\3\4' then
        local saved=tonumber(resp.saved)
        local seen='app sees '..download_bytes..' B'..(saved and (', firmware saved '..saved..' B') or '')
        clear_partial();ui.download_error=write_error or ('Download failed (HTTP '..status..'; '..seen..').');view='download_error';redraw('');return
      end
      local expected=tonumber(header(resp,'content-length'))
      if expected and not header(resp,'content-encoding') and expected~=download_bytes then
        local host_error=type(resp.err)=='string' and resp.err or type(resp.error)=='string' and resp.error
        local rate=elapsed()>0 and (download_bytes//math.max(1,elapsed())) or 0
        local heap=heap_kb()
        clear_partial();ui.download_error='Incomplete EPUB: saved '..download_bytes..' of '..expected..' bytes in '
          ..chunks..' chunks, '..elapsed()..' ms ('..rate..' KiB/s, gc='..(gc and 'on' or 'off')..(heap and (', heap='..heap..' KB') or '')..')'
          ..(host_error and (' ('..host_error..')') or '')..'.'
        view='download_error';redraw('');return
      end
      c.state.downloads=c.state.downloads or {};c.state.downloads[#c.state.downloads+1]=item
      c.state.pending=nil;download_file=nil;c:save_state();tick_rate(false)
      view='download_ready'
      local queued=queue_download_event()
      if queued then sync_events() else say('saved_queue_full') end
    end,{['Accept-Encoding']='identity'},not native_save and function(_,chunk)
      if type(chunk)~='string' or write_error then return end
      keep_wifi(); request_started=now(); chunks=chunks+1
      if #download_prefix<4 then download_prefix=(download_prefix..chunk):sub(1,4) end
      if download_bytes+#chunk>32*1024*1024 then write_error=T('err_too_big_32')
      else
        -- Hand the host's chunk straight to storage: the host already allocated
        -- it, and a second Lua copy doubles peak heap during a long transfer.
        -- 256 KiB is the per-call storage limit; chunks are 8 KiB (CrossPoint)
        -- or at most 128 KiB (stock window).
        for offset=1,#chunk,262144 do
          local piece=(offset==1 and #chunk<=262144) and chunk or chunk:sub(offset,offset+262143)
          local written_ok,written,reason=pcall(append,storage,filename,piece)
          if not written_ok or not written then
            write_error=storage_error(written_ok,written,reason)..' At '..((download_bytes+offset-1)//1024)..' KiB.'
            break
          end
        end
        if not write_error then
          local before=download_bytes;download_bytes=download_bytes+#chunk
          if gc then pcall(gc) end
          if before//262144~=download_bytes//262144 then redraw(T('downloaded_kib',download_bytes//1024)) end
        end
      end
      if write_error then
        -- A stock append that fails before the first byte may be a firmware
        -- quirk; retry the same URL once through the native save first.
        if download_bytes==0 and not native_save and not tried_native and rawget(c,'crosspoint_reader_events')==nil then
          tried_native=true;native_save=true;download_native=true
          if active then pcall(function() active:cancel() end) end
          request_id=request_id+1;active=nil;busy=false
          pcall(function() c.storage:remove(filename) end)
          write_error=nil
          fetch(url,auth,hops)
          return
        end
        if active then pcall(function() active:cancel() end) end
        request_id=request_id+1;active=nil;busy=false;clear_partial();ui.download_error=write_error;view='download_error';redraw('');return
      end
    end or nil,native_save and {to=book_save,name=filename} or nil,60000)
  end
  fetch('/books/'..encode(item.id)..'/download?v='..VERSION,true,0)
end
local function scalar(v)
  if type(v)=='table' then v=v.value end
  return type(v)=='number' and v==v and math.abs(v)<1e12 and v or nil
end
function F.parse_profile(d)
  local p={today=short_utf8(d.today,10),today_minutes=scalar(d.today_minutes),current_streak_days=scalar(d.current_streak_days),week_minutes=scalar(d.week_minutes),week_days={}}
  if type(d.year_goal)=='table' then p.year_goal={finished=scalar(d.year_goal.finished),goal=scalar(d.year_goal.goal),delta=scalar(d.year_goal.delta)} end
  p.books_year=scalar(d.books_finished_this_year)
  for i,day in ipairs(type(d.week_days)=='table' and d.week_days or {}) do
    if i>7 then break end
    if type(day)=='table' then p.week_days[i]={date=short_utf8(day.date,10),minutes=scalar(day.minutes),observed=type(day.sources)~='table' or #day.sources>0} end
  end
  p.reading={}
  for _,book in ipairs(type(d.currently_reading)=='table' and d.currently_reading or {}) do
    if #p.reading>=4 then break end
    if type(book)=='table' and (type(book.id)=='string' or type(book.id)=='number') and #tostring(book.id)<=256 then
      local pct=scalar(book.percent)
      p.reading[#p.reading+1]={id=tostring(book.id),title=short_utf8(book.title or book.id,96),author=short_utf8(book.author,64),percent=pct and math.max(0,math.min(100,pct)) or nil}
    end
  end
  return p
end
function F.parse_awards(d)
  local y=type(d.yandex)=='table' and d.yandex or {};local list={}
  for _,group in ipairs{{true,y.received},{false,y.pending}} do
    for i,item in ipairs(type(group[2])=='table' and group[2] or {}) do
      if i>20 then break end
      if type(item)=='table' then
        local progress=scalar(item.progress)
        list[#list+1]={title=short_utf8(item.title,64),description=short_utf8(item.description,256),progress=progress and math.max(0,math.min(1,progress)),earned=group[1]}
      end
    end
  end
  return list
end
function F.parse_days(days)
  local map={}
  for i,day in ipairs(type(days)=='table' and days or {}) do
    if i>31 then break end
    if type(day)=='table' and type(day.date)=='string' and day.date:match('^%d%d%d%d%-%d%d%-%d%d$') then map[day.date]={minutes=scalar(day.minutes)} end
  end
  return map
end
-- Raw responses are cached (they are small) and parsed on use.
function F.store_profile(d) cache.profile=d;fresh.profile=true;cache_save();ui.data.profile=F.parse_profile(d) end
function F.store_awards(d) cache.awards=d;fresh.awards=true;cache_save();ui.data.awards=F.parse_awards(d) end
function F.store_days(month,days) cache.month=month;cache.days=days;fresh.days=true;cache_save();ui.data.days=F.parse_days(days) end
local function profile()
  if cache.profile then
    ui.data.profile=F.parse_profile(cache.profile);ui.tab='Activity';view='activity';ui.focus=false;redraw('')
    if not fresh.profile then quiet('/reading/summary?limit=6',function(d) F.store_profile(d);if view=='activity' and message=='' then redraw('') end end) end
    return
  end
  request('/reading/summary?limit=6',nil,true,function(resp,status)
    if status~=200 then failure(resp,status);return end
    F.store_profile(decode(resp));ui.tab='Activity';view='activity';redraw('')
  end)
end
local function achievements()
  if cache.awards then
    ui.data.awards=F.parse_awards(cache.awards);ui.award_page=1;view='awards';ui.focus=false;redraw('')
    if not fresh.awards then quiet('/achievements?limit=20',function(d) F.store_awards(d);if view=='awards' and message=='' then redraw('') end end) end
    return
  end
  request('/achievements?limit=20',nil,true,function(resp,status)
    if status~=200 then failure(resp,status);return end
    F.store_awards(decode(resp));ui.award_page=1;view='awards';redraw('')
  end)
end
function F.open_calendar(month,today)
  ui.month=month;ui.day=today and today:sub(1,7)==month and today or ui.day
  if not ui.day or ui.day:sub(1,7)~=month then ui.day=nil end
  view='calendar';redraw('')
end
local function calendar()
  local today=cache.profile and cache.profile.today
  if cache.days and cache.month then
    ui.data.days=F.parse_days(cache.days);F.open_calendar(cache.month,type(today)=='string' and today or nil)
    if not fresh.days then
      local month=cache.month
      quiet('/reading/calendar?month='..month,function(d) F.store_days(month,d.days);if view=='calendar' and message=='' then redraw('') end end)
    end
    return
  end
  request('/reading/summary?limit=1',nil,true,function(resp,status)
    if status~=200 then failure(resp,status);return end
    local today=decode(resp).today
    if type(today)~='string' or not today:match('^%d%d%d%d%-%d%d%-%d%d$') then say('calendar_no_date');return end
    request('/reading/calendar?month='..today:sub(1,7),nil,true,function(answer,code)
      if code~=200 then failure(answer,code);return end
      F.store_days(today:sub(1,7),decode(answer).days);F.open_calendar(today:sub(1,7),today)
    end)
  end)
end
-- Per-book reading stats (the plugin's book card). Kept in memory for the session.
local function book_stats(book)
  ui.stats_book=book;ui.book_detail=ui.book_details and ui.book_details[book.id]
  if ui.book_detail then view='book_stats';ui.focus=false;redraw('');return end
  request('/reading/books/'..encode(book.id),nil,true,function(resp,status)
    if status~=200 then failure(resp,status);return end
    local d=decode(resp)
    local detail={percent=scalar(d.percent),minutes=scalar(d.minutes),sessions=scalar(d.sessions),
      started=math.tointeger(scalar(d.started_at)),finished=math.tointeger(scalar(d.finished_at)),sources={}}
    local seen={}
    for _,metric in ipairs{d.percent,d.minutes,d.sessions} do
      for _,src in ipairs(type(metric)=='table' and type(metric.sources)=='table' and metric.sources or {}) do
        if type(src)=='string' and #src<=32 and not seen[src] then seen[src]=true;detail.sources[#detail.sources+1]=src end
      end
    end
    if type(d.dates_source)=='string' and #d.dates_source<=32 and not seen[d.dates_source] then detail.sources[#detail.sources+1]=d.dates_source end
    ui.book_details=ui.book_details or {};ui.book_details[book.id]=detail
    ui.book_detail=detail;view='book_stats';redraw('')
  end)
end
local function revoke()
  request('/auth/revoke','',true,function(resp,status)
    if status<200 or status>=300 then failure(resp,status);return end
    if not save_token('') then return end;view='home';say('disconnected')
  end)
end
local function kosync()
  request('/auth/kosync-key','',true,function(resp,status)
    if status~=200 then failure(resp,status);return end
    local key=decode(resp).kosync_key
    if type(key)~='string' or not key:match('^kosync_[%w_-]+$') or #key>256 then say('kosync_invalid');return end
    ui.credentials=key;ui.reveal=false;view='kosync';redraw('')
  end)
end
function F.b64(data)
  local abc='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  return ((data:gsub('.',function(x) local r,b='',x:byte();for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end;return r end)..'0000')
    :gsub('%d%d%d?%d?%d?%d?',function(x) if #x<6 then return '' end;local c=0;for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end;return abc:sub(c+1,c+1) end)
    ..({'','==','='})[#data%3+1])
end
-- Ask the KOSync endpoint whether it accepts the issued key. Checked over
-- HTTPS so the key never travels in clear text from here.
function F.kosync_check()
  if not ui.credentials then return end
  request(api_host()..API_PATH..'/kosync/users/auth',nil,false,function(_,status)
    if status==200 then say('kosync_ok') else say('kosync_rejected',status) end
  end,{Authorization='Basic '..F.b64('ybx:'..ui.credentials)})
end
-- Separate key for syncing quotes and notes over KOSync (plugin 1.6.13+).
function F.clippings_get()
  request('/auth/clippings-key','',true,function(resp,status)
    if status~=200 then failure(resp,status);return end
    local d=decode(resp);local key=d.kosync_key
    -- The server answers with the clippings base of the host this request used:
    -- main when my.ybx.app is reachable, a mirror when it is blocked. All bases
    -- share one clipping store, so all are accepted; anything else is not.
    local base=API_PATH..'/kosync'
    local url=d.sync_url
    local trusted=type(url)=='string' and host_of(url) or nil
    if type(key)~='string' or not key:match('^kosync_[%w_-]+$') or #key~=50 or d.clippings_enabled~=true
      or not trusted or url~=trusted..base then say('clippings_invalid');return end
    ui.clip_key=key;ui.clip_url=d.sync_url;ui.reveal=false;view='clippings';redraw('')
  end)
end
function F.clippings_revoke()
  request('/auth/clippings-key/revoke','',true,function(resp,status)
    if status<200 or status>=300 then failure(resp,status);return end
    ui.clip_key=nil;ui.clip_url=nil;ui.reveal=false;view='clippings';say('clippings_revoked')
  end)
end
local function downloads()
  ui.tab='Library';ui.local_page=1;view='downloads';selected_index=1;redraw('')
end
local function delete_book()
  local file=local_book(selected.id)
  if not file then say('err_no_local');return end
  if reader_supported() then
    local cleaned,result=pcall(function()
      if not remember_reader_book(file,selected.id) then return false end
      local track=file..'.track'
      return not c.storage:size(track) or c.storage:remove(track)
    end)
    if not cleaned or not result then say('err_remove_meta');return end
  end
  local ok,result=pcall(function() return book_store:remove(file) end)
  if not ok or not result then say('err_remove');return end
  for i,book in ipairs(c.state.downloads or {}) do
    if book.file==file then table.remove(c.state.downloads,i);break end
  end
  c:save_state();say('removed')
end
local function selftest()
  local name='ybx-test.txt'
  local service,append=append_service()
  if not service then ui.notice=T('err_append');view='storage';redraw('');return end
  local ok,err=pcall(function()
    assert(service:write(name,'YBX'))
    assert(append(service,name,' test'))
    local result,reason=service:read(name,0,8)
    assert(result=='YBX test','Read-back mismatch: type='..type(result)..', size='..tostring(service:size(name))..', bytes='..(type(result)=='string' and #result or 0)..', value='..(type(result)=='string' and string.format('%q',result:sub(1,16)) or tostring(reason)))
    assert(service:remove(name))
  end)
  ui.notice=ok and T('storage_ok') or T('storage_failed')..short_utf8(err,160);view='storage';redraw('')
end
local function text(g,x,y,s,font)
  g:text(math.floor(x),math.floor(y),tostring(s or ''),{font=c.fonts[font or 'small'] or c.fonts.small})
end
local width
local function rtext(g,right,y,s,font) text(g,right-width(s,font),y,s,font) end
width=function(s,font)
  local f=c.fonts[font or 'small'] or c.fonts.small
  local ok,w=pcall(function() return f:measure(s) end)
  return ok and type(w)=='number' and w or (utf8.len(s) or #s)*12
end
local function fit(s,pixels,font)
  s=short_utf8(s,768)
  if width(s,font)<=pixels then return s end
  local out=''
  for _,ch in utf8.codes(s) do local next=out..utf8.char(ch);if width(next..'...',font)>pixels then break end;out=next end
  return out..'...'
end
local function paragraph(g,x,y,s,pixels,lines,font)
  local words={};for word in short_utf8(s,768):gmatch('%S+') do words[#words+1]=word end
  local at=1;local step=font=='large' and 34 or 28
  for row=1,lines do
    if at>#words then break end
    local value=words[at];at=at+1
    while at<=#words and width(value..' '..words[at],font)<=pixels do value=value..' '..words[at];at=at+1 end
    if row==lines and at<=#words then value=value..' '..table.concat(words,' ',at) end
    text(g,x,y+(row-1)*step,fit(value,pixels,font),font)
  end
end
local function fill(g,x,y,w,h)
  local x2,y2=math.floor(x+w+0.5),math.floor(y+h+0.5)
  x,y=math.floor(x+0.5),math.floor(y+0.5);w,h=x2-x,y2-y
  if w<=0 or h<=0 then return end
  local ok,fn=pcall(function() return g.fill_rect end)
  if ok and type(fn)=='function' then fn(g,x,y,w,h) else g:rect(x,y,w,h,{fill=true}) end
end
local function line(g,x,y,x2,y2) g:line(math.floor(x),math.floor(y),math.floor(x2),math.floor(y2)) end
local function rounded(g,x,y,w,h,radius)
  local r=radius or 10
  line(g,x+r,y,x+w-r,y);line(g,x+r,y+h,x+w-r,y+h)
  line(g,x,y+r,x,y+h-r);line(g,x+w,y+r,x+w,y+h-r)
  for _,p in ipairs{{x,y,1,1},{x+w,y,-1,1},{x,y+h,1,-1},{x+w,y+h,-1,-1}} do
    local a,b,sx,sy=table.unpack(p)
    line(g,a,b+sy*r,a+sx*3,b+sy*3);line(g,a+sx*3,b+sy*3,a+sx*r,b)
  end
end
-- Curves for the keyboard and switches, drawn as short lines and 1 px spans so
-- they need nothing beyond line/rect (no colour or circle primitives).
local function ring(g,cx,cy,rx,ry)
  local steps=20;local px,py=cx+rx,cy
  for i=1,steps do
    local a=i*2*math.pi/steps;local nx,ny=cx+rx*math.cos(a),cy+(ry or rx)*math.sin(a)
    line(g,px,py,nx,ny);px,py=nx,ny
  end
end
local function half(r,d) local v=r*r-d*d;return v>0 and math.sqrt(v) or 0 end
local function disc(g,cx,cy,r)
  for dy=-r+1,r-1 do local w=half(r,dy+0.5);if w>=0.5 then fill(g,cx-w,cy+dy,2*w,1) end end
end
-- Pill switch. On: solid track with a white knob (a hole in the fill) holding
-- a check mark. Off: outlined track with a solid knob on the left.
local function pill(g,x,y,on)
  local w,h=64,34;local r=h/2;local kr=12;local kx=x+w-r
  for dy=0,h-1 do
    local d=dy+0.5-r;local cw=half(r,d)
    local a,b=x+r-cw,x+w-r+cw
    if on then
      local hw=half(kr,d)
      if hw>0 then fill(g,a,y+dy,kx-hw-a,1);fill(g,kx+hw,y+dy,b-kx-hw,1) else fill(g,a,y+dy,b-a,1) end
    else
      local iw=half(r-2,d)
      if iw>0 then fill(g,a,y+dy,(x+r-iw)-a,1);fill(g,x+w-r+iw,y+dy,b-(x+w-r+iw),1) else fill(g,a,y+dy,b-a,1) end
    end
  end
  if on then
    local cy=y+r
    for o=0,1 do line(g,kx-5,cy+o,kx-1,cy+5+o);line(g,kx-1,cy+5+o,kx+6,cy-5+o) end
  else disc(g,x+r,y+r,11) end
end
-- Outline icons use the same supported line/rectangle primitives on both hosts.
local glyphs={
 back={{19,4,9,12},{9,12,19,20},{9,12,23,12}}, next={{8,4,16,12},{16,12,8,20}},
 search={{10,2,14,3},{14,3,17,6},{17,6,18,10},{18,10,17,14},{17,14,14,17},{14,17,10,18},{10,18,6,17},{6,17,3,14},{3,14,2,10},{2,10,3,6},{3,6,6,3},{6,3,10,2},{16,16,23,23}},
 book={{2,3,10,5},{10,5,12,8},{12,8,14,5},{14,5,22,3},{2,3,2,20},{22,3,22,20},{2,20,10,20},{10,20,12,23},{12,23,14,20},{14,20,22,20},{12,8,12,23}},
 library={{3,3,3,22},{8,3,8,22},{13,3,13,22},{18,3,23,21},{2,7,9,7},{12,17,15,17}},
 activity={{4,15,4,23},{11,7,11,23},{18,1,18,23}},
 settings={{1,6,8,6},{14,6,23,6},{11,2,11,10},{1,17,15,17},{21,17,23,17},{18,13,18,21}},
 download={{12,1,12,16},{6,10,12,16},{12,16,18,10},{3,17,3,23},{3,23,21,23},{21,23,21,17}},
 check={{2,12,9,19},{9,19,23,3}}, close={{4,4,20,20},{4,20,20,4}},
 refresh={{4,9,7,3},{7,3,18,3},{18,3,22,9},{22,9,16,9},{22,9,22,3},{20,15,17,21},{17,21,6,21},{6,21,2,15},{2,15,8,15}},
 user={{8,2,16,2},{16,2,18,6},{18,6,16,10},{16,10,8,10},{8,10,6,6},{6,6,8,2},{4,23,4,18},{4,18,8,14},{8,14,16,14},{16,14,20,18},{20,18,20,23}},
 moon={{15,2,6,5},{6,5,2,12},{2,12,6,20},{6,20,15,23},{15,23,22,17},{22,17,13,17},{13,17,9,10},{9,10,15,2}},
 calendar={{2,5,22,5},{22,5,22,23},{22,23,2,23},{2,23,2,5},{2,10,22,10},{7,1,7,7},{17,1,17,7},{7,15,10,15},{14,15,17,15}},
 award={{7,2,17,2},{17,2,21,8},{21,8,17,14},{17,14,7,14},{7,14,3,8},{3,8,7,2},{7,14,5,24},{5,24,12,20},{12,20,19,24},{19,24,17,14}},
 info={{12,6,12,7},{12,11,12,18},{5,3,19,3},{19,3,23,8},{23,8,23,17},{23,17,18,22},{18,22,6,22},{6,22,1,17},{1,17,1,8},{1,8,5,3}}, warning={{12,2,1,22},{1,22,23,22},{23,22,12,2},{12,8,12,15},{12,18,12,19}},
 storage={{2,3,22,3},{22,3,22,23},{22,23,2,23},{2,23,2,3},{2,17,22,17},{5,20,7,20}},
 trash={{3,6,21,6},{7,2,17,2},{5,6,7,23},{7,23,17,23},{17,23,19,6},{10,10,10,18},{14,10,14,18}},
 wifi={{2,7,7,3},{7,3,17,3},{17,3,22,7},{6,12,10,9},{10,9,14,9},{14,9,18,12},{10,17,14,17},{12,21,12,22}},
 more={{3,12,4,12},{11,12,12,12},{19,12,20,12}}, eye={{1,12,6,6},{6,6,18,6},{18,6,23,12},{23,12,18,18},{18,18,6,18},{6,18,1,12},{12,9,12,15}}
}
local function icon(g,name,x,y,size)
  local paths=glyphs[name] or glyphs.info;local scale=(size or 24)/24
  for _,p in ipairs(paths) do
    local dx=math.abs(p[3]-p[1])>=math.abs(p[4]-p[2]) and 0 or 1;local dy=dx==0 and 1 or 0
    line(g,x+p[1]*scale,y+p[2]*scale,x+p[3]*scale,y+p[4]*scale)
    line(g,x+p[1]*scale+dx,y+p[2]*scale+dy,x+p[3]*scale+dx,y+p[4]*scale+dy)
  end
end
local function hit(g,x,y,w,h,action,label)
  local n=#buttons+1;buttons[n]={x=x,y=y,w=w,h=h,action=action,label=label}
  if ui.focus and selected_index==n then g:rect(x-2,y-2,w+4,h+4) end
end
local function ib(g,name,x,y,action,label)
  hit(g,x,y,48,48,action,label);icon(g,name,x+12,y+12)
end
local enter_sleep
local STORES_URL='https://ybx.app'
function F.drop_stores_qr() if ui.stores_qr then pcall(function() ui.stores_qr:release() end);ui.stores_qr=nil end end
local function go(name,msg)
  if view=='stores' and name~='stores' then F.drop_stores_qr() end
  if view=='sleep' and name~='sleep' then
    if ui.sleep_picture then pcall(function() ui.sleep_picture:release() end);ui.sleep_picture=nil end
    ui.sleep_runs=nil
  end
  view=name;ui.focus=false;redraw(msg or '')
end
local function welcome() go('welcome') end
local function library()
  ui.tab='Library';query=''
  if token=='' then welcome();return end
  local cache=ui.library_cache
  if cache then items=cache.items;page=cache.page;shelf=cache.shelf;go('catalog') else shelf='reading';page=1;catalog() end
end
local function back()
  if view=='stores' then
    F.drop_stores_qr();local to=ui.stores_back or 'catalog'
    if to=='catalog' then library() else go(to) end
    return
  end
  if view=='kosync' then ui.credentials=nil;ui.reveal=false end
  if view=='clippings' then ui.clip_key=nil;ui.clip_url=nil;ui.reveal=false end
  local parent={offline='support',settings='catalog',account='settings',disconnect='account',forget='account',sleep='settings',sleep_options='sleep',reader_sleep='settings',kosync='settings',support='settings',storage='support',about='support',activity='catalog',reading_list='activity',book_stats='reading_list',clippings='kosync',calendar='activity',day='calendar',awards='activity',award='awards',search='catalog',filters='catalog',provider='filters',pair='welcome',pair_expired='welcome',expired='welcome',delete='detail',book_actions='detail',download_ready='detail',download_error='detail',error_details='download_error',update='about',update_ready='about'}
  if view=='detail' or view=='download_ready' then go(return_view);return end
  if parent[view]=='catalog' then library() elseif parent[view]=='sleep' then enter_sleep() else go(parent[view] or 'catalog') end
end
-- Where to connect Yandex Books, WB Books and LitRes: a QR code and link to ybx.app.
function F.open_stores(from)
  ui.stores_back=from;F.drop_stores_qr()
  local ok,qr=pcall(function() return c.qr:encode(STORES_URL) end)
  ui.stores_qr=ok and qr or nil
  message='';go('stores')
end
-- Update channel: the site serves /xtapp/latest.json and the package; the host
-- has no install API and cannot open .xtapp, so the app only prepares the file.
function F.update_newer(current,candidate)
  local cm,cn,cp,bm,bn,bp
  if type(candidate)=='string' then cm,cn,cp=candidate:match('^(%d+)%.(%d+)%.(%d+)$') end
  if type(current)=='string' then bm,bn,bp=current:match('^(%d+)%.(%d+)%.(%d+)$') end
  if not cm or not bm then return false end
  cm,cn,cp,bm,bn,bp=tonumber(cm),tonumber(cn),tonumber(cp),tonumber(bm),tonumber(bn),tonumber(bp)
  if cm~=bm then return cm>bm end
  if cn~=bn then return cn>bn end
  return cp>bp
end
function F.update_manifest(doc)
  if type(doc)~='table' or doc.app~='ybx-xtapp' then return nil end
  local v=doc.version
  if type(v)~='string' or not v:match('^%d+%.%d+%.%d+$') or not F.update_newer(VERSION,v) then return nil end
  if doc.url~='/xtapp/YBX-'..v..'.xtapp' then return nil end
  local size=tonumber(doc.size)
  if not size or size%1~=0 or size<1 or size>2097152 then return nil end
  if type(doc.sha256)~='string' or not doc.sha256:match('^[0-9a-f]+$') or #doc.sha256~=64 then return nil end
  return {version=v,url=doc.url,size=size,notes=type(doc.notes)=='string' and doc.notes or ''}
end
-- Raw host request outside /api/v1 (the update catalog lives at /xtapp/).
function F.update_fetch(path,on_data,done)
  local base=api_host()
  local function send(host,hops)
    local url=host..path
    local ok,handle=pcall(function()
      return c.net:request({url=url,method='GET',timeout_ms=20000,
        on_data=on_data and function(_,chunk) on_data(_,chunk) end},function(_,resp)
        local status=type(resp)=='table' and tonumber(resp.status) or 0
        if status<=0 and hops<#F.auto_order-1 and server_mode()=='auto' then
          send(F.next_host(host),hops+1);return
        end
        if status>0 then note_host(host_of(url)) end
        done(resp,status)
      end)
    end)
    if not ok then done(nil,0) end
  end
  send(base,0)
end
function F.update_snooze(m)
  c.state.update_skip_version=m.version
  c.state.update_skip_until=epoch()+86400
  c:save_state()
end
function F.update_prompt(m)
  c.state.update_available=m;c:save_state()
  if type(c.dialog)=='table' and c.dialog.confirm then
    c.dialog:confirm({title=T('update_available',m.version),text=T('update_available_body',m.version,math.floor((m.size+512)//1024))},function(_,yes)
      if yes then go('update') else F.update_snooze(m) end
    end)
    return
  end
  go('update')
end
function F.update_check(manual)
  if ui.update_check_at and now()-ui.update_check_at<30000 then return end
  ui.update_check_at=now()
  if manual then say('update_checking') end
  F.update_fetch('/xtapp/latest.json?v='..VERSION,nil,function(resp,status)
    ui.update_check_at=nil
    if status~=200 then if manual then say('update_check_failed') end;return end
    local ok,doc=pcall(function() return c.json:decode(type(resp)=='table' and resp.body or '') end)
    local m=ok and F.update_manifest(doc) or nil
    local stamp=epoch()
    if stamp>0 then c.state.update_checked_at=stamp end
    if not m then c.state.update_available=nil;c:save_state();if manual then say('update_none') end;return end
    if not manual and c.state.update_skip_version==m.version and stamp>0
        and stamp<(tonumber(c.state.update_skip_until) or 0) then return end
    F.update_prompt(m)
  end)
end
function F.update_auto()
  if token=='' or download_file then return end
  local stamp=epoch()
  if stamp<=0 then return end
  local checked=tonumber(c.state.update_checked_at) or 0
  if checked>0 and stamp-checked<86400 then return end
  F.update_check(false)
end
function F.update_download(m)
  if ui.update_downloading or download_file or busy then return end
  local storage,append=append_service()
  if not (storage and append) then say('update_download_failed');return end
  local name='YBX-'..m.version..'.xtapp'
  pcall(function() storage:remove(name) end)
  local created,result=pcall(function() return storage:write(name,'') end)
  if not created or not result then say('update_download_failed');return end
  ui.update_downloading={name=name,size=m.size,bytes=0,error=nil,drawn_at=now()}
  view='update';tick_rate(true);redraw('')
  F.update_fetch(m.url..'?v='..VERSION,function(_,chunk)
    local u=ui.update_downloading
    if not u or u.error or type(chunk)~='string' then return end
    if u.bytes+#chunk>m.size or u.bytes+#chunk>2097152 then u.error='size';return end
    for offset=1,#chunk,262144 do
      local piece=(offset==1 and #chunk<=262144) and chunk or chunk:sub(offset,offset+262143)
      local ok,written=pcall(append,storage,name,piece)
      if not ok or not written then u.error='write';return end
    end
    u.bytes=u.bytes+#chunk
    keep_wifi()
  end,function(_,status)
    local u=ui.update_downloading
    if not u then return end
    local size=storage:size(name)
    local head=storage:read(name,0,4)
    if status~=200 or u.error or size~=m.size or head~='XTAP' then
      pcall(function() storage:remove(name) end)
      ui.update_downloading=nil
      tick_rate(false);say('update_download_failed')
      return
    end
    ui.update_downloading=nil
    local folder=(type(c.files)=='table' and type(c.files.path)=='string' and c.files.path) or 'AppFiles/ybx'
    c.state.update_ready={version=m.version,file=name,path=folder}
    c:save_state();tick_rate(false);view='update_ready';redraw('')
  end)
end
local function header_ui(g,title,back_action,settings,refresh)
  local right=refresh and 344 or settings and 400 or 456
  if back_action then ib(g,'back',12,14,back_action,'Back');text(g,76,24,fit(title,right-76,'large'),'large')
  else text(g,24,24,fit(title,right-24,'large'),'large') end
  if refresh then ib(g,'refresh',352,14,refresh,'Refresh') end
  if settings then ib(g,'settings',408,14,function() go('settings') end,'Settings') end
end
local function action(g,y,label,fn,name,secondary)
  hit(g,24,y,432,56,fn,label)
  if not secondary then rounded(g,24,y,432,56) end
  local w=width(label,'medium');local x=math.max(40,(480-w-(name and 36 or 0))/2)
  if name then icon(g,name,x,y+16);x=x+36 end
  text(g,x,y+15,fit(label,412-(name and 36 or 0),'medium'),'medium')
end
local function row(g,y,label,fn,name,value,sub)
  hit(g,24,y,432,68,fn,label);local x=24
  if name then icon(g,name,24,y+20);x=64 end
  local vw=value and math.min(width(value),160) or 0
  text(g,x,y+(sub and 10 or 23),fit(label,(value and 412-vw or 424)-x))
  if sub then text(g,x,y+38,fit(sub,424-x)) end
  if value then rtext(g,424,y+23,fit(value,160)) end
  icon(g,'next',432,y+22,18);line(g,24,y+68,456,y+68)
end
local function nav(g,active_tab)
  line(g,0,720,480,720)
  for i,t in ipairs{{T('nav_library'),'library',library,'Library'},{T('nav_search'),'search',function() ui.tab='Search';go('search') end,'Search'},{T('nav_activity'),'activity',function() ui.tab='Activity';profile() end,'Activity'}} do
    local x=(i-1)*160
    hit(g,x+8,728,144,68,t[3],t[1]);icon(g,t[2],x+68,736)
    text(g,x+(160-width(t[1]))/2,770,t[1])
    if active_tab==t[4] then fill(g,x+60,720,40,3) end
  end
end
local function section(g,y,label) text(g,24,y,label,'medium') end
local function cover(g,item,x,y,w,h)
  g:rect(x,y,w,h);line(g,x+5,y,x+5,y+h)
  local last=tostring(item.author or ''):match('([^ ]+)$') or tostring(item.title or '?')
  local initial=short_utf8(last,1);if initial=='' then initial='Y' end
  text(g,x+(w-width(initial,'large'))/2,y+h*.26,initial,'large')
  for n=0,2 do line(g,x+14,y+h*.64+n*5,x+w-10,y+h*.64+n*5) end
end
local function book_row(g,y,item,fn)
  hit(g,24,y,432,130,fn,item.title);cover(g,item,24,y,86,126)
  paragraph(g,130,y+3,item.title or item.id,326,2,'medium')
  text(g,130,y+66,fit(item.author or '',326))
  local saved=local_book(item.id)
  icon(g,saved and 'check' or 'book',130,y+102,18)
  text(g,156,y+98,fit((scalar(item.percent) and tostring(math.floor(item.percent))..'% · ' or '')..(saved and T('shelf_device') or T('in_library')),300))
end
local function book_hero(g,small)
  if not selected then return end
  cover(g,selected,24,88,small and 86 or 142,small and 126 or 208)
  paragraph(g,small and 132 or 190,104,selected.title,small and 324 or 266,small and 3 or 4,'medium')
  paragraph(g,small and 132 or 190,small and 190 or 224,selected.author,small and 324 or 266,2)
end
-- One tap from the Library to a store's catalog, like the plugin's top-level
-- Яндекс Книги / WB Книги / ЛитРес lists. Tapping the active store goes back
-- to All books.
function F.store_buttons(g,y)
  local x=24
  for _,st in ipairs(STORES) do
    local id,label=st[1],st[2][lang_at]
    local w=math.floor(width(label))+28
    hit(g,x,y,w,44,function()
      ui.tab='Library';query='';page=1;shelf=shelf==id and 'all' or id;catalog()
    end,label)
    rounded(g,x,y,w,44,8)
    if shelf==id then rounded(g,x+1,y+1,w-2,42,7);rounded(g,x+2,y+2,w-4,40,6) end
    text(g,x+14,y+11,label)
    x=x+w+8
  end
end
local function tabs(g)
  for i,t in ipairs{{T('shelf_reading'),'reading'},{T('shelf_all'),'all'},{T('shelf_device'),'device'}} do
    local x=24+(i-1)*144
    hit(g,x,84,138,48,function()
      ui.tab='Library'
      if t[2]=='device' then downloads() else shelf=t[2];page=1;query='';catalog() end
    end,t[1]);text(g,x,92,t[1])
    if (view=='downloads' and t[2]=='device') or (view~='downloads' and shelf==t[2]) then fill(g,x,128,120,3) end
  end
  line(g,24,132,456,132)
end
local function pager(g,y,current,prev,next)
  if prev then ib(g,'back',140,y,prev,'Previous page') end
  text(g,234,y+13,tostring(current))
  if next then ib(g,'next',292,y,next,'Next page') end
end
local function empty(g,title,copy,name)
  icon(g,name or 'book',214,250,52);paragraph(g,40,330,title,400,2,'medium');paragraph(g,40,410,copy,400,4)
end
local function switch(g,y,label,on,fn,sub)
  local h=sub and 84 or 68
  hit(g,24,y,432,h,fn,label)
  if sub then text(g,24,y+12,fit(label,350,'medium'),'medium');text(g,24,y+46,fit(sub,350))
  else text(g,24,y+22,fit(label,350)) end
  pill(g,392,y+(h-34)//2,on);line(g,24,y+h,456,y+h)
end
local kb={active=false,title='',text='',callback=nil,layout='en',shift=false,digits=false,return_view='search'}
kb_open=function(title,text,callback,return_view)
  kb.active=true;kb.title=title or '';kb.text=type(text)=='string' and text or ''
  kb.callback=callback;kb.shift=false;kb.digits=false
  if not kb.chosen then kb.layout=lang=='en' and 'en' or lang=='kk' and c.state.kb_kk and 'kk' or 'ru' end
  if kb.layout=='kk' and not c.state.kb_kk then kb.layout='ru' end
  kb.return_view=return_view or 'search'
  view='keyboard';ui.focus=false;buttons={};redraw('')
end
-- Holding Delete keeps deleting: one letter on touch, then after 450 ms about
-- eight a second until the finger lifts or leaves the key. The tick goes back to
-- the download rate or the idle rate afterwards.
function F.kb_hold_stop() if kb.hold then kb.hold=nil;tick_rate(download_file~=nil) end end
function F.kb_hold_start(b) kb.hold={x=b.x,y=b.y,w=b.w,h=b.h,at=now()+450,stop=now()+20000};tick_rate(true) end
local function kb_close()
  kb.active=false;kb.callback=nil
  go(kb.return_view=='search' and 'search' or kb.return_view,'')
end
local function kb_insert(ch) kb.text=short_utf8(kb.text..ch,128);redraw('') end
local function kb_backspace()
  local n=utf8.len(kb.text)
  if n and n>0 then kb.text=kb.text:sub(1,(utf8.offset(kb.text,n) or 1)-1);redraw('') end
end
local function kb_finish()
  local text=kb.text
  local fn=kb.callback
  kb.active=false;kb.callback=nil
  if fn then fn(text) end
end
local function kb_next_layout()
  kb.chosen=true
  if kb.layout=='en' then kb.layout='ru'
  elseif kb.layout=='ru' then kb.layout=c.state.kb_kk and 'kk' or 'en'
  else kb.layout='en' end
  kb.shift=false;redraw('')
end
-- Every key is an outlined rounded cell. Letter rows: [Kazakh row], three
-- ЙЦУКЕН/QWERTY rows with Shift and Delete closing the third, then
-- [123] [globe + layout code] [space, labelled with the layout] [OK].
local KB_SYMBOLS={ {'1','2','3','4','5','6','7','8','9','0'},
  {'-','/',':',';','(',')','$','&','@'}, {'.',',','?','!','\'','"','#','%','*','+'} }
local function kb_shift_icon(g,x,y,w,h)
  local cx,cy=x+w//2,y+h//2
  if kb.shift then
    for i=0,12 do local hw=math.floor(i*11/12);fill(g,cx-hw,cy-12+i,2*hw+1,1) end
    fill(g,cx-5,cy,11,11)
  else
    local pts={{cx,cy-12},{cx-11,cy},{cx-5,cy},{cx-5,cy+10},{cx+5,cy+10},{cx+5,cy},{cx+11,cy},{cx,cy-12}}
    for i=1,#pts-1 do line(g,pts[i][1],pts[i][2],pts[i+1][1],pts[i+1][2]) end
  end
end
local function kb_delete_icon(g,x,y,w,h)
  local cx,cy=x+w//2,y+h//2
  local pts={{cx-14,cy},{cx-6,cy-10},{cx+14,cy-10},{cx+14,cy+10},{cx-6,cy+10},{cx-14,cy}}
  for i=1,#pts-1 do line(g,pts[i][1],pts[i][2],pts[i+1][1],pts[i+1][2]) end
  line(g,cx,cy-4,cx+8,cy+4);line(g,cx+8,cy-4,cx,cy+4)
end
local function kb_layout_icon(g,x,y,w,h)
  local cx,cy=x+w//2,y+h//2-9
  ring(g,cx,cy,8);ring(g,cx,cy,3.5,8);line(g,cx-8,cy,cx+8,cy)
  local code=(KB_NAMES[kb.layout] or KB_NAMES.en)[1]
  text(g,cx-width(code)/2,cy+11,code)
end
local function kb_space_icon(g,x,y,w,h)
  local name=(KB_NAMES[kb.layout] or KB_NAMES.en)[2]
  if kb.digits then name=T('kb_space') end
  text(g,x+(w-width(name))/2,y+h//2-15,fit(name,w-12))
  local cx=x+w//2;line(g,cx-24,y+h-20,cx-24,y+h-14);line(g,cx-24,y+h-14,cx+24,y+h-14);line(g,cx+24,y+h-14,cx+24,y+h-20)
end
local function kb_ok_icon(g,x,y,w,h)
  local label=T('kb_ok');local lw=width(label,'medium');local x0=x+(w-lw-24)//2;local cy=y+h//2
  for o=0,1 do line(g,x0,cy+o,x0+6,cy+7+o);line(g,x0+6,cy+7+o,x0+18,cy-8+o) end
  text(g,x0+24,cy-11,label,'medium')
end
local function kb_key(g,x,y,w,h,k)
  hit(g,x,y,w,h,k.fn,k.hit or k.label)
  rounded(g,x,y,w,h,6)
  if k.bold then rounded(g,x+1,y+1,w-2,h-2,5);rounded(g,x+2,y+2,w-4,h-4,4) end
  if k.draw then k.draw(g,x,y,w,h);return end
  local f=width(k.label,'medium')<=w-8 and 'medium' or 'small'
  local th=f=='medium' and 22 or 18
  text(g,x+(w-width(k.label,f))/2,y+(h-th)/2,fit(k.label,w-6,f),f)
end
local function kb_row(g,y,h,keys)
  local gap=6;local units=0
  for _,k in ipairs(keys) do units=units+(k.u or 1) end
  local unit=(456-(#keys-1)*gap)/units
  local x=12
  for i,k in ipairs(keys) do
    local w=i==#keys and 468-x or math.floor(unit*(k.u or 1))
    kb_key(g,x,y,w,h,k)
    x=x+w+gap
  end
end
local function kb_letters(row)
  local keys={}
  for _,ch in ipairs(row) do
    local out=kb.shift and (CASE[ch] or ch:upper()) or ch
    keys[#keys+1]={label=out,hit=ch,fn=function() kb_insert(out) end}
  end
  return keys
end
local function kb_draw(g)
  header_ui(g,kb.title,kb_close,false)
  rounded(g,20,86,440,58)
  text(g,32,104,fit(kb.text~='' and kb.text or '',400,'medium'),'medium')
  if kb.text=='' then
    local ok,active=pcall(function() return c.clock:millis() end)
    if ok and type(active)=='number' and (active//500)%2==0 then
      line(g,34,108,34,142)
    end
  else
    local w=math.min(400,width(kb.text,'medium'))
    line(g,34+w,108,34+w,142)
  end
  local gap=6;local kh=64
  local extra=not kb.digits and KB_EXTRA[kb.layout] or nil
  local rows=4+(extra and 1 or 0)
  local y=800-14-rows*kh-(rows-1)*gap-(extra and gap or 0)
  local del={label=T('kb_backspace'),hit='Del',u=1.5,fn=kb_backspace,draw=kb_delete_icon}
  if extra then
    kb_row(g,y,kh,kb_letters(extra));y=y+kh+gap
    line(g,24,y,456,y);y=y+gap
  end
  if not kb.digits then
    local letters=KB_ROWS[kb.layout] or KB_ROWS.en
    kb_row(g,y,kh,kb_letters(letters[1]));y=y+kh+gap
    kb_row(g,y,kh,kb_letters(letters[2]));y=y+kh+gap
    local row3={ {label=T('kb_shift'),hit='Shift',u=1.5,fn=function() kb.shift=not kb.shift;redraw('') end,draw=kb_shift_icon} }
    for _,k in ipairs(kb_letters(letters[3])) do row3[#row3+1]=k end
    row3[#row3+1]=del
    kb_row(g,y,kh,row3);y=y+kh+gap
  else
    for r,row in ipairs(KB_SYMBOLS) do
      local keys={}
      for _,ch in ipairs(row) do keys[#keys+1]={label=ch,fn=function() kb_insert(ch) end} end
      if r==#KB_SYMBOLS then keys[#keys+1]=del end
      kb_row(g,y,kh,keys);y=y+kh+gap
    end
  end
  local code=(KB_NAMES[kb.layout] or KB_NAMES.en)[1]
  kb_row(g,y,kh,{
    {label=kb.digits and T('kb_abc') or T('kb_more'),u=1.5,fn=function() kb.digits=not kb.digits;redraw('') end},
    {label=code,u=1.5,fn=kb_next_layout,draw=kb_layout_icon},
    {label=T('kb_space'),hit='Space',u=5,fn=function() kb_insert(' ') end,draw=kb_space_icon},
    {label=T('kb_ok'),hit='OK',u=2.5,bold=true,fn=kb_finish,draw=kb_ok_icon},
  })
end
local function has(name) return type(rawget(c,name))=='function' end
local function read_config(name)
  local ok,s=pcall(function() return c.storage:read(name) end);return ok and type(s)=='string' and #s>0
end
local function select_sleep(enable)
  if enable then
    local card=SleepCard.current(c.storage,c.json)
    if not card then say('sleep_need_card');return end
    if has('crosspoint_sleep_image') then
      local ok,r=pcall(c.crosspoint_sleep_image,card.bytes);if ok and r then ui.sleep_selected=true;say('sleep_selected_cp') else say('sleep_select_failed') end
    else
      local ok,r=pcall(function() return c.lockscreen:set_default() end);say(ok and r~=false and 'sleep_confirm_stock' or 'sleep_select_failed')
    end
  else
    if has('crosspoint_sleep_image') then
      if has('crosspoint_sleep_refresh') then local ok,r=pcall(c.crosspoint_sleep_refresh,nil);if not ok or not r then say('sleep_setting_failed');return end end
      local ok,r=pcall(c.crosspoint_sleep_image,nil);if ok and r then ui.sleep_selected=false;say('sleep_restored') else say('sleep_restore_failed') end
    else
      local ok,r=pcall(function() return c.storage:write('ybx-stock-sleep.json','') end);if not ok or not r then say('sleep_setting_failed');return end
      local ok,ours=pcall(function() return c.lockscreen:is_default() end)
      if not ok or not ours then say('sleep_not_ours');return end
      local ok,r=pcall(function() return c.lockscreen:clear_default() end);say(ok and r~=false and 'sleep_restore_requested' or 'sleep_restore_failed')
    end
  end
end
local function sleep_refresh(enable)
  if enable and token=='' then say('connect_first');return end
  if has('crosspoint_sleep_refresh') then
    local config
    if enable then
      local card=SleepCard.current(c.storage,c.json);if not card then say('sleep_need_card');return end
      local ok,r=pcall(c.crosspoint_sleep_image,card.bytes);if not ok or not r then say('sleep_select_failed');return end
      ui.sleep_selected=true
      config=c.json:encode({url=fixed_host()..API_PATH..'/sleep-image?w=480&h=800&v='..VERSION,method='GET',stream=true,headers={Authorization='Bearer '..token}})
    end
    local ok,r=pcall(c.crosspoint_sleep_refresh,config);say(ok and r and 'sleep_setting_saved' or 'sleep_setting_failed')
  else
    if enable and not SleepCard.current(c.storage,c.json) then say('sleep_need_card');return end
    local ok,r=pcall(function() return c.storage:write('ybx-stock-sleep.json',enable and c.json:encode({token=token,host=fixed_host()}) or '') end)
    say(ok and r and 'sleep_setting_saved' or 'sleep_setting_failed')
  end
end
local function reading_sync(enable)
  local config
  if enable then
    if token=='' then say('connect_first');return end
    local mapping={}
    for _,name in ipairs({'reader.open','reader.exit','reader.session'}) do mapping[name]={event='event',event_id='event_id',ts='ts',book_id='@book'} end
    mapping['reader.exit'].percent='percent'
    for _,name in ipairs({'doc','start','duration','progress_bp'}) do mapping['reader.session'][name]=name end
    config=c.json:encode({owner=c.state.event_owner,url=fixed_host()..API_PATH..'/events?v='..VERSION,headers={Authorization='Bearer '..token},events=mapping})
  end
  local ok,r=pcall(c.crosspoint_reader_upload,config);say(ok and r and 'sync_saved' or 'sync_save_failed')
end
local function cancel()
  local downloading=download_file~=nil
  request_id=request_id+1;if active then pcall(function() active:cancel() end) end
  active=nil;busy=false;clear_partial();if downloading then go('detail',T('download_cancelled')) else say('cancelled') end
end

-- Idle prefetch: one quiet request at a time, only on browsing screens and
-- after 3 s without input, so it never competes with what the reader is doing.
-- Everything the main tabs need is refreshed once per session; the next page of
-- the shelf on screen is fetched ahead.
local prefetch_tries={}
local PREFETCH_VIEWS={reading_list=true,catalog=true,downloads=true,activity=true,search=true,settings=true,awards=true,calendar=true}
local function prefetch()
  if busy or bg.handle or token=='' or download_file or pairing or not PREFETCH_VIEWS[view] then return end
  if now()-(ui.last_input or 0)<3000 then return end
  local jobs={}
  local function page_job(sh,pg)
    local key=page_key(sh,pg)
    if not fresh[key] then jobs[#jobs+1]={key,function() return revalidate_page(sh,pg) end} end
  end
  page_job('reading',1);page_job('all',1)
  if view=='catalog' and query=='' and #items==3 then page_job(shelf,page+1) end
  if not fresh.profile then jobs[#jobs+1]={'profile',function() return quiet('/reading/summary?limit=6',F.store_profile) end} end
  if not fresh.awards then jobs[#jobs+1]={'awards',function() return quiet('/achievements?limit=20',F.store_awards) end} end
  local today=cache.profile and cache.profile.today
  if not fresh.days and type(today)=='string' and today:match('^%d%d%d%d%-%d%d%-%d%d$') then
    local month=today:sub(1,7)
    jobs[#jobs+1]={'days',function() return quiet('/reading/calendar?month='..month,function(d) F.store_days(month,d.days) end) end}
  end
  for _,st in ipairs(STORES) do page_job(st[1],1) end
  for _,job in ipairs(jobs) do
    local tries=prefetch_tries[job[1]] or 0
    if tries<2 then prefetch_tries[job[1]]=tries+1;if job[2]() then return end end
  end
end
function on_load(ctx)
  c=ctx
  message='';auto_reader_sync=false
  lang_at=2 -- Russian until the reader picks another language
  if type(c.state.lang)=='string' then
    for i,l in ipairs(LANGS) do if l[1]==c.state.lang then lang_at=i end end
  end
  lang=LANGS[lang_at][1]
  local okf,files_service=pcall(function() return c.files end)
  if not okf or type(files_service)~='table' then files_service=nil end
  book_store=files_service or c.storage
  book_save=files_service and 'files' or 'storage'
  token=type(c.state.token)=='string' and #c.state.token<=4096 and c.state.token or ''
  local books={}
  for i,book in ipairs(type(c.state.downloads)=='table' and c.state.downloads or {}) do
    if i>32 then break end
    if type(book)=='table' and type(book.id)=='string' and #book.id<=256 and NAMES.valid(book.file) then
      books[#books+1]={id=book.id,file=book.file,title=short_utf8(book.title,64),author=short_utf8(book.author,64)}
    end
  end
  c.state.downloads=books
  if type(c.state.event_owner)~='string' or #c.state.event_owner~=32 then c.state.event_owner=event_id();c:save_state() end
  local stored={}
  local ok,value=pcall(function()
    local raw=c.storage:read('ybx-events.json')
    return type(raw)=='string' and #raw<=8192 and c.json:decode(raw) or nil
  end)
  if ok and type(value)=='table' and value.owner==c.state.event_owner and type(value.events)=='table' then stored=value.events end
  events={}
  local repaired=false
  for i,event in ipairs(stored) do
    if i>16 then break end
    local ts=type(event)=='table' and math.tointeger(event.ts)
    if type(event)=='table' and event.event=='book.downloaded' and ts and ts>=0 and ts<=4102444800 then
      -- Queues written before 0.8.4 hold ids the server always rejected; re-mint once.
      local id=valid_wire_event_id(event.event_id) and event.event_id or wire_event_id()
      if id~=event.event_id then repaired=true end
      events[#events+1]={event=event.event,event_id=id,ts=ts}
    end
  end
  events=token~='' and events or {}
  if repaired and token~='' then persist_events() end
  local next_file=math.tointeger(c.state.next_file or 1)
  c.state.next_file=next_file and next_file>=1 and next_file<1000000000 and next_file or 1
  if NAMES.valid(c.state.pending) then local done=false;for _,b in ipairs(c.state.downloads) do if b.file==c.state.pending then done=true end end;if not done then download_file=c.state.pending;clear_partial() else c.state.pending=nil end else c.state.pending=nil end
  if reader_supported() then
    if not c.state.reader_files then
      local ok,ready=pcall(function()
        local queue=c.storage:read('reader-events.jsonl')
        local mapping=c.storage:read('reader-books.json')
        if type(queue)=='string' or type(mapping)=='string' then
          -- A state-save interruption must not reset an existing queue.
          return type(queue)=='string' and #queue<=10240 and type(mapping)=='string' and #mapping<=32768
        end
        return c.storage:write('reader-events.jsonl','') and
          c.storage:write('reader-books.json',c.json:encode({owner=c.state.event_owner,books={}}))
      end)
      if ok and ready then c.state.reader_files=true;c:save_state() end
    end
    if c.state.reader_files then
      pcall(function() c.storage:write('reader-owner.txt',token~='' and c.state.event_owner or '') end)
      auto_reader_sync=token~=''
    end
  end
  c:set_tick(1000)
  view=token=='' and 'welcome' or 'catalog';ui.focus=false;ui.loaded=false;ui.auto_library=token~='';ui.library_cache=nil;items={};ui.data={};ui.credentials=nil
  bg={id=0};prefetch_tries={};ui.last_input=now() or 0
  if token~='' then cache_load() else cache={pages={},order={}};fresh={} end
  -- Open straight onto the cached Reading shelf; on_tick then refreshes it quietly.
  shelf='reading';page=1;query=''
  if token~='' and cache.pages[page_key('reading',1)] then items=cache.pages[page_key('reading',1)];ui.loaded=true end
  redraw('')
end
local function value(v) if type(v)=='table' then v=v.value end;return type(v)=='number' and v==v and math.abs(v)<1e12 and v or nil end
local function display(v,suffix) local n=value(v);return n and (math.floor(n)==n and tostring(math.floor(n)) or tostring(math.floor(n*10)/10))..(suffix or '') or '—' end
enter_sleep=function()
  if ui.sleep_picture then pcall(function() ui.sleep_picture:release() end);ui.sleep_picture=nil end
  ui.sleep_runs=nil
  local card=SleepCard.current(c.storage,c.json)
  if card then
    local ok,picture=pcall(function() return c.image:decode(card.bytes,{max_w=168,max_h=244}) end)
    if ok and picture then ui.sleep_picture=picture else
      local bytes=card.bytes;local top=bytes:byte(26)>=128;local black_zero=bytes:byte(55)==0
      local runs={}
      for row=0,47 do
        local start=nil;local py=math.min(799,math.floor((row+.5)*800/48));if not top then py=799-py end
        for col=0,32 do
          local ink=false
          if col<32 then local px=math.min(479,math.floor((col+.5)*480/32));local bit=(bytes:byte(63+py*60+px//8)>>(7-px%8))&1;ink=black_zero and bit==0 or not black_zero and bit==1 end
          if ink and not start then start=col end
          if not ink and start then runs[#runs+1]=(row<<10)|(start<<5)|(col-start-1);start=nil end
        end
      end
      ui.sleep_runs=runs -- At most 16 black runs per row, 768 runs total.
    end
  end
  go('sleep')
end
function on_draw(_,g)
  if view~=drawn_view then selected_index=1;drawn_view=view end
  buttons={};g:clear()
  if busy then
    header_ui(g,download_file and T('busy_download') or T('busy_title'))
    if download_file then
      book_hero(g,true);section(g,300,T('saving_book'))
      text(g,24,352,T('received_kib',download_bytes//1024))
      paragraph(g,24,412,T('keep_open'),432,3)
    else empty(g,T('busy_body'),T('busy_hint'),'wifi') end
    action(g,700,T('cancel'),cancel,'close');return
  end
  if message~='' and view~='pair' and view~='download_ready' and view~='storage' and view~='download_error' and view~='error_details' then
    header_ui(g,'YBX',function() message='';redraw() end)
    empty(g,ui.message_ok and T('msg_ok') or T('msg_check'),message,ui.message_ok and 'check' or 'info')
    if ui.message_key=='err_source' then action(g,548,T('stores_how'),function() F.open_stores(view=='stores' and 'catalog' or view) end,'info') end
    if view=='catalog' and not ui.message_ok then action(g,624,T('try_again'),function() message='';catalog(true) end,'refresh') end
    action(g,700,T('back'),function() message='';redraw() end,'back',true);return
  end
  if view=='home' then view=token=='' and 'welcome' or 'catalog' end
  if view=='welcome' then
    header_ui(g,'YBX');empty(g,T('welcome_title'),T('welcome_body'),'library')
    action(g,624,T('connect'),pair,'user');action(g,700,T('open_downloads'),downloads,'book',true)
  elseif view=='paired' then
    header_ui(g,T('connected'));empty(g,T('paired_body'),T('welcome_body'),'check');action(g,700,T('open_library'),catalog,'library')
  elseif view=='pair' then
    header_ui(g,T('pair_title'),welcome)
    text(g,24,100,T('pair_on_phone'));section(g,140,'my.ybx.app/pair')
    if pair_qr then g:image(pair_qr,148,212,{w=184,h=184}) end
    text(g,24,438,T('pair_enter_code'));text(g,24,480,pairing and fit(pairing.user,432,'large') or T('pair_code_expired'),'large')
    paragraph(g,24,558,message~='' and message or T('pair_approve'),432,3)
    action(g,700,T('pair_check'),poll,'check')
  elseif view=='pair_expired' or view=='expired' then
    header_ui(g,T('pair_title'),welcome);empty(g,view=='expired' and T('session_title') or T('pair_expired_title'),view=='expired' and T('session_body') or T('pair_expired_body'),'user')
    action(g,624,T('pair_new_code'),pair,'refresh');action(g,700,T('open_downloads'),downloads,'book',true)
  elseif view=='catalog' or view=='downloads' then
    local local_view=view=='downloads';local list=local_view and (c.state.downloads or {}) or items
    header_ui(g,ui.tab=='Search' and not local_view and T('nav_search') or 'YBX',nil,true,not local_view and ui.tab~='Search' and function() catalog(true) end or nil)
    if ui.tab=='Search' and not local_view then
      hit(g,24,88,432,56,search,T('search_query'));rounded(g,24,88,432,56);icon(g,'search',40,104);text(g,80,104,fit(query,350))
    else tabs(g) end
    if not local_view and ui.tab~='Search' then
      F.store_buttons(g,146)
      hit(g,300,146,44,44,function() F.open_stores('catalog') end,T('stores_title'));rounded(g,300,146,44,44,8);icon(g,'info',310,156)
      hit(g,352,144,104,48,function() local store=PROVIDERS[shelf] and shelf;ui.filter_shelf=store and 'all' or shelf;ui.provider=store or '';go('filters') end,T('filter'));icon(g,'settings',352,158);text(g,388,158,T('filter'))
    else text(g,24,162,local_view and T('offline_sub') or T('search_results')) end
    local start=local_view and ((ui.local_page-1)*3+1) or 1
    if #list==0 then empty(g,local_view and T('empty_offline') or ui.tab=='Search' and T('no_match') or T('no_books'),local_view and T('empty_offline_cta') or ui.tab=='Search' and T('no_match_body') or T('try_other'),'book') end
    for i=start,math.min(start+2,#list) do
      local item=list[i];book_row(g,210+(i-start)*150,item,function() selected=item;return_view=view;go('detail') end)
    end
    local current=local_view and ui.local_page or page
    pager(g,660,current,current>1 and function() if local_view then ui.local_page=ui.local_page-1;redraw() else page=page-1;catalog() end end or nil,
      (local_view and start+2<#list or not local_view and #items==3) and function() if local_view then ui.local_page=ui.local_page+1;redraw() else page=page+1;catalog() end end or nil)
    nav(g,local_view and 'Library' or ui.tab)
  elseif view=='search' then
    header_ui(g,T('nav_search'));rounded(g,24,88,432,56);hit(g,24,88,432,56,search,T('search_query'));icon(g,'search',40,104);text(g,80,104,fit(query~='' and query or T('search_query'),350))
    empty(g,T('find_book'),T('find_book_body'),'search');nav(g,'Search')
  elseif view=='filters' then
    header_ui(g,T('catalog_title'),back);section(g,92,T('shelf_label'))
    for i,t in ipairs{{T('shelf_all'),'all'},{T('shelf_reading'),'reading'},{T('shelf_want'),'to_read'},{T('shelf_finished'),'done'},{T('shelf_uploaded'),'uploaded'}} do
      local y=136+(i-1)*66;hit(g,24,y,432,62,function() ui.filter_shelf=t[2];redraw() end,t[1]);text(g,24,y+20,t[1]);if ui.filter_shelf==t[2] then icon(g,'check',428,y+20) end;line(g,24,y+62,456,y+62)
    end
    section(g,500,T('provider'));row(g,540,F.provider_name(ui.provider) or T('all_providers'),function() go('provider') end)
    action(g,700,T('apply_filters'),function() shelf=ui.provider~='' and ui.provider or ui.filter_shelf or 'all';query='';page=1;ui.tab='Library';catalog() end,'check')
  elseif view=='provider' then
    header_ui(g,T('provider'),back)
    for i,t in ipairs{{T('all_providers'),''},{F.provider_name('yandex'),'yandex'},{F.provider_name('wb'),'wb'},{F.provider_name('litres'),'litres'}} do row(g,110+(i-1)*76,t[1],function() ui.provider=t[2];go('filters') end,nil,ui.provider==t[2] and T('selected') or nil) end
  elseif view=='detail' then
    header_ui(g,'',back)
    local saved=selected and local_book(selected.id)
    if saved then ib(g,'more',408,14,function() go('book_actions') end,T('book_actions')) end
    book_hero(g,false);icon(g,saved and 'check' or 'download',24,328,20);text(g,56,325,saved and T('offline_yes') or T('offline_no'))
    if selected and selected.description and selected.description~='' then line(g,24,374,456,374);section(g,398,T('about_book'));paragraph(g,24,444,selected.description,432,5)
    else paragraph(g,24,410,T('no_description'),432,2) end
    if selected and scalar(selected.percent) then text(g,24,616,T('reading_progress'));text(g,368,616,display(selected.percent,'%'));line(g,24,664,456,664);fill(g,24,660,math.max(1,math.floor(432*selected.percent/100)),5) end
    action(g,700,saved and T('read_now') or T('download'),saved and open_book or download,saved and 'book' or 'download')
  elseif view=='book_actions' then
    header_ui(g,T('book_actions'),back);book_hero(g,true)
    row(g,300,T('remove_download'),function() go('delete') end,'trash')
  elseif view=='download_ready' then
    header_ui(g,T('downloaded'),back);book_hero(g,false);icon(g,'check',24,350);section(g,350,'    '..T('ready'))
    paragraph(g,24,400,T('ready_body'),432,3)
    if message~='' then paragraph(g,24,510,message,432,3) end
    action(g,624,T('read_now'),open_book,'book');action(g,700,T('back_to_library'),function() go(return_view) end,'back',true)
  elseif view=='download_error' then
    header_ui(g,T('download'),back);book_hero(g,true)
    icon(g,'warning',24,282);section(g,282,'    '..T('failed_title'))
    paragraph(g,24,334,T('failed_body'),432,3)
    row(g,458,T('technical'),function() go('error_details') end,'info')
    action(g,624,T('try_again'),download,'refresh');action(g,700,T('check_storage'),function() ui.notice='';go('storage') end,'storage',true)
  elseif view=='error_details' then
    header_ui(g,T('details_title'),back);paragraph(g,24,122,ui.download_error or T('unavailable'),432,14)
  elseif view=='delete' then
    header_ui(g,T('remove_download'),back);book_hero(g,true)
    section(g,320,T('remove_q'));paragraph(g,24,374,T('remove_body'),432,4)
    action(g,624,T('remove_download'),function() delete_book();view='detail' end,'trash');action(g,700,T('keep_book'),function() go('detail') end,'book',true)
  elseif view=='activity' then
    header_ui(g,T('nav_activity'),nil,true);local p=ui.data.profile
    local available=p and (p.today_minutes or p.current_streak_days or p.week_minutes or p.books_year or #p.week_days>0)
    local y=444
    if not available then empty(g,T('activity_unavailable'),T('activity_try_later'),'activity');y=486 else
      text(g,24,96,T('activity_today'));rtext(g,456,96,fit(F.day_name(p.today),260))
      -- three metrics: today, streak, books finished this year
      for i,m in ipairs{{display(p.today_minutes,T('min')),T('activity_time')},{display(p.current_streak_days),T('activity_streak')},{display(p.books_year),T('activity_books_year',(p.today or ''):sub(1,4))}} do
        local x=24+(i-1)*148
        text(g,x,126,fit(m[1],136,'large'),'large');text(g,x,164,fit(m[2],140))
      end
      line(g,24,198,456,198)
      section(g,212,T('activity_week'));rtext(g,456,216,fit(display(p.week_minutes,T('min')),156))
      local max=1;for _,d in ipairs(p.week_days or {}) do max=math.max(max,value(d.minutes) or 0) end
      for i=1,7 do local d=p.week_days[i];local n=d and value(d.minutes);local x=24+(i-1)*62
        if n and d.observed~=false then local h=math.floor(math.max(0,n)/max*72);if h>0 then fill(g,x,326-h,42,h) end;line(g,x,328,x+42,328)
        else text(g,x+16,304,'-') end
        local label=d and d.date:sub(9,10) or '-';text(g,x+(42-width(label))/2,334,label)
      end
      if type(p.year_goal)=='table' then
        text(g,24,370,T('activity_goal'));rtext(g,456,370,fit(display(p.year_goal.finished)..' / '..display(p.year_goal.goal),166))
        local goal=value(p.year_goal.goal);local done=value(p.year_goal.finished)
        if goal and goal>0 and done then line(g,24,402,456,402);fill(g,24,398,math.max(1,math.floor(432*math.max(0,math.min(1,done/goal)))),5) end
        local delta=p.year_goal.delta
        if delta then text(g,24,410,fit(delta>0 and T('goal_ahead',F.books_count(delta)) or delta<0 and T('goal_behind',F.books_count(-delta)) or T('goal_on_track'),432)) end
      end
    end
    local reading=p and p.reading or {}
    row(g,y,T('continue_reading'),function() go('reading_list') end,'book',#reading>0 and tostring(#reading) or nil)
    row(g,y+68,T('activity_calendar'),calendar,'calendar');row(g,y+136,T('activity_awards'),achievements,'award')
    nav(g,'Activity')
  elseif view=='reading_list' then
    header_ui(g,T('continue_reading'),back);local list=ui.data.profile and ui.data.profile.reading or {}
    if #list==0 then empty(g,T('continue_none'),T('continue_none_body'),'book') end
    for i,book in ipairs(list) do
      local y=96+(i-1)*150
      book_row(g,y,book,function() book_stats(book) end)
    end
  elseif view=='book_stats' then
    header_ui(g,T('book_stats_title'),back);local b=ui.stats_book or {};local d=ui.book_detail or {}
    selected=b;book_hero(g,true)
    local rows={{T('reading_progress'),d.percent and display(d.percent,'%') or '—'},{T('active_time'),F.duration(d.minutes)},
      {T('sessions'),d.sessions and display(d.sessions) or '—'}}
    if F.iso_date(d.started) then rows[#rows+1]={T('started'),F.day_name(F.iso_date(d.started))} end
    if F.iso_date(d.finished) then rows[#rows+1]={T('finished'),F.day_name(F.iso_date(d.finished))} end
    for i,r in ipairs(rows) do
      local y=248+(i-1)*52
      text(g,24,y,fit(r[1],200));rtext(g,456,y,fit(r[2],240));line(g,24,y+38,456,y+38)
    end
    if #(d.sources or {})>0 then
      local names={};for _,src in ipairs(d.sources) do names[#names+1]=F.source_name(src) end
      paragraph(g,24,248+#rows*52+10,T('data_sources')..table.concat(names,' · '),432,2)
    end
    action(g,700,T('open_book'),function() selected={id=b.id,title=b.title,author=b.author,percent=d.percent or b.percent};return_view='book_stats';go('detail') end,'book')
  elseif view=='calendar' then
    header_ui(g,T('activity_calendar'),back);section(g,100,F.month_name(ui.month))
    local year,month=(ui.month or ''):match('^(%d%d%d%d)%-(%d%d)$');year=tonumber(year);month=tonumber(month)
    if year and month and month>=1 and month<=12 then
      local months={31,28,31,30,31,30,31,31,30,31,30,31};if year%4==0 and (year%100~=0 or year%400==0) then months[2]=29 end
      local y=month<3 and year-1 or year;local offsets={0,3,2,5,0,3,5,1,4,6,2,4};local first=(y+y//4-y//100+y//400+offsets[month]+1+6)%7
      for i,t in ipairs(WEEKDAYS[lang_at]) do text(g,24+(i-1)*61+(52-width(t))/2,156,t) end
      for d=1,months[month] do
        local cell=first+d-1;local x=24+(cell%7)*61;local yy=198+(cell//7)*54;local date=string.format('%04d-%02d-%02d',year,month,d)
        hit(g,x,yy,52,48,function() ui.day=date;go('day') end,tostring(d));text(g,x+(52-width(tostring(d)))/2,yy+8,tostring(d))
        if ui.data.days[date] and value(ui.data.days[date].minutes) then fill(g,x+23,yy+40,4,4) end
      end
      text(g,24,574,fit(T('calendar_hint'),432));section(g,622,ui.day and fit(F.day_name(ui.day),432,'medium') or T('select_day'))
      action(g,700,T('view_day'),function() go('day') end,'calendar')
    else empty(g,T('calendar_unavailable'),T('calendar_retry'),'calendar') end
  elseif view=='day' then
    header_ui(g,T('calendar_title'),back);section(g,110,fit(F.day_name(ui.day),432,'medium'))
    local d=ui.data.days and ui.data.days[ui.day];text(g,24,184,display(d and d.minutes,T('min')),'large');text(g,24,238,T('recorded'))
    paragraph(g,24,330,T('day_note'),432,4)
  elseif view=='awards' then
    header_ui(g,T('activity_awards'),back);local list=ui.data.awards or {};local start=(ui.award_page-1)*3+1
    if #list==0 then empty(g,T('awards_none'),T('awards_hint'),'award') end
    for i=start,math.min(start+2,#list) do local a=list[i];local y=120+(i-start)*162
      hit(g,24,y,432,146,function() ui.award=a;go('award') end,a.title);icon(g,'award',24,y+18,40);paragraph(g,84,y+6,a.title,372,2,'medium');text(g,84,y+74,a.earned and T('earned') or a.progress and display(a.progress*100,'%') or T('upcoming'));line(g,24,y+146,456,y+146)
    end
    pager(g,680,ui.award_page,ui.award_page>1 and function() ui.award_page=ui.award_page-1;redraw() end or nil,start+2<#list and function() ui.award_page=ui.award_page+1;redraw() end or nil)
  elseif view=='award' then
    header_ui(g,T('award_title'),back);local a=ui.award or {};icon(g,'award',208,154,64);paragraph(g,24,260,a.title or '',432,3,'large');paragraph(g,24,388,a.description or '',432,7);text(g,24,622,a.earned and T('earned') or T('upcoming'))
  elseif view=='settings' then
    header_ui(g,T('settings'),library)
    for i,t in ipairs{{T('settings_account'),'account','user'},{T('settings_sleep'),'sleep','moon'},{T('settings_reading'),'reader_sleep','refresh'},{T('settings_kosync'),'kosync','book'},{T('settings_help'),'support','info'}} do
      row(g,100+(i-1)*66,t[1],function() if t[2]=='sleep' then enter_sleep() elseif t[2]=='kosync' then ui.reveal=false;go('kosync') else go(t[2]) end end,t[3])
    end
    row(g,430,T('settings_language'),function()
      lang_at=lang_at%#LANGS+1;lang=LANGS[lang_at][1];c.state.lang=lang;c:save_state();redraw('')
    end,nil,LANGS[lang_at][2])
    text(g,24,512,T('settings_keyboard'))
    switch(g,536,T('settings_kb_kk'),c.state.kb_kk==true,function()
      c.state.kb_kk=not c.state.kb_kk;c:save_state()
      if not c.state.kb_kk and kb.layout=='kk' then kb.layout='ru' end
      redraw('')
    end,T('settings_kb_kk_sub'))
    text(g,24,640,has('crosspoint_reader_upload') and T('settings_reader_cp') or T('settings_reader_stock'))
    action(g,700,T('close_app'),function() c:quit() end,'close',true)
  elseif view=='account' then
    header_ui(g,T('settings_account'),back);icon(g,'user',24,110,40);section(g,166,token=='' and T('account_not_connected') or T('account_connected'))
    paragraph(g,24,224,T('account_manage'),432,3)
    if token=='' then action(g,700,T('connect'),pair,'user') else row(g,358,T('account_signout'),function() go('forget') end,'user');row(g,434,T('account_disconnect'),function() go('disconnect') end,'close');paragraph(g,24,548,T('account_books_stay'),432,2) end
  elseif view=='disconnect' or view=='forget' then
    local revoke_access=view=='disconnect';header_ui(g,T('settings_account'),back)
    empty(g,revoke_access and T('disconnect_q') or T('signout_q'),revoke_access and T('disconnect_body') or T('signout_body'),'user')
    action(g,624,revoke_access and T('disconnect') or T('signout'),revoke_access and revoke or function() if save_token('') then ui.credentials=nil;ui.data={};welcome() end end,'close');action(g,700,T('cancel'),function() go('account') end,nil,true)
  elseif view=='sleep' then
    header_ui(g,T('settings_sleep'),back)
    if ui.sleep_picture then g:image(ui.sleep_picture,156,92,{w=168,h=244})
    elseif ui.sleep_runs then
      for _,r in ipairs(ui.sleep_runs) do local col=(r>>5)&31;local row=r>>10;local count=(r&31)+1;local x=math.floor(col*168/32);local y=math.floor(row*244/48);fill(g,156+x,92+y,math.floor((col+count)*168/32)-x,math.floor((row+1)*244/48)-y) end
    else g:rect(156,92,168,244);icon(g,'moon',212,160,48);paragraph(g,170,244,T('sleep_preview'),140,3) end
    local known=ui.sleep_selected
    if not has('crosspoint_sleep_image') then local ok,r=pcall(function() return c.lockscreen:is_default() end);if ok then known=r==true end end
    if known~=nil then switch(g,370,T('sleep_use'),known,function() select_sleep(not known) end)
    else row(g,370,T('sleep_use'),function() select_sleep(true) end,'moon') end
    row(g,446,T('sleep_refresh_card'),function() refresh_sleep_card();ui.reload_sleep=true end,'refresh');row(g,522,T('sleep_refresh_opts'),function() go('sleep_options') end,'settings')
    paragraph(g,24,620,has('crosspoint_sleep_image') and T('sleep_hint_cp') or T('sleep_hint_stock'),432,4)
  elseif view=='sleep_options' then
    header_ui(g,T('sleep_refresh_opts'),back)
    local enabled=read_config(has('crosspoint_sleep_refresh') and 'sleep-request.json' or 'ybx-stock-sleep.json')
    switch(g,110,T('sleep_before'),enabled,function() sleep_refresh(not enabled) end)
    paragraph(g,24,214,has('crosspoint_sleep_refresh') and T('sleep_opts_cp') or T('sleep_opts_stock'),432,8)
    row(g,518,T('sleep_restore'),function() select_sleep(false) end,'moon')
  elseif view=='reader_sleep' then
    header_ui(g,T('settings_reading'),back)
    if has('crosspoint_reader_upload') then
      paragraph(g,24,110,T('sync_intro'),432,4)
      local enabled=read_config('reader-upload.json');switch(g,236,T('sync_before_sleep'),enabled,function() reading_sync(not enabled) end)
      row(g,316,T('sync_now'),sync_reader_events,'refresh');paragraph(g,24,420,T('sync_note'),432,8)
    else paragraph(g,24,120,T('sync_stock_title'),432,2,'medium');paragraph(g,24,212,T('sync_stock_body'),432,6);row(g,450,T('sync_downloads'),sync_events,'refresh') end
  elseif view=='kosync' then
    header_ui(g,T('settings_kosync'),back);section(g,104,fit(T('kosync_hint'),432,'medium'))
    if not ui.credentials then
      paragraph(g,24,150,T('kosync_intro'),432,5)
      row(g,470,T('clippings_title'),function() ui.reveal=false;go('clippings') end,'book')
      action(g,700,T('kosync_get'),kosync,'refresh')
    else
      local sync=F.sync_hosts[server_mode()=='auto' and 'main' or server_mode()]
      text(g,24,146,T('kosync_server'));text(g,24,176,sync);text(g,24,204,'/api/v1/crosspoint/kosync')
      paragraph(g,24,236,T('kosync_https',fixed_host():sub(9)),432,2)
      text(g,24,306,T('kosync_user'));text(g,24,346,T('kosync_pass'))
      if ui.reveal then local key=ui.credentials;for i=1,#key,28 do text(g,24,380+((i-1)//28)*28,key:sub(i,i+27)) end else text(g,24,380,'************') end
      action(g,624,T('kosync_check'),F.kosync_check,'check')
      action(g,700,ui.reveal and T('kosync_hide') or T('kosync_reveal'),function() ui.reveal=not ui.reveal;redraw() end,'eye',true)
    end
  elseif view=='clippings' then
    header_ui(g,T('clippings_title'),back)
    paragraph(g,24,104,T('clippings_intro'),432,5)
    if ui.clip_key then
      text(g,24,262,T('kosync_server'));text(g,24,292,fit(ui.clip_url,432))
      text(g,24,336,T('kosync_user'));text(g,24,376,T('kosync_pass'))
      if ui.reveal then local key=ui.clip_key;for i=1,#key,28 do text(g,24,410+((i-1)//28)*28,key:sub(i,i+27)) end else text(g,24,410,'************') end
      action(g,624,ui.reveal and T('kosync_hide') or T('kosync_reveal'),function() ui.reveal=not ui.reveal;redraw() end,'eye')
      action(g,700,T('clippings_revoke'),F.clippings_revoke,'close',true)
    else
      paragraph(g,24,262,T('clippings_note'),432,4)
      action(g,624,T('clippings_get'),F.clippings_get,'refresh')
      action(g,700,T('clippings_revoke'),F.clippings_revoke,'close',true)
    end
  elseif view=='support' then
    header_ui(g,T('support_title'),back)
    row(g,100,T('stores_title'),function() F.open_stores('support') end,'library')
    row(g,168,T('check_device_storage'),function() ui.notice='';go('storage') end,'storage')
    row(g,236,T('retry_reports'),sync_events,'refresh');row(g,304,T('conn_help'),function() go('offline') end,'wifi');row(g,372,T('about_title'),function() go('about') end,'info')
    local mode=server_mode()
    row(g,440,T('server'),function()
      local next_mode=({auto='main',main='eu',eu='pt',pt='auto'})[mode];c.state.server=next_mode~='auto' and next_mode or nil;c:save_state();mirror.host=nil;mirror.keep_until=0
      ui.server_note=true;redraw('')
    end,'wifi',T('server_'..mode))
    if ui.server_note then paragraph(g,24,518,T('server_note'),432,3) end
    if ui.download_error then section(g,610,T('last_error'));paragraph(g,24,650,ui.download_error,432,5) end
  elseif view=='storage' then
    header_ui(g,T('storage_check'),back);icon(g,'storage',212,112,56)
    section(g,224,T('storage_test'));paragraph(g,24,280,T('storage_body'),432,5)
    if ui.notice~='' then paragraph(g,24,444,ui.notice,432,7) end
    action(g,700,T('run_check'),selftest,'storage')
  elseif view=='offline' then
    header_ui(g,T('conn_help'),back);empty(g,T('offline_title'),T('offline_body'),'wifi')
    action(g,624,T('open_downloads'),downloads,'book');action(g,700,T('offline_retry'),function() catalog(true) end,'refresh',true)
  elseif view=='update' then
    header_ui(g,T('update_title'),back)
    local m=c.state.update_available
    if type(m)~='table' then empty(g,T('update_none'),T('update_none_body'),'refresh')
    else
      paragraph(g,24,120,T('update_available_body',m.version,math.floor((m.size+512)//1024)),432,4)
      if ui.update_downloading then
        local done=math.floor(ui.update_downloading.bytes*100/math.max(1,m.size))
        text(g,24,360,T('update_downloading',done))
      else
        action(g,624,T('update_now'),function() F.update_download(m) end,'download')
        action(g,700,T('update_later'),function() F.update_snooze(m);go('about') end,'close',true)
      end
    end
  elseif view=='update_ready' then
    header_ui(g,T('update_ready_title'),back)
    local ready=c.state.update_ready or {}
    paragraph(g,24,120,T('update_saved',tostring(ready.path or '')..'/'..tostring(ready.file or '')),432,6)
    paragraph(g,24,320,T('update_saved_hint'),432,4)
    action(g,700,T('update_close'),function() go('about') end,'check')
  elseif view=='about' then
    header_ui(g,T('about_title'),back);empty(g,T('welcome_title'),T('about_body'),'library')
    row(g,512,T('update_check'),function() F.update_check(true) end,'refresh')
    if type(c.state.update_ready)=='table' then row(g,576,T('update_install'),function() go('update_ready') end,'download') end
    text(g,24,660,'YBX XTApp '..APP_VERSION)
  elseif view=='stores' then
    header_ui(g,T('stores_title'),back)
    paragraph(g,24,96,T('stores_body'),432,3)
    if ui.stores_qr then g:image(ui.stores_qr,140,196,{w=200,h=200}) else icon(g,'wifi',216,260,48) end
    local site=STORES_URL:sub(9);text(g,(480-width(site,'medium'))/2,408,site,'medium')
    paragraph(g,24,460,T('stores_steps'),432,4)
    action(g,700,T('stores_refresh'),function() F.drop_stores_qr();ui.tab='Library';query='';page=1;catalog(true) end,'refresh')
  elseif view=='keyboard' then
    kb_draw(g)
  else
    header_ui(g,T('nav_library'),library);empty(g,T('open_library'),T('welcome_body'),'book');nav(g,ui.tab)
  end
end
function on_input(_,event)
  ui.last_input=now()
  if view=='keyboard' and event.type=='pointer' then
    local function inside(b) return event.x and event.x>=b.x and event.x<b.x+b.w and event.y>=b.y and event.y<b.y+b.h end
    if event.phase=='down' then
      for _,b in ipairs(buttons) do if b.label=='Del' and inside(b) then kb_backspace();F.kb_hold_start(b);return end end
      return
    elseif event.phase=='move' or event.phase=='hold' then
      if kb.hold and event.x and not inside(kb.hold) then F.kb_hold_stop() end
      return
    elseif event.phase=='up' and kb.hold then F.kb_hold_stop();return end
  end
  if event.type=='pointer' and event.phase=='up' and event.gesture=='tap' then
    ui.focus=false
    for _,b in ipairs(buttons) do if event.x>=b.x and event.x<b.x+b.w and event.y>=b.y and event.y<b.y+b.h then ui.auto_library=false;b.action();return end end
  elseif view=='keyboard' and event.type=='key' and event.phase~='up' then
    if event.key=='ok' then kb_finish()
    elseif event.key=='back' then kb_close()
    elseif event.key=='up' then kb_backspace() end
  elseif event.type=='key' and event.phase~='up' then
    if event.key=='up' then ui.focus=true;selected_index=math.max(1,selected_index-1);redraw()
    elseif event.key=='down' then ui.focus=true;selected_index=math.min(#buttons,selected_index+1);redraw()
    elseif event.key=='ok' and buttons[selected_index] then ui.auto_library=false;buttons[selected_index].action()
    elseif event.key=='back' then ui.auto_library=false;if busy then cancel() elseif message~='' then message='';redraw() else back() end end
  end
end

function on_tick()
  if ui.update_downloading and view=='update' and now()-(ui.update_downloading.drawn_at or 0)>=300 then
    ui.update_downloading.drawn_at=now();redraw('')
  end
  if kb.hold then
    local h=kb.hold
    if view~='keyboard' or now()>h.stop or kb.text=='' then F.kb_hold_stop()
    elseif now()>=h.at then kb_backspace();h.at=now()+120 end
  end
  if busy and download_file and download_native then
    local ok,size=pcall(function() return book_store:size(download_file) end)
    if ok and type(size)=='number' then
      if size>download_bytes then request_started=now();redraw(T('downloaded_kib',size//1024)) end
      download_bytes=size
      if size>32*1024*1024 then
        request_id=request_id+1;if active then pcall(function() active:cancel() end) end
        active=nil;busy=false;clear_partial();ui.download_error=T('err_too_big_32');view='download_error';redraw('');return
      end
    end
  end
  if ui.reload_sleep and not busy then ui.reload_sleep=false;if view=='sleep' then local status=message;enter_sleep();message=status end end
  if ui.auto_library and not busy then ui.auto_library=false;catalog();return end
  if auto_reader_sync and not busy then auto_reader_sync=false;sync_reader_events() end
  if bg.handle and bg.started and now()-bg.started>=25000 then quiet_cancel() end
  if busy and now()-request_started>=35000 then
    request_id=request_id+1
    if active then pcall(function() active:cancel() end) end
    active=nil;busy=false
    if download_file then clear_partial();ui.download_error=T('err_download_timeout');view='download_error';redraw('')
    else say('err_timeout') end
  end
  prefetch()
end
function on_leave()
  kb.hold=nil
  quiet_cancel()
  ui.sleep_runs=nil
  if ui.sleep_picture then pcall(function() ui.sleep_picture:release() end);ui.sleep_picture=nil end
  ui.credentials=nil;ui.reveal=false;ui.clip_key=nil;ui.clip_url=nil
  if pair_qr then pcall(function() pair_qr:release() end);pair_qr=nil end
  F.drop_stores_qr()
  request_id=request_id+1
  if active then pcall(function() active:cancel() end) end
  active=nil;busy=false;clear_partial()
  wifi_kept_at=nil
  pcall(function() c.net:keep_wifi(1) end)
end
