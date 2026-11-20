# Ядро Pentagon-4096 для Karabas Go / Mini / Mini G

[English version](README.md)

Pentagon-4096 для плат семейства Karabas Go (Xilinx Spartan-6 XC6SLX25). Оригинал — плата [AleksandrDneprCity/Pentagon-4096](https://github.com/AleksandrDneprCity/Pentagon-4096) (MainBoard 10.7.1, TopBoard 5.3.1): дискретная логика без HDL, поэтому ядро написано по её README и схеме. Разбор схемы (порты, страницы памяти, видеорежимы, палитра, растр, INT, BIOS v4.2) — в [docs/HW.md](docs/HW.md).

| Плата | Файл ядра | Видео | Звук |
|---|---|---|---|
| Karabas Go | `p4096.kg` | VGA | ЦАП I2S (PCM5102) |
| Karabas Mini | `p4096.kg` | HDMI | HDMI, аналоговый выход (сигма-дельта) |
| Karabas Mini G | `p4096.kg` | HDMI | HDMI, ЦАП I2S |

Файл ядра — в `src/`. ПЗУ входят в него (`core.json` "roms", их грузит прошивка): Gluk Reset Service, TR-DOS 5.03, меню 128K и BASIC 48, ПЗУ +3 4.1, BIOS v4.2 Pentagon-4096 и ПЗУ GS 1.05b.

Состояние: сборка 26112020. На плате Mini G проверены: машина, все видеорежимы, схемы памяти, тесты BIOS v4.2, TR-DOS с образов, CF-карта, GS, OPL4 и MIDI. Сборки Go и Mini на плате не запускались.

## Возможности

- **Машина:** Z80 (z80-silicon) на 3,5 / 7 / 14 МГц, растр и INT Пентагона (или «фирменный» вариант, с перемычкой XJ3), ожидания Турбо 14 как в оригинале (WAITP) или без них.
- **Память:** 4 МБ ОЗУ, семь схем расширения порта FC37 (128K, Pentagon 1M, Profi 1M, 1FFD 512K, KAY 4M, Profi + Pentagon, Profi + 1FFD), защёлка D5 порта 7FFD, режим +3, статическое ОЗУ вместо страниц ПЗУ, кэш FB / 7B, многозадачность (аппаратная часть), ловушка IN / OUT.
- **Видео:** стандартный экран, 16 colors, 512 × 192 (моно или цвет), мультиколор 8 × 1, 384 × 304, FlashColor, GigaScreen, палитра 16 из 4096 цветов; удвоение строк до 720 × 576 (или 768 × 608 со всем бордюром), 48,8 Гц.
- **BIOS:** работает BIOS v4.2 (Boot = BIOS) с тестом ОЗУ и Setup; без него то, что задаёт Setup, задаёт OSD (значения портов BIOS FC37..FF37 при сбросе).
- **Диски:** ВГ93 с четырьмя образами TRD (A..D) на SD1; Nemo IDE на CF-карте платы или на образах HDF на SD1 (Master, Slave).
- **Звук:** TurboSound (два AY), бипер и магнитофон, SoundDrive / Covox, **General Sound** (порты BB / B3, 2 МБ), **OPL4** (ZXM-MoonSound: FM и волновой синтез с ПЗУ YRW801, порты C4..C7 и 7E / 7F), MIDI-синтезатор платы на порту A AY (`PLAY "Y1..."` в BASIC 128K); на Mini / Mini G его звук и линейный вход возвращаются в микшер через АЦП.
- **Часы:** RTC платы как CMOS MC146818 Gluk (порты EFF7 / DFF7 / BFF7).
- **Управление:** USB-клавиатура, два джойстика (Kempston, Sinclair 1 / 2, Cursor, QAOP), Kempston-мышь.

Не сделано: RS-232 и ESP8266, DivMMC / DivIDE, принтер, запись флеш-ПЗУ обратно на SD-карту (копия в SDRAM живёт до выключения), меню задач многозадачности.

## Начало работы

1. Скопируйте `p4096.kg` (один файл для Go, Mini и Mini G) в корень SD-карты прошивки.
2. Создайте на SD-карте папку `/p4096` для образов дисков (`.trd`, `.hdf`).
3. ПЗУ OPL4 `yrw801.rom` (2 МБ, в ядро не входит): `/p4096/yrw801.rom`; ядро берёт его и из `/baseconf` или `/tsconf`.
4. Выберите Pentagon-4096 в меню ядер: запустится Gluk Reset Service. Образ TRD подключается по **Menu+F5** (Disk A).

«Menu» — клавиша Windows на клавиатуре. **F11** — кнопка Magic (NMI), **F12** — сброс.

## Меню OSD

| Страница | Пункт | Значения | Клавиша |
|---|---|---|---|
| | Turbo | Off / 7 MHz / 14 MHz | Menu+F2 |
| | INT | Pentagon / Pent -2T / Firm / Firm -2T | |
| | Joystick L, Joystick R | Kempston / Sinclair1 / Sinclair2 / Cursor / QAOPM / QAOPS | |
| | Mouse | On / Off | |
| | Magic | NMI | F11 |
| | Reset | | F12 |
| Video | 512 Ink | цвет INK режима 512 × 192 моно (16 цветов) | |
| Video | 512 mode, FlashColor, GigaScreen | значения FE37 при сбросе | |
| Video | Palette | On / Off | |
| Video | Output | 720x576 / 768x608 | |
| Video | VGA Sync (Go) | -H -V / +H -V / -H +V / +H +V | |
| System | Turbo 14 | Original / No wait | |
| System | Memory | схемы FC37 | |
| System | 7FFD D5 | Lock / Memory | |
| System | +3 mode, Multitask | Off / On | |
| System | Boot | Direct / BIOS | |
| System | Reset to | Gluk / Menu-128 / TR-DOS / BASIC 48 | |
| Sound | SoundDrive, General Snd, OPL4, OPL4 Interp | On / Off | |
| Sound | OPL4 ROM | файл YRW801 | |
| Disks | Disk A..D | образы TRD | Menu+F5 / Menu+F6 (A / B) |
| Disks | HDD Master | CF card / Image | |
| Disks | HDF0, HDF1 | образы HDF (Master, Slave) | |

Пункты System применяются при следующем сбросе.

## Порты

| Устройство | Порты |
|---|---|
| 128K, расширенная память | 7FFD, DFFD, 1FFD, EFF7 |
| BIOS | FC37 (схема памяти), FD37 (статическое ОЗУ вместо ПЗУ), FE37 (видео), FF37 (ПЗУ BIOS, защёлка Gluk, запись палитры, флеш) |
| Палитра | запись в xxFF при FF37 D5 = 1 (цвет — в данных и старших битах адреса, HW.md) |
| Порт атрибутов | чтение FF (вне TR-DOS) |
| TR-DOS (ВГ93) | 1F, 3F, 5F, 7F, FF (только при включённом TR-DOS) |
| Nemo IDE | A1 = A2 = 0 (не в TR-DOS): A0 = 0 — регистры накопителя (A7..A5), A0 = 1 (11) — старший байт данных |
| CMOS (MC146818) | EFF7 (D7 = вкл.), DFF7 (адрес), BFF7 (данные) |
| Kempston-джойстик / мышь | 1F / FBDF (x), FFDF (y), FADF (кнопки) |
| SoundDrive / Covox | 0F, 1F, 4F, 5F / FB |
| General Sound | BB (команда / состояние), B3 (данные) |
| OPL4 | C4 / C5 — FM, банк 0, C6 / C7 — FM, банк 1, 7E / 7F — волновой синтез (не в TR-DOS) |

Пока OPL4 включён, его порты C4 / C6 / 7E (A0 = 0) не попадают в порт FE.

## Сборка

Клонировать с `--recursive` (подмодуль `modules`). ISE 14.7: `cd src && make go`, `make mini`, `make minig` (по очереди: платы делят `xst/`). Топы Go и Mini делает из топа Mini G `src/tools/mktop.py`. Симуляции (Verilator, от секунд до минуты): `make sim-video`, `sim-modes`, `sim-int`, `sim-boot`; эталонная модель картинки — `src/tools/p4096_vmodel.py`. План и заметки — [docs/PLAN.md](docs/PLAN.md).

## Лицензия

GPL v3 ([LICENSE](LICENSE)). Плата Pentagon-4096 и её BIOS: (c) AleksandrDneprCity. z80-silicon: GPL-3 (`src/rtl/z80-silicon/LICENSE`); opl3_fpga: LGPL-3 (`src/rtl/sound/opl4/opl3/COPYING.LESSER`); wd1793 из MiSTer: GPL. ПЗУ 128K, 48K и +3 — (c) Amstrad, которая разрешает распространять их с эмуляторами; Gluk Reset Service, TR-DOS и ПЗУ GS принадлежат их авторам. Импортированные файлы сохраняют лицензионные заголовки авторов.
