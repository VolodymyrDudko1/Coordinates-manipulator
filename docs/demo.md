# Демо на захисті: перемикання між лабораторними

Одна точка входу — `scripts/lab.sh`. Одночасно працює **лише одна** лабораторна:
перед запуском іншої попередня вимикається автоматично (економія RAM).

| Команда | Що робить |
|---|---|
| `./scripts/lab.sh status` | що розгорнуто зараз + RAM хоста, minikube і найбільші pod-и |
| `./scripts/lab.sh demo 3` | покрокове демо Lab 3 з чистого стану (16 кроків) |
| `./scripts/lab.sh demo 4` | покрокове демо Lab 4 з чистого стану (16 кроків) |
| `./scripts/lab.sh demo 5` | покрокове демо Lab 5 — Argo CD (16 кроків, назви з номерами пунктів завдання) |
| `./scripts/lab.sh demo 6` | покрокове демо Lab 6 — canary з Argo Rollouts (11 кроків) |
| `./scripts/lab.sh demo 7` | покрокове демо Lab 7 — метрики, логи, дашборд, відкат за метриками (13 кроків) |
| `./scripts/lab.sh demo 4 --list` | перелік кроків (підглянути план) |
| `./scripts/lab.sh demo 4 --from 9` | продовжити з кроку 9 (після `q` або питання викладача) |
| `./scripts/lab.sh demo 3 --yes` | без пауз — репетиція перед захистом (~3 хв на лабу) |
| `./scripts/lab.sh up 4 [values-файл]` | просто розгорнути лабу в робочому стані |
| `./scripts/lab.sh down [N\|all]` | вимкнути лабу N або всі |
| `./scripts/lab.sh sleep [--docker]` | вимкнути все й зупинити minikube; `--docker` — ще й Docker Desktop (якщо він активний) |
| `./scripts/lab.sh wake` | запустити minikube (~1 хв; Docker Desktop — лише якщо активний контекст `desktop-linux`) |

У кожному кроці демо видно команди (`$ ...`) і підказку «Очікую:» — що сказати/показати.
Клавіші: **Enter** — виконати, **s** — пропустити, **q** — вийти (скрипт підкаже `--from N`).

Деталі:
- Запити до застосунку йдуть через `kubectl port-forward` до ingress-nginx на `127.0.0.1:18080`
  з потрібним заголовком `Host` — без `minikube tunnel` і sudo. У браузері:
  `http://portal.local:18080/` (у `/etc/hosts` має бути `127.0.0.1 portal.local`).
- Lab 3, крок 11: rolling update під фоновим трафіком; у кінці підсумок — скільки відповідей
  кожної версії і **0 помилок**. Другий термінал не потрібен.
- Lab 4, крок 9: upgrade з `hooks.preUpgrade.deletePolicy=before-hook-creation`, щоб показати логи
  pre-upgrade Job; у кроці 10 (prod) Job видаляється після успіху — видно обидві політики.
- Веб-клієнт Django — окремо, в іншому терміналі: `./scripts/client-up.sh lab3|lab4`.
- Lab 5 (Argo CD): демо **комітить і пушить** у `labs-5-7` (реліз, selfHeal, битий тег, revert) —
  `git push` має працювати з терміналу. Перед демо скрипт сам повертає Git у стартовий стан
  (`selfHeal: false`, робочий тег) і пушить це. Підготовка: [`argocd-commands.md`](argocd-commands.md).
  UI Argo CD: `http://localhost:18090` (port-forward тримає скрипт).
- Argo CD не видаляється між демо: для Lab 3/4 його pod-и масштабуються до 0, для Lab 5 — назад (~15 с).
- Нові лабораторні (6–7) додаються файлами `scripts/labs/labN.sh`
  з функціями `labN_title / _is_up / _up / _down / _prepare / _steps`.

## Порядок на захисті (з дзвінком у Meet)

```bash
./scripts/lab.sh wake          # за 2–3 хв до початку
./scripts/lab.sh demo 3        # Lab 3
./scripts/lab.sh demo 4        # Lab 4 (Lab 3 вимкнеться сам)
./scripts/lab.sh demo 5        # Lab 5 (Lab 4 вимкнеться, Argo CD прокинеться)
./scripts/lab.sh demo 6        # Lab 6 (root-lab5 -> root-lab6, Argo CD лишається)
./scripts/lab.sh demo 7        # Lab 7 (root-lab6 -> root-lab7 + моніторинг; перший запуск ~3-5 хв)
./scripts/lab.sh sleep --docker   # після захисту — повернути RAM
```

Поради щодо RAM (ноутбук 7.5 GiB; Docker Engine без окремої VM, minikube `--memory` ≈ 4.5 GiB — це стеля, а не резерв;
з Argo CD minikube займає ~1.4 GiB, виміряно):
- закрити IDE, Telegram, зайві вкладки; Meet — у браузері, камеру вимкнути за можливості;
- `metrics-server` потрібен лише для `kubectl top` (Lab 3, крок 5): `minikube addons disable metrics-server` економить ~50 MiB;
- з Docker Engine (`docker-ce`) `minikube stop` повертає пам'ять одразу; з Docker Desktop VM — лише `lab.sh sleep --docker`.
