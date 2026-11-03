# PHP Switcher

Mała natywna aplikacja macOS do przełączania PHP w terminalu i instalowania wersji z serii 8.3, 8.4 oraz 8.5.

## Używanie

Otwórz `PHP Switcher.app`. Przycisk **Użyj** wybiera wersję dla nowych poleceń `php`; można też przełączać ją z menu PHP obok zegara. **Zainstaluj** pobiera i buduje wskazaną wersję. **Inna wersja…** pozwala podać pełny numer wydania. Instalacja nie aktywuje nowej wersji automatycznie.

Domyślnie widoczne są wersje zarządzane przez aplikację. Przełącznik **Pokaż pozostałe instalacje** udostępnia PHP znalezione w MAMP i Homebrew. **Dodaj z dysku…** przyjmuje katalog instalacji lub plik `bin/php`. Ikona suwaków otwiera graficzne ustawienia wybranej instalacji.

Przy pierwszym skonfigurowaniu ścieżki trzeba otworzyć nowe okno Terminala. Jeśli bieżący terminal już używa `~/.local/php/current/bin`, przełączanie działa od następnego wywołania PHP. Program nie zmienia konfiguracji Apache, PHP-FPM ani MAMP.

## Ustawienia programu i język (1.5)

Główne okno ma zakładki **Wersje PHP**, **Ustawienia** i **O programie**. Ustawienia otworzysz też skrótem **⌘,**, z menu aplikacji lub menu PHP przy zegarze.

- **Język programu**: Polski lub English. Wybór zapisuje się automatycznie i działa od razu w interfejsie, menu PHP, edytorze konfiguracji i komunikatach instalatora. Domyślnym językiem pozostaje polski. Treści komunikatów pobierane z GitHub oraz dzienniki zewnętrznych narzędzi zachowują język źródła.
- **Uruchamiaj przy starcie systemu**: uruchamia aplikację po zalogowaniu do macOS. Używa systemowego `SMAppService.mainApp`; stan jest odczytywany z macOS, także po powrocie z Ustawień systemowych. Gdy macOS wymaga zgody, aplikacja pokazuje osobny komunikat i przycisk otwierający ustawienia logowania. Błąd rejestracji nie jest pokazywany jako udane włączenie. Domyślnie program nie rejestruje autostartu.
- **O programie**: nazwa aplikacji, wersja i numer kompilacji z pakietu, krótki opis oraz twórca **danny3b**.

Przed włączeniem autostartu uruchom podpisany pakiet z docelowego miejsca, np. `~/Applications/PHP Switcher.app`. Dokumentacja mechanizmu macOS: [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).

Tłumaczenia angielskie są w `Resources/en.lproj/Localizable.strings`; polski tekst jest językiem bazowym. `{0}`, `{1}` itd. oznaczają argumenty, które tłumaczenie może przestawiać. Identyfikatory źródeł instalacji i kategorii ustawień nie zależą od języka. Preferencja `appLanguage` trafia do standardowego magazynu ustawień macOS.

## Usuwanie wersji (1.2)

Ikona **Kosza** obok wersji zarządzanej przez PHP Switcher przenosi całą instalację do systemowego Kosza, razem z jej `php.ini` i rozszerzeniami. Potwierdzenie pokazuje dokładną wersję i ścieżkę. Domyślnym przyciskiem jest **Anuluj**. Po usunięciu lista i wynik sprawdzania bezpieczeństwa odświeżają się automatycznie; wersję można zainstalować ponownie.

- Aktywnej wersji nie można usunąć. Najpierw wybierz inną przyciskiem **Użyj**.
- Dla katalogów dodanych ręcznie ikona **minus** usuwa tylko wpis z listy. Pliki pozostają na dysku i można je ponownie dodać przez **Dodaj z dysku…**.
- Wersje **Homebrew** można odinstalować w aplikacji od wersji **1.3.2**. Kosz otwiera potwierdzenie **Odinstaluj przez Homebrew**, z numerem wersji, nazwą pakietu i ścieżką. To trwałe odinstalowanie przez `brew uninstall --formula`, bez przenoszenia do Kosza. Aplikacja wyłącza automatyczne usuwanie zależności, aktualizację Homebrew i sprzątanie konfiguracji. Nie używa `--force` ani `--ignore-dependencies`; Homebrew chroni pakiety wymagane przez inne programy. Na Apple Silicon korzysta z Rosetty dla Homebrew w `/usr/local`.
- Przed odinstalowaniem Homebrew sprawdzane są katalog Cellar, rejestr pakietu, dowiązania oraz usługa PHP-FPM. Aktywne PHP i kilka wydań w tym samym pakiecie blokują operację z konkretnym komunikatem. Zarejestrowaną usługę użytkownika można zatrzymać w aplikacji. Stan jest ponownie sprawdzany po potwierdzeniu. MAMP nadal zarządza usuwaniem własnych instalacji.
- Kliknięcie Kosza przy zablokowanej instalacji wyświetla powód blokady. Podczas sprawdzania i usuwania widać opis trwającej operacji.

### Zatrzymywanie PHP-FPM (1.4)

Przycisk **Stop** (kwadrat w kółku) przy PHP z Homebrew otwiera potwierdzenie **Zatrzymaj usługę**. Zatrzymuje PHP-FPM bieżącego użytkownika oraz wyłącza autostart, zachowując instalację PHP. Kliknięcie **Kosza** przy takiej usłudze również proponuje jej zatrzymanie, a potem pokazuje osobne potwierdzenie odinstalowania. Anulowanie drugiego okna pozostawia PHP na dysku.

Aplikacja sprawdza właściciela, etykietę, program i tożsamość pliku LaunchAgent oraz program faktycznie uruchomionej usługi. Zatrzymuje wyłącznie odpowiednią usługę przez macOS `launchctl` i potwierdza jej wyłączenie. Działa również ze starymi usługami PHP 7.3/7.4, których repozytorium nie jest zaufane przez aktualne Homebrew; nie zmienia zaufania repozytoriów i nie wykonuje kodu ich formuł. Nieaktywne wpisy autostartu także można wyłączyć. Kopia pliku trafia do `~/Library/Application Support/PHP Switcher/stopped-services/<identyfikator>/`. Usługi systemowe administratora wymagają osobnej obsługi i nie są zmieniane przez ten przycisk.
- Aby odzyskać instalację z Kosza, przenieś jej folder z powrotem pod ścieżkę pokazaną w potwierdzeniu, np. `~/.local/php/8.4.27`, i kliknij **Odśwież**. Nie nadpisuj w ten sposób nowszej instalacji o tej samej nazwie. Miejsce na dysku jest zwalniane dopiero po opróżnieniu Kosza przez użytkownika.
- Usuwanie i przełączanie korzystają ze wspólnej blokady z instalatorem. Ponowne sprawdzenie przed przeniesieniem chroni aktywną wersję oraz wykrywa podmianę katalogu lub wersji od czasu otwarcia potwierdzenia. Jeśli przeniesienie do Kosza się nie powiedzie, aplikacja zgłasza błąd; nie próbuje usuwać plików trwale.

## Graficzny edytor php.ini (1.3)

Kliknij **ikonę suwaków** obok wersji PHP, zmień wartości i wybierz **Zapisz ustawienia**. Każda instalacja ma własne okno ustawień z czterema zakładkami:

| Zakładka | Ustawienia |
| --- | --- |
| Wysyłanie plików | `file_uploads`, `upload_max_filesize`, `post_max_size`, `max_file_uploads` |
| Pamięć i limity | `memory_limit`, `max_execution_time`, `max_input_time`, `max_input_vars` |
| Błędy i dzienniki | `display_errors` (również `stderr`), `display_startup_errors`, `log_errors` |
| Data i czas | `date.timezone`, z wyborem popularnych stref |

Rozmiary można wpisywać jako liczbę bajtów albo z końcówką `K`, `M` lub `G`, np. `128M`. Formularz sprawdza wartości, wskazuje niespójny limit POST względem limitu pliku i blokuje zapis nieprawidłowych danych. Odczytuje zapisane w plikach limity czasu, ponieważ CLI wymusza inne wartości podczas wykonywania.

Edytor wykrywa główny `php.ini` oraz dodatkowe pliki `.ini` w kolejności wczytywania przez wybrane PHP. Jeśli dodatkowy plik nadpisuje ustawienie, zmiana trafia do tego pliku, a formularz pokazuje jego nazwę. Zmieniane są wyłącznie wybrane pola, z zachowaniem pozostałych ustawień, komentarzy i sekcji warunkowych `PATH`/`HOST`. Brakujący wpis globalny jest dodawany do głównego pliku. Edytor nie obsługuje przepisywania wielowierszowych wartości edytowanych pól; takie wpisy należy zmienić tekstowo.

Przed zapisem powstaje kopia każdego zmienianego pliku obok oryginału: `<plik>.php-switcher-<UUID>.bak`. **Pokaż kopię** otwiera ją w Finderze. Po zapisie aplikacja uruchamia wybrane PHP i weryfikuje wynik. W razie błędu przywraca poprzednie pliki. Zewnętrzna zmiana konfiguracji od czasu otwarcia formularza blokuje zapis; **Wczytaj ponownie** pobiera aktualne dane. Zapis wymaga zwykłych uprawnień użytkownika do pliku i jego katalogu, bez automatycznego podnoszenia uprawnień.

**Zamknij** pozwala odrzucić niezapisane zmiany. Przycisk folderu w nagłówku pokazuje główny plik w Finderze. Ustawienia dotyczą konfiguracji wykrytej przez wskazane PHP CLI. Nowe wywołania w terminalu odczytują je od razu; serwer WWW korzystający z tego samego pliku wymaga ponownego uruchomienia. Wybór PHP w terminalu nie przełącza wersji ani konfiguracji serwera MAMP.

Opis dyrektyw: [oficjalna dokumentacja PHP](https://www.php.net/manual/en/ini.core.php). Kolejność plików i ponowne wczytywanie: [konfiguracja PHP](https://www.php.net/manual/en/configuration.file.php).

## Instalator

- Instaluje do `~/.local/php/<wersja>`; aktywną wersję wskazuje dowiązanie `~/.local/php/current`.
- Weryfikuje archiwum PHP przez SHA-256 z oficjalnego API php.net.
- Korzysta z istniejących bibliotek Homebrew i Apple Command Line Tools. Nie aktualizuje Homebrew ani jego pakietów.
- Na tym Macu kompiluje PHP jako x86_64 dla zgodności z już zainstalowanymi bibliotekami. Sama aplikacja jest natywna dla Apple Silicon.
- Każda wersja otrzymuje osobne `php.ini` i rozszerzenia. Imagick jest kompilowany dla właściwego ABI PHP, jeżeli występuje w konfiguracji bazowej.
- Sprawdza uruchomienie PHP, wymagane rozszerzenia, SQLite, generowanie PNG, Imagick i rzeczywiste wykonanie kodu przez JIT przed oznaczeniem instalacji jako gotowej.
- Anulowanie lub błąd usuwa niekompletną instalację. Istniejące PHP i aktywny wybór pozostają bez zmian.
- Wersje zainstalowane w ten sposób nie są zarządzane przez `brew upgrade`.

Instalator jest przygotowany dla obecnego środowiska tego komputera. Na nowym Macu wymagane będą najpierw odpowiednie biblioteki Homebrew i Command Line Tools. Nie przenosi automatycznie dodatkowych rozszerzeń PECL innych niż Imagick; ich konfigurację trzeba uzupełnić osobno.

## Sprawdzanie poprawek bezpieczeństwa (1.1)

Sekcja **Bezpieczeństwo PHP** sprawdza oficjalny katalog wydań na php.net i publiczne komunikaty bezpieczeństwa repozytorium `php/php-src` na GitHub. **Sprawdź teraz** wymusza odczyt. W **Szczegółach** można wyłączyć automatyczne sprawdzanie, zobaczyć wynik dla każdej instalacji, numery CVE i odnośniki do komunikatów.

- Automatyczne sprawdzanie jest domyślnie włączone. Działa przy uruchomieniu oraz co 6 godzin, gdy aplikacja pozostaje uruchomiona, także po zamknięciu jej okna do paska menu. Wynik z ostatnich 6 godzin jest ponownie używany. Po wybudzeniu Maca sprawdzany jest termin kolejnego odczytu; po błędzie następuje ponowna próba po co najmniej 15 minutach. Zakończenie aplikacji zatrzymuje sprawdzanie.
- Zakres obejmuje instalacje PHP Switcher, dodane ręcznie oraz aktywne PHP w terminalu. Pozostałe PHP z MAMP i Homebrew nie są objęte wynikiem tej sekcji, chyba że zostaną wybrane jako aktywne. Konfiguracja serwerów WWW pozostaje poza zakresem aplikacji.
- Ważność **Krytyczna** pochodzi z oceny komunikatu zespołu PHP, a nie z samego numeru nowszego wydania. Porównanie odbywa się w obrębie właściwej serii i obejmuje wcześniejsze poprawki, nawet jeśli najnowsze wydanie ma już tylko zwykłe zmiany.
- Dostępna krytyczna poprawka powoduje czerwony komunikat w oknie i znak ostrzeżenia przy PHP na pasku menu. Można otworzyć opis podatności lub zainstalować najnowsze PHP w tej samej serii. Jeśli odpowiednie PHP jest już zainstalowane, pojawia się przycisk jego wyboru. Instalowanie i przełączanie wymaga kliknięcia użytkownika.
- Brak sieci, limit API, nieznany format danych lub wersja bez wsparcia nie są przedstawiane jako potwierdzenie aktualności. Ostatni udany wynik pozostaje dostępny z datą i informacją o nieaktualności. Stan zależy od kompletności oficjalnych publikacji i numeru wersji; nie jest audytem dodatkowych bibliotek, rozszerzeń PECL ani poprawek dostawcy w niestandardowych kompilacjach. Warunki wykorzystania podatności opisuje jej komunikat.
- Sprawdzanie nie wymaga konta GitHub. Wysyła odczyty do php.net i api.github.com; nie przesyła ścieżek instalacji ani plików projektów.

Źródła: [katalog PHP](https://www.php.net/releases/?json), [komunikaty PHP](https://github.com/php/php-src/security/advisories), [API komunikatów GitHub](https://docs.github.com/en/rest/security-advisories/repository-advisories#list-repository-security-advisories).

## Pliki

- Aplikacja: `~/Applications/PHP Switcher.app`
- Źródła: `/Applications/MAMP/htdocs/Github Danny3b/php-switcher`
- Instalacje i aktywne dowiązanie: `~/.local/php`
- Konfiguracja dodatkowych katalogów: `~/Library/Application Support/PHP Switcher/installations.json`
- Dzienniki instalacji: `~/Library/Logs/PHP Switcher`
- Pobrane archiwa: `~/Library/Caches/PHP Switcher`
- Ostatni pełny wynik sprawdzania poprawek: `~/Library/Caches/PHP Switcher/security.json`
- Wpis PATH: `~/.zprofile`; przed zmianą istniejącego pliku powstaje kopia `.zprofile.php-switcher-*.bak`.

## Budowanie i testy

macOS 14 lub nowszy, Apple Silicon, zainstalowane Apple Command Line Tools. Bez zewnętrznych zależności dla samej aplikacji.

```sh
bash build.sh
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Preferences.swift Tests/PreferencesTests.swift -framework ServiceManagement -o build/preferences-tests
build/preferences-tests
python3 -m unittest discover -s Tests -p 'test_*.py' -v
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Core.swift Tests/CoreTests.swift -o build/core-tests
build/core-tests
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Core.swift Tests/RemovalTests.swift -o build/removal-tests
build/removal-tests
# Opcjonalny test Kosza macOS: przenosi i przywraca wyłącznie tymczasowy katalog testowy.
build/removal-tests --trash-integration
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Core.swift Tests/HomebrewRemovalTests.swift -o build/homebrew-removal-tests
build/homebrew-removal-tests
# Opcjonalny odczyt rzeczywistych instalacji Homebrew: bez odinstalowywania.
build/homebrew-removal-tests --live
# Odczyt konfiguracji usług PHP 7.3/7.4, bez zatrzymywania:
build/homebrew-removal-tests --live-services
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Core.swift Tests/ServiceIntegrationTests.swift -o build/service-integration-tests
# Uruchamia i zatrzymuje wyłącznie własny proces sleep pod testową etykietą php@99.99:
build/service-integration-tests --run
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Core.swift Sources/Configuration.swift Tests/ConfigurationTests.swift -o build/configuration-tests
build/configuration-tests --php "$HOME/.local/php/current/bin/php"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache Sources/Localization.swift Sources/Core.swift Sources/Security.swift Tests/SecurityTests.swift -o build/security-tests
build/security-tests
# Opcjonalny test z rzeczywistym połączeniem do źródeł:
build/security-tests --live
```

Wynik to `build/PHP Switcher.app`, podpisany lokalnym podpisem ad hoc. Pakiet jest przeznaczony do lokalnego użytku; rozpowszechnianie wymaga własnego podpisu Developer ID i notaryzacji.

Ustawienia programu i autostart są w `Sources/Preferences.swift`, zakładki w `Sources/PreferencesView.swift`, a wybór tłumaczeń w `Sources/Localization.swift`. Testy ustawień korzystają z oddzielnego magazynu preferencji i symulowanego mechanizmu autostartu; nie zmieniają rzeczywistych elementów logowania.

Kod jest podzielony na wykrywanie, przełączanie i usuwanie (`Sources/Core.swift`), interfejs i menu (`Sources/App.swift`), sprawdzanie poprawek (`Sources/Security.swift`, `Sources/SecurityView.swift`) oraz instalator (`Resources/install_php.py`). Testy używają oddzielnych katalogów tymczasowych i nie przełączają rzeczywistego PHP. Testy usuwania sprawdzają odzyskiwanie plików, ochronę aktywnej wersji, zakres katalogów, dowiązania, podmianę instalacji, błędy Kosza i współbieżność z instalatorem. Testy bezpieczeństwa sprawdzają zakresy wersji, rozróżnienie serii, krytyczne poprawki, stan bez wsparcia, nieznane dane, cache, paginację oraz błędy połączenia i API. Pliki w `Tests/Fixtures` zawierają wybrane pola z oficjalnych odpowiedzi pobranych 22.10.2026, bez treści opisów podatności.
