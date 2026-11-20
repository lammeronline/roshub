# ROSHub

Модульная экосистема скриптов для MikroTik RouterOS 7.

- **Ядро** — менеджер модулей: установка, удаление и обновление с GitHub, журнал, конфигурация.
- **Уведомления** — шина событий и отдельные каналы: Telegram, e-mail, ntfy, webhook, WhatsApp, Viber.
- **Управление через Telegram** — команды модулей, белый список пользователей, подтверждение опасных действий.
- **Health** — мониторинг роутера с порогами и гистерезисом.
- **WireGuard и трафик** — контроль туннелей, переключение на прямой канал, история падений, учёт трафика.

> Статус: ядро и все основные модули реализованы и проверены на тестовом стенде (CHR), этапы 0-8 из
> [docs/PLAN.md](docs/PLAN.md) пройдены. WhatsApp и Viber не реализованы — требуют сторонний шлюз/аккаунт.
> Установка: `/tool fetch url="https://raw.githubusercontent.com/lammeronline/roshub/main/bootstrap.rsc" dst-path=bootstrap.rsc; /import bootstrap.rsc`,
> дальше модули через `rhPkgInstall`.

Требования: RouterOS 7.25+.

Секреты (токены ботов, пароли) хранятся только на роутере и в репозиторий не попадают: создайте
скрипт `rh-secrets` вручную (`:global rhSecrets {"tg.token"="..."; ...}`) и добавьте ему расписание
`start-time=startup interval=0`, иначе после перезагрузки роутера секреты не подгрузятся сами, пока
скрипт не будет запущен вручную:
```
/system scheduler add name=rh-secrets start-time=startup interval=0 on-event="/system script run rh-secrets"
```
