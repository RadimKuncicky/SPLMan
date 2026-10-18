# SPL Man

SPL Man is a native macOS sound level meter for live sound workflows, designed
for wide 1920 × 480 displays. It provides calibrated A-, C-, and Z-weighted
measurements, rolling Leq metrics, peak monitoring, CSV recording, and session
history.

## Application preview

![SPL Man application](docs/screenshot.jpg)

Nativní macOS aplikace pro průběžné měření SPL na širokém displeji 1920 × 480.

## Sestavení

Vyžaduje macOS 13 nebo novější a Swift 6:

```sh
./test.sh
./build-app.sh
open dist/SPLMan.app
```

Při prvním spuštění povolte mikrofon. V nastavení vyberte konkrétní zařízení a
kanál, nasaďte 1kHz kalibrátor a stiskněte **Kalibrovat na 94 dB**. Aplikace
ověří stabilitu i koncentraci signálu kolem 1 kHz. Po kalibraci kalibrátor
sejměte a stiskněte **Spustit vstup**, aby časová okna začala bez kalibračního
tónu. Aplikace nikdy automaticky nepřejde na jiné zařízení. Pokud uložený vstup
chybí, měření zůstane zastavené.

## Měření

- LAeq, LCeq a LZeq za dokončenou sekundu, včetně LAFmax, LASmax a LCpeak
  pro stejný sekundový interval
- LAeq za klouzavých 1, 10, 15 a 30 minut a LCeq za klouzavých 1, 10 a 30 minut;
  hodnota se zobrazí až po naplnění
  celého příslušného časového okna
- SPL A Slow a SPL C Slow
- LCpeak pro krátké C-vážené špičky
- LAFmax, tedy nejvyšší A-vážená hodnota s rychlou odezvou od spuštění vstupu
- C−A u LCeq 1 min, LCeq 10 min a SPL C Slow

Hodnoty LAFmax a LCpeak jsou maxima od spuštění vstupu a vynulují se jeho
restartováním. LCpeak nemá odpovídající A-váženou špičkovou metriku, proto se
u něj C−A nezobrazuje.

## Záznam, relace a historie

Po spuštění a kalibraci vstupu lze tlačítkem Record vedle Nastavení zvolit CSV
soubor a začít ukládat měření. Během záznamu se tlačítko změní na Stop a
zobrazuje se uplynulý čas. Před uložením lze vyplnit název akce, místo, poznámku
a identifikaci mikrofonu. Poslední relace a jejich stav jsou dostupné v historii.
U každé relace lze zobrazit posledních 100 uložených událostí, výpadků a chyb.

CSV používá UTC časové značky a obsahuje identifikátor i stav relace, počty
zpracovaných framů a sekund, sekundové i dlouhodobé metriky a identifikaci
vstupu, kanálu a kalibrace. Vedle vzorků zapisuje stavové události, alarmy,
výpadky a chyby. Neplatný nebo chybějící interval se nenahrazuje poslední
hodnotou; je uchován jako neplatný vzorek nebo explicitní `gap`/`error` řádek.
První audio sekunda, která začala před stiskem Record, se nezapíše jako platný
vzorek. Hodnoty, jejichž časové okno ještě není naplněné, mají v CSV prázdné
pole.

Záznam se bezpečně ukončí při stisku Stop, změně nebo odpojení vstupu,
kalibraci, chybě zápisu a ukončení aplikace. Po novém spuštění aplikace se
záznam automaticky neobnovuje.

Volitelný koncertní alarm sleduje LAeq 30 min a sekundový LCpeak. Výchozí
orientační hodnoty jsou 99 dB a 135 dB a lze je změnit v nastavení. Překročení
i návrat pod limit se zapisují jako události relace.

Výchozí barevný přechod je 95–100 dB(A) a 105–110 dB(C). Jde o nastavitelné
vizuální upozornění pro live sound, nikoli o hygienický nebo právní limit.

Kalibrace jedním bodem ani softwarové testy nenahrazují typové nebo periodické
ověření celé měřicí sestavy podle IEC 61672. Koncertní alarm není deklarací
shody s DIN 15905-5.
