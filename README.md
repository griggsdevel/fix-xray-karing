# fix-xray-karing

Правит серверный **Xray (VLESS Reality)** из AmneziaVPN, чтобы к нему подключался
**Karing** и другие клиенты на sing-box.

## Зачем

После установки Xray через AmneziaVPN Karing подключается и сразу отваливается по
таймауту. Причина — в конфиге сервера:

- у клиентов включён `flow: xtls-rprx-vision`, который Karing не переваривает;
- в `realitySettings` стоит ограничение по версии клиента (`minClientVer`).

Скрипт снимает оба ограничения.

## Запуск одной командой

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/griggsdevel/fix-xray-karing/main/fix.sh)
```

Нужен root. Скрипт сам:

1. находит конфиг Xray (`/opt/amnezia/xray/config.json` и другие типовые места);
2. делает резервную копию рядом с конфигом;
3. убирает `flow` у всех клиентов;
4. ставит `"minClientVer": "1.0.0"` и убирает `maxClientVer`;
5. перезапускает контейнер `amnezia-xray` (или службу `xray`);
6. печатает, что изменилось.

## После запуска

В клиенте (Karing / karing-editor) у узла Xray поставь **Flow = нет** — иначе
клиент будет просить vision, которого на сервере больше нет.

## Откат

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/griggsdevel/fix-xray-karing/main/fix.sh) --restore
```

Берёт самый свежий бэкап `config.json.bak.*` и перезапускает Xray.

## Требования

- Linux-сервер с AmneziaVPN (Docker) или обычным Xray
- root, `bash`, `python3` (поставит сам, если нет)
- конфиг Xray доступен на хосте (`/opt/amnezia/xray/config.json`)

## Что внутри нет

В репозитории нет ни адресов серверов, ни доменов, ни UUID, ни ключей, ни токенов.
Все значения скрипт читает из конфига на самом сервере.

## Лицензия

MIT
