# SPL Man – technický audit měření, logování a vazby na normy

Datum auditu: 11. října 2026  
Auditovaný stav: zdrojové soubory a automatizované testy dostupné v repozitáři SPLMan  
Výsledek testu: `./test.sh` – `SPLMan DSP validation: PASS`, `SPLMan self-test: PASS`

## 1. Executive Summary

SPL Man je nativní macOS aplikace ve Swiftu, která používá Core Audio HAL pro jeden zvolený vstupní kanál. Aktuální implementace odvozuje jednosekundové intervaly z počtu zpracovaných audio framů, nikoli z obnovovací frekvence UI. A/C vážení, Fast/Slow, energetický Leq, sekundová maxima a LCpeak mají automatizované numerické testy. Logger dostává dokončené sekundové intervaly přes omezené fronty, používá UTC, ukládá identifikátor a stav relace a při ztrátě intervalu zapisuje explicitní řádek `gap` nebo `error`.

Opraveny byly hlavní dříve zjištěné problémy: tichá ztráta sekund při zpoždění UI, chybějící sekundové LAeq/LCeq, UTC a stavová metadata, absence modelu relace a událostí, chybějící označení výpadků a chybějící 30minutová okna pro koncertní monitoring. První audio sekunda, která začala před stiskem Record, je vyloučena a označena jako gap. Při známé nespojitosti se evidují také framy zahozeného rozpracovaného intervalu. UI a CSV vycházejí ze stejné DSP pipeline; zobrazovací snapshot má vlastní cestu a jeho případné zahození neovlivní sekundový záznam.

Audit neprokazuje shodu ani certifikaci podle IEC 61672 třídy 1 nebo 2. Nebyla provedena typová zkouška, periodická zkouška ani fyzické ověření kompletního řetězce mikrofon–předzesilovač–audio rozhraní–macOS–software. Nebyl použit fyzický kalibrátor, nebyl proveden reálný 24hodinový soak test a nebyly simulovány stavy zaplnění disku nebo výpadku napájení. Vztah uložené kalibrace k mikrofonu, vstupnímu gainu a celé konfiguraci měření zůstává na výslovný pokyn uživatele nezměněný a je veden jako známé omezení.

## 2. Architecture

### Skutečný datový tok

```text
Core Audio HAL input (jeden Float32 kanál)
    ↓
kontrola zařízení, kanálu a sample rate
    ↓
A a C váhovací filtry + Z jako nezměněný vstup
    ↓
energie po vzorcích; A Fast 125 ms; A/C Slow 1 s
    ↓
sekundové LAeq/LCeq/LZeq, LAFmax/LASmax, 4× odhad LCpeak
    ↓
energetická okna 1/10/15/30 min
    ↓
omezená fronta dokončených sekund + health/dropout čítače
    ├── poslední snapshot → UI
    └── CompletedSecondRecorder → MeasurementSample/Event/Gap
                                      ↓
                                 asynchronní CSV logger
```

Audio backend je Audio Unit HAL s explicitně vybraným zařízením a kanálem; podporovaný sample rate je validován před vytvořením DSP procesoru ([`AudioCaptureEngine.swift:283`](../Sources/SPLMan/Audio/AudioCaptureEngine.swift#L283), [`SPLProcessor.swift:166`](../Sources/SPLMan/DSP/SPLProcessor.swift#L166)). Callback zpracuje buffer, sleduje nespojitost sample time, v takovém případě invaliduje časová okna, započítá zahozené částečné framy a odebírá všechny dokončené sekundové snapshoty ([`AudioCaptureEngine.swift:433`](../Sources/SPLMan/Audio/AudioCaptureEngine.swift#L433), [`SPLProcessor.swift:255`](../Sources/SPLMan/DSP/SPLProcessor.swift#L255)). UTC značky dokončených sekund vznikají z počátku streamu a pořadového čísla intervalu; host time slouží pro vazbu prvního audio timestampu k UTC ([`AudioCaptureEngine.swift:479`](../Sources/SPLMan/Audio/AudioCaptureEngine.swift#L479), [`AudioCaptureEngine.swift:490`](../Sources/SPLMan/Audio/AudioCaptureEngine.swift#L490)).

DSP uchovává stav filtrů mezi buffery a zpracovává vzorky v jedné průchozí smyčce ([`SPLProcessor.swift:190`](../Sources/SPLMan/DSP/SPLProcessor.swift#L190)). Jedna sekunda je uzavřena po `sampleRate` framech, její energie je zprůměrována v lineární oblasti a teprve pak převedena na dB ([`SPLProcessor.swift:232`](../Sources/SPLMan/DSP/SPLProcessor.swift#L232), [`SPLProcessor.swift:343`](../Sources/SPLMan/DSP/SPLProcessor.swift#L343)). Klouzavá okna obsahují sekundové energie, mají pevnou kapacitu a hodnotu publikují až po naplnění celého okna ([`RollingEnergy.swift:14`](../Sources/SPLMan/DSP/RollingEnergy.swift#L14), [`RollingEnergy.swift:32`](../Sources/SPLMan/DSP/RollingEnergy.swift#L32)).

Pro UI se smí zahodit pouze zobrazovací snapshot. Záznam používá samostatnou omezenou frontu dokončených sekund s kapacitou 120 a počítá zahozené položky ([`AudioCaptureEngine.swift:5`](../Sources/SPLMan/Audio/AudioCaptureEngine.swift#L5), [`AudioCaptureEngine.swift:49`](../Sources/SPLMan/Audio/AudioCaptureEngine.swift#L49)). `CompletedSecondRecorder` ji vyprazdňuje na utility queue, doplňuje kalibrační offset, stav intervalu, alarmy a gap/event záznamy ([`CompletedSecondRecorder.swift:125`](../Sources/SPLMan/App/CompletedSecondRecorder.swift#L125), [`CompletedSecondRecorder.swift:180`](../Sources/SPLMan/App/CompletedSecondRecorder.swift#L180)). CSV logger zapisuje mimo audio callback, omezuje počet čekajících operací, synchronizuje soubor a přetečení zapisuje jako viditelnou chybu ([`CSVMeasurementLogger.swift:102`](../Sources/SPLMan/Logging/CSVMeasurementLogger.swift#L102), [`CSVMeasurementLogger.swift:356`](../Sources/SPLMan/Logging/CSVMeasurementLogger.swift#L356)).

## 3. Compliance Matrix

Stavy `PASS` a `PARTIAL` níže popisují pouze ověřenou softwarovou implementaci. Neznamenají shodu měřidla s normou.

| Oblast | Stav | Důkaz | Problém | Oprava / současný stav |
|---|---|---|---|---|
| Výběr vstupu a sample rate | PASS | HAL vstup, konkrétní kanál a rozsah 32–192 kHz ([`AudioCaptureEngine.swift:283`](../Sources/SPLMan/Audio/AudioCaptureEngine.swift#L283)); test platných/neplatných rate ([`DSPValidation.swift:28`](../Sources/SPLMan/Diagnostics/DSPValidation.swift#L28)) | Neplatný sample rate mohl narušit intervaly | Neplatná nebo neceločíselná frekvence se odmítá |
| A/C frekvenční vážení | PASS | Stavové kaskádní filtry normalizované na 1 kHz ([`FrequencyWeightingFilter.swift:45`](../Sources/SPLMan/DSP/FrequencyWeightingFilter.swift#L45)); 100/1 000/10 000 Hz při 44,1/48/96 kHz proti nezávislému analogovému vztahu ([`DSPValidation.swift:57`](../Sources/SPLMan/Diagnostics/DSPValidation.swift#L57)) | Úplná normativní charakteristika nebyla laboratorně proměřena | Doplněny numerické referenční testy; certifikační tolerance nebyly tvrzeny |
| Z vážení | PASS | Z je přímá energie vstupu a poskytuje LZeq,1s ([`SPLProcessor.swift:212`](../Sources/SPLMan/DSP/SPLProcessor.swift#L212), [`SPLProcessor.swift:357`](../Sources/SPLMan/DSP/SPLProcessor.swift#L357)); test sinus/konstanta/impuls/ticho/šum ([`DSPValidation.swift:75`](../Sources/SPLMan/Diagnostics/DSPValidation.swift#L75)) | Původně chybělo | Přidáno LZeq,1s do snapshotu, UI metrik a CSV |
| Fast / Slow | PASS | Exponenciální vážení energie s 0,125 s a 1 s ([`SPLProcessor.swift:66`](../Sources/SPLMan/DSP/SPLProcessor.swift#L66), [`SPLProcessor.swift:178`](../Sources/SPLMan/DSP/SPLProcessor.swift#L178)); analytický step-response test ([`DSPValidation.swift:41`](../Sources/SPLMan/Diagnostics/DSPValidation.swift#L41)) | Riziko závislosti na bufferu nebo průměrování dB | Výpočet probíhá po vzorcích v lineární energii |
| Leq a klouzavá okna | PASS | Sekundové energetické průměry a okna 1/10/15/30 min ([`SPLProcessor.swift:343`](../Sources/SPLMan/DSP/SPLProcessor.swift#L343)); test nezávislosti na bufferu ([`DSPValidation.swift:133`](../Sources/SPLMan/Diagnostics/DSPValidation.swift#L133)) | Dříve chyběly přesné sekundové hodnoty a 30 min | Intervaly jsou odvozené z frame count a dlouhá okna z jednosekundových energií |
| LAFmax, LASmax, LCpeak | PARTIAL | Sekundová maxima, session maxima a 4× intersample detektor ([`SPLProcessor.swift:3`](../Sources/SPLMan/DSP/SPLProcessor.swift#L3), [`SPLProcessor.swift:203`](../Sources/SPLMan/DSP/SPLProcessor.swift#L203)); test maxima/resetu ([`DSPValidation.swift:151`](../Sources/SPLMan/Diagnostics/DSPValidation.swift#L151)) | Softwarový 4× odhad nebyl ověřen normativním peak testem celé sestavy | Rozlišena maxima časového vážení a C-vážený peak; fyzická odezva zůstává neověřena |
| Kalibrace | PARTIAL | Kontrola stability, koncentrace kolem 1 kHz a energetický průměr pro offset na 94 dB ([`CalibrationSession.swift:11`](../Sources/SPLMan/DSP/CalibrationSession.swift#L11), [`CalibrationSession.swift:40`](../Sources/SPLMan/DSP/CalibrationSession.swift#L40)); automatizované pozitivní i negativní případy ([`SelfTest.swift:152`](../Sources/SPLMan/Diagnostics/SelfTest.swift#L152)) | Bez fyzického kalibrátoru; klíč jen zařízení + kanál, ne mikrofon/gain/konfigurace | Jednobodová softwarová kalibrace ověřena; rozšíření vazby bylo výslovně vyřazeno uživatelem |
| Sekundové logování a UTC | PASS | Povinné sekundové sloupce, stav, session ID, čítače a explicitní UTC `Z` ([`CSVMeasurementLogger.swift:86`](../Sources/SPLMan/Logging/CSVMeasurementLogger.swift#L86), [`CSVMeasurementLogger.swift:464`](../Sources/SPLMan/Logging/CSVMeasurementLogger.swift#L464), [`CSVMeasurementLogger.swift:590`](../Sources/SPLMan/Logging/CSVMeasurementLogger.swift#L590)) | Dříve logger závisel na UI timeru a postrádal metadata | Záznam bere dokončené audio sekundy a ukládá integritní údaje |
| Ztráta dat a backpressure | PASS | Omezená DSP/fronta loggeru, sekvenční kontrola a `gap/error` řádky ([`SPLProcessor.swift:402`](../Sources/SPLMan/DSP/SPLProcessor.swift#L402), [`CSVMeasurementLogger.swift:191`](../Sources/SPLMan/Logging/CSVMeasurementLogger.swift#L191), [`CSVMeasurementLogger.swift:401`](../Sources/SPLMan/Logging/CSVMeasurementLogger.swift#L401)); overflow a burst testy ([`LoggingIntegrityTests.swift:140`](../Sources/SPLMan/Diagnostics/LoggingIntegrityTests.swift#L140)) | Riziko tiché ztráty nebo kontaminace prvního REC vzorku | Ztráta je počítána, hlášena a exportována; první částečný REC interval je gap; audio callback nečeká na disk |
| Relace a události | PARTIAL | Stavový model relace a metadata ([`MeasurementSession.swift:3`](../Sources/SPLMan/Logging/MeasurementSession.swift#L3)); event typy a metadata ([`MeasurementEvent.swift:3`](../Sources/SPLMan/Logging/MeasurementEvent.swift#L3)); historie rozpozná dřívější `recording` jako přerušený stav ([`RecordingHistory.swift:80`](../Sources/SPLMan/App/RecordingHistory.swift#L80)); streamový reader vrací posledních 100 event/gap/error položek pro UI ([`RecordingEventHistory.swift:41`](../Sources/SPLMan/App/RecordingEventHistory.swift#L41), [`SettingsView.swift:282`](../Sources/SPLMan/UI/SettingsView.swift#L282)) | Některé typy jsou definované, ale aplikace nemá samostatný pause/resume tok; kvalita názvu/místa/mikrofonu závisí na uživateli | Přidány session/event řádky, přehled relací a rozbalitelná historie událostí; chybějící uživatelská metadata mají fallback nebo zůstávají volitelná |
| Časová integrita a výpadky | PARTIAL | Kontrola nespojitosti sample time, invalidace oken a gap z missing i zahozených částečných framů ([`AudioCaptureEngine.swift:462`](../Sources/SPLMan/Audio/AudioCaptureEngine.swift#L462), [`CompletedSecondRecorder.swift:367`](../Sources/SPLMan/App/CompletedSecondRecorder.swift#L367)); test invalidace a počtu zahozených framů ([`DSPValidation.swift:206`](../Sources/SPLMan/Diagnostics/DSPValidation.swift#L206)) | Uspání, hot-plug a změna systémového času nebyly ověřeny na hardware | DSP nepřenáší neúplné okno přes známou nespojitost a gap vznikne i při resetu sample time bez kladného počtu missing framů; fyzické scénáře zůstávají neověřeny |
| 24hodinová stabilita | PARTIAL | 86 400 aktualizací `RollingEnergy` a kontrola 64bit frame count při 192 kHz ([`DSPValidation.swift:236`](../Sources/SPLMan/Diagnostics/DSPValidation.swift#L236)) | Nejde o reálné zpracování 24 h audia ani test CPU, paměti a disku | Zrychleně ověřena agregace a rozsah čítače; skutečný soak test chybí |
| CSV export | PARTIAL | Jednoznačné názvy s jednotkami, session/sample/event/gap/error řádky a escapování ([`CSVMeasurementLogger.swift:86`](../Sources/SPLMan/Logging/CSVMeasurementLogger.swift#L86), [`CSVMeasurementLogger.swift:612`](../Sources/SPLMan/Logging/CSVMeasurementLogger.swift#L612)); integritní test CSV ([`LoggingIntegrityTests.swift:36`](../Sources/SPLMan/Diagnostics/LoggingIntegrityTests.swift#L36)) | Dříve export neobsahoval integritní metadata; textová pole nejsou neutralizována proti interpretaci jako spreadsheet formule | Rozšířen CSV formát při zachování starších sloupců; pro obecnou distribuci zbývá ochrana formula injection |
| Databáze / historie | PARTIAL | Relace a vzorky jsou v CSV; posledních 100 relací v `UserDefaults` ([`RecordingHistory.swift:42`](../Sources/SPLMan/App/RecordingHistory.swift#L42), [`RecordingHistory.swift:95`](../Sources/SPLMan/App/RecordingHistory.swift#L95)) | Neexistuje SQLite ani indexované čtení dlouhých časových řad; inspekce načítá celé CSV | CSV je pro současný sekvenční zápis funkční; rozsáhlá databázová vrstva nebyla přidána bez prokázané potřeby |
| PDF report | NOT APPLICABLE | V repozitáři není PDF export | Požadovaný report nelze ověřit | Budoucí PDF má být generováno z CSV a obsahovat metadata, průběh, maxima, Leq, výpadky a úplnost; musí být označeno jako necertifikovaný report |
| Koncertní režim / DIN 15905-5 | PARTIAL | LAeq,30min, LCpeak, nastavitelné limity, alarm eventy a barevná indikace ([`CompletedSecondRecorder.swift:266`](../Sources/SPLMan/App/CompletedSecondRecorder.swift#L266), [`RecordingHistory.swift:10`](../Sources/SPLMan/App/RecordingHistory.swift#L10), [`MeterView.swift:121`](../Sources/SPLMan/UI/MeterView.swift#L121)) | Metodika, umístění mikrofonu, korekce a úplné požadavky DIN nebyly ověřeny | Funkční podpůrné prvky jsou implementovány, režim není označen jako shodný s DIN |
| IEC 61260-1 | NOT APPLICABLE | Aplikace neimplementuje oktávové ani zlomkooktávové banky | Norma se týká pásmových filtrů | Bez pásmových filtrů se tato norma na auditovanou funkci nevztahuje |
| IEC 61672-1/-2/-3, IEC 60942 | NOT VERIFIED | Pouze kontrola kódu a softwarové testy; žádná typová, periodická ani hardwarová zkouška | Chybí kompletní normativní a laboratorní ověření sestavy | Nutné akreditované zkoušky úplného měřicího řetězce |

## 4. DSP Validation

`DSPValidation.run()` ověřuje:

- Fast 125 ms a Slow 1 s proti analytické odezvě v lineární energii;
- A/C přenos na 100 Hz, 1 kHz a 10 kHz při 44,1, 48 a 96 kHz proti samostatně vypočtené analogové referenci s testovací tolerancí 0,8 dB;
- LAeq/LCeq/LZeq za jednu sekundu pro 1kHz sinus, konstantu, impuls, digitální ticho a deterministický bílý šum;
- shodu výsledku při jednom velkém bufferu a při proměnlivých velikostech bufferů;
- sekundové a session LAFmax/LCpeak, LASmax a reset;
- invalidaci rozpracovaného i dlouhých oken po nespojitosti;
- vyloučení první sekundy, která částečně předchází stisku Record, a explicitní gap pro dopřednou i zpětnou změnu audio času;
- omezenou frontu dokončených sekund a počítání ztrát;
- zrychlených 86 400 aktualizací 30minutového energetického okna a rozsah 64bit čítače.

Relevantní testy jsou v [`DSPValidation.swift:7`](../Sources/SPLMan/Diagnostics/DSPValidation.swift#L7). Samostatný self-test navíc ověřuje 4× intersample peak na 16kHz sinu, dlouhodobá maxima, 1kHz detektor a další body frekvenční odezvy ([`SelfTest.swift:79`](../Sources/SPLMan/Diagnostics/SelfTest.swift#L79), [`SelfTest.swift:123`](../Sources/SPLMan/Diagnostics/SelfTest.swift#L123)).

Výsledek `PASS` prokazuje shodu s očekávanou matematikou těchto testů. Neověřuje akustický tlak v Pa bez kalibrovaného fyzického řetězce, směrovou charakteristiku mikrofonu, vlastní šum, linearitu, dynamický rozsah, přetížení analogového vstupu, elektromagnetickou odolnost ani prostředí. Test nepokrývá explicitní pink-noise případ a frekvenční test neprochází kompletní normativní sadou frekvencí a sample rate.

## 5. Logging Validation

`LoggingIntegrityTests` ověřují životní cyklus relace, povinné sekundové sloupce, UTC s příponou `Z`, explicitní invalidní vzorek, gap při chybějícím pořadovém čísle, export event metadat, rozpoznání aktivní/přerušené relace, úplné uložení přijatého burstu 100 vzorků a viditelné přetečení omezené fronty ([`LoggingIntegrityTests.swift:27`](../Sources/SPLMan/Diagnostics/LoggingIntegrityTests.swift#L27), [`LoggingIntegrityTests.swift:169`](../Sources/SPLMan/Diagnostics/LoggingIntegrityTests.swift#L169)). `SelfTest` navíc ověřuje odmítnutí pre-REC částečné sekundy, vytvoření gapu včetně zahozených částečných framů i při zpětném resetu audio hodin a streamové načtení omezené historie událostí včetně víceřádkových metadat ([`SelfTest.swift:342`](../Sources/SPLMan/Diagnostics/SelfTest.swift#L342), [`SelfTest.swift:358`](../Sources/SPLMan/Diagnostics/SelfTest.swift#L358), [`SelfTest.swift:396`](../Sources/SPLMan/Diagnostics/SelfTest.swift#L396)).

CSV obsahuje timestamp UTC, session ID/status, stav měření a důvod, frame/second čítače, LAeq/LCeq/LZeq, LAFmax/LASmax/LCpeak za sekundu, dlouhá okna, stavové události a gap metadata. Soubor se při startu vytváří atomicky a při uzavření se synchronizuje ([`CSVMeasurementLogger.swift:151`](../Sources/SPLMan/Logging/CSVMeasurementLogger.swift#L151), [`CSVMeasurementLogger.swift:426`](../Sources/SPLMan/Logging/CSVMeasurementLogger.swift#L426)).

Nebylo provedeno skutečné zaplnění disku, odpojení úložiště ani násilné ukončení procesu během zápisu. `inspectSession(at:)` načte celý CSV soubor do paměti ([`CSVMeasurementLogger.swift:324`](../Sources/SPLMan/Logging/CSVMeasurementLogger.swift#L324)); pro velmi dlouhé relace je to škálovací riziko. Zapisované řádky jsou průběžně synchronizovány, ale bez transakční databáze nelze po výpadku napájení zaručit zachování posledního řádku.

## 6. Calibration Validation

Kalibrace je jednobodová na 94 dB. Aplikace sbírá 30 hodnot, požaduje omezený rozptyl, dostatečný signál, koncentraci kolem 1 kHz a přiměřený rozdíl C−A. Offset se počítá z energetického průměru dB hodnot ([`CalibrationSession.swift:23`](../Sources/SPLMan/DSP/CalibrationSession.swift#L23)). Kalibrační tón je oddělen od měřicí relace restartem vstupu, aby neovlivnil Leq; aplikace neprovádí automatickou kalibraci z neznámého signálu ([`MeterModel.swift:179`](../Sources/SPLMan/App/MeterModel.swift#L179)).

Softwarové testy potvrzují přijetí stabilního 1kHz signálu, odmítnutí nestability a odmítnutí nesprávné frekvence. Nebyla ověřena skutečná hladina fyzického kalibrátoru ani jeho třída podle IEC 60942. Uložený `CalibrationKey` obsahuje pouze UID zařízení a kanál ([`AppSettings.swift:8`](../Sources/SPLMan/Domain/AppSettings.swift#L8)). Vazba na konkrétní mikrofon, analogový/digitální gain a kompletní konfiguraci zůstává záměrně neopravená podle instrukce uživatele. Mikrofon lze uvést v metadatech relace, ale tato hodnota není součástí klíče kalibrace.

## 7. Implemented Changes

Auditovaný opravný celek zahrnuje tyto relevantní soubory:

- [`SPLProcessor.swift`](../Sources/SPLMan/DSP/SPLProcessor.swift) a [`FrequencyWeightingFilter.swift`](../Sources/SPLMan/DSP/FrequencyWeightingFilter.swift): přesné sekundové agregace, Z energie, maxima, 30minutová okna, kontinuita a omezené předávání;
- [`AudioCaptureEngine.swift`](../Sources/SPLMan/Audio/AudioCaptureEngine.swift): časování od audio framů/host time, fronta dokončených sekund a health/dropout čítače;
- [`CompletedSecondRecorder.swift`](../Sources/SPLMan/App/CompletedSecondRecorder.swift): oddělení sekundového záznamu od UI, tvorba samples/gaps/events a alarmů;
- [`MeasurementSession.swift`](../Sources/SPLMan/Logging/MeasurementSession.swift), [`MeasurementSample.swift`](../Sources/SPLMan/Logging/MeasurementSample.swift) a [`MeasurementEvent.swift`](../Sources/SPLMan/Logging/MeasurementEvent.swift): doménové modely relace, vzorku, výpadku a události;
- [`CSVMeasurementLogger.swift`](../Sources/SPLMan/Logging/CSVMeasurementLogger.swift): UTC a session metadata, typované řádky, bounded queue, kontrola pořadí, flush/close a inspekce relace;
- [`MeterModel.swift`](../Sources/SPLMan/App/MeterModel.swift), [`RecordingHistory.swift`](../Sources/SPLMan/App/RecordingHistory.swift), [`RecordingEventHistory.swift`](../Sources/SPLMan/App/RecordingEventHistory.swift), [`Metric.swift`](../Sources/SPLMan/Domain/Metric.swift), [`MeterView.swift`](../Sources/SPLMan/UI/MeterView.swift) a [`SettingsView.swift`](../Sources/SPLMan/UI/SettingsView.swift): metadata, přehled relací, streamovaná historie posledních 100 událostí, stavové indikace, nové metriky a koncertní alarmy;
- [`DSPValidation.swift`](../Sources/SPLMan/Diagnostics/DSPValidation.swift), [`LoggingIntegrityTests.swift`](../Sources/SPLMan/Diagnostics/LoggingIntegrityTests.swift) a [`SelfTest.swift`](../Sources/SPLMan/Diagnostics/SelfTest.swift): numerické, integrační a integritní testy;
- [`README.md`](../README.md): popis obsluhy, metrik, záznamu a omezení certifikace;
- tento soubor: konečný audit skutečné implementace.

Nebyla přidána externí závislost ani databázová vrstva. Kalibrační klíč v `AppSettings.swift` nebyl rozšířen, jak uživatel výslovně požadoval.

## 8. Remaining Limitations

1. Kalibrace není pevně svázána s mikrofonem, vstupním gainem a konfigurací měření. Uživatelské pole mikrofonu je pouze metadata relace.
2. Nebyl proveden test s fyzickým mikrofonem, audio rozhraním a kalibrátorem ani laboratorní frekvenční, amplitudový, peak a environmentální test.
3. Zrychlený 24hodinový test simuluje pouze 86 400 agregací `RollingEnergy` a kontroluje rozsah frame čítače. Nezpracovává 24 hodin audio bufferů a neměří CPU, paměť, disk I/O ani dlouhodobé chování Core Audio.
4. Nebyl injektován disk-full, odpojení disku, I/O chyba na úrovni OS ani výpadek napájení. Obnova posledního částečně zapsaného řádku není zaručena.
5. `inspectSession(at:)` načítá celý CSV soubor; u velmi dlouhých relací má být nahrazen streamovým čtením nebo malým sidecar metadatovým souborem.
6. Přehled relací v `UserDefaults` je omezen na 100 položek a není databází časových řad. Historie událostí se streamuje z CSV a v UI ponechá posledních 100 relevantních položek; CSV zůstává primárním úložištěm.
7. Název akce a místo mohou být automaticky doplněny obecnými hodnotami a identifikace mikrofonu je volitelná. Úplnost těchto metadat proto závisí na obsluze.
8. Pause/resume typy a stavy jsou v modelu, ale samostatný uživatelský tok pauzy není implementován.
9. PDF export není implementován. Doporučený minimální návrh je číst session/sample/event/gap řádky streamově, vytvořit graf časové řady, souhrn Leq/maxim, seznam alarmů a výpadků a explicitní indikátor úplnosti. Report musí uvádět, že nejde o certifikovaný akustický protokol.
10. IEC 61260-1 se nepoužije, protože nejsou implementovány oktávové ani zlomkooktávové filtry.
11. CSV escapování řeší čárky, uvozovky a nové řádky, ale nebrání interpretaci uživatelských textů začínajících `=`, `+`, `-` nebo `@` jako vzorce po otevření v tabulkovém procesoru. Soubor proto otevírejte jako data nebo před obecnou distribucí doplňte ochranu proti CSV formula injection.
12. Režim DIN obsahuje LAeq,30min, LCpeak, nastavitelné limity, alarmy a historii, ale nebyla ověřena metodika umístění mikrofonu ani další požadavky normy. Výchozí hodnoty 99 dB a 135 dB jsou nastavení aplikace, ne univerzální zákonné limity.

## 9. Certification Limitations

Tento audit je kontrola zdrojového kódu a softwarových testů. Nepředstavuje prohlášení o shodě, typové schválení ani periodické ověření měřidla. Nelze z něj odvodit, že SPL Man nebo konkrétní měřicí sestava splňuje IEC 61672 třídy 1 nebo 2.

Relevantní veřejné popisy norem:

- [IEC 61672-1:2013 – Specifications](https://webstore.iec.ch/en/publication/5708) stanovuje elektroakustické výkonové požadavky na zvukoměry;
- [IEC 61672-2:2013 – Pattern evaluation tests](https://webstore.iec.ch/en/publication/5709) popisuje typové zkoušky;
- [IEC 61672-3:2013 – Periodic tests](https://webstore.iec.ch/en/publication/5710) popisuje periodické zkoušky;
- [IEC 60942:2017 – Sound calibrators](https://webstore.iec.ch/en/publication/30045) se týká výkonových požadavků na akustické kalibrátory;
- [IEC 61260-1:2014 – Octave-band and fractional-octave-band filters](https://webstore.iec.ch/en/publication/5063) se na současnou aplikaci bez pásmových bank nevztahuje;
- [DIN 15905-5:2022-07](https://www.dinmedia.de/en/standard/din-15905-5/352773526) se týká opatření proti ohrožení sluchu publika při elektroakustickém ozvučení.

K prokázání shody je potřeba určit přesnou konfiguraci měřicí sestavy, použít dohledatelně kalibrované komponenty a provést všechny relevantní zkoušky včetně nejistoty měření. Veřejné popisy norem nestačí k ověření všech článků a tolerancí; tyto oblasti jsou proto v matici vedeny jako `NOT VERIFIED`.

## 10. Test Results

### Provedené ověření

```text
$ ./test.sh
Build complete!
SPLMan DSP validation: PASS
SPLMan self-test: PASS
```

Příkaz sestavil spustitelný Swift target a spustil DSP, kalibrační, UI-model, CSV a logging-integrity testy registrované v [`SelfTest.swift:21`](../Sources/SPLMan/Diagnostics/SelfTest.swift#L21). Při sestavení se objevila pouze upozornění na nedostupnou uživatelskou cache SwiftPM v sandboxu; build a testy skončily úspěšně.

### Prošlé skupiny

- A/C vážení na vybraných referenčních frekvencích a sample rate;
- Fast/Slow analytická odezva;
- energetický Leq pro syntetické signály včetně Z;
- nezávislost výsledku na hranicích bufferů;
- maxima, reset, intersample peak a invalidace kontinuity;
- hranice prvního REC intervalu a gap při dopředné i zpětné nespojitosti audio času;
- bounded queue a viditelnost ztrát;
- kalibrační přijímací/odmítací scénáře;
- CSV formát, UTC, session lifecycle, events, gaps, overflow a burst zápis;
- streamové načtení posledních událostí relace a zachování quoted/multiline metadat;
- zrychlená agregace odpovídající 24 hodinám sekundových hodnot.

### Neprovedené nebo neověřené testy

- fyzická akustická kalibrace a kompletní hardwarový řetězec;
- reálný 24hodinový soak celé aplikace;
- disk-full, odpojení úložiště, power loss a tvrdý crash během zápisu;
- fyzické uspání/probuzení macOS, hot-plug a změna sample rate během běhu;
- normativní zkoušky podle IEC 61672-2/-3, IEC 60942 a DIN 15905-5;
- PDF, protože aplikace PDF export neobsahuje.

Automatizované testy v tomto běhu neměly žádné selhání. Uvedené neprovedené testy nejsou považovány za `PASS`.
