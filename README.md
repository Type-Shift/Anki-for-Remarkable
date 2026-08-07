# Offline Anki for reMarkable 1

Review Anki flashcards **offline** on a reMarkable 1, syncing when the tablet
reconnects to WiFi.

The existing [RmAnki](https://github.com/Jayy001/RmAnki) is an online-only
wrapper around AnkiWeb's web reviewer — every card is fetched live, and a
dropped connection silently loses reviews. This project makes the tablet
usable without a network.

## How it works

The PC is the brain; the tablet is a review terminal.

```
PC  --- batch.json --->  tablet      questions, answers, button labels,
                                     opaque scheduling states
tablet --- queue.json ---> PC        card_id, rating, time taken
PC applies via Anki's real library, then syncs onward
```

The tablet holds no scheduler and speaks no sync protocol, so it cannot
corrupt the collection. Scheduling states are passed through opaquely — the
same model AnkiWeb's own reviewer uses.

## Layout

| Path | What |
|---|---|
| `pc/rmanki.py` | PC-side tool: `export`, `apply`, `selftest` |
| `device/` | Tablet app (C++/QML), derived from RmAnki |
| `.github/workflows/build-rm1.yml` | Cross-compiles the ARM binary in CI |

## PC side

Runs on Anki's bundled Python — nothing to install.

```powershell
$py = "$env:LOCALAPPDATA\AnkiProgramFiles\.venv\Scripts\python.exe"

# prove the round-trip works, against a throwaway collection
& $py pc\rmanki.py selftest

# pull due cards for the tablet
& $py pc\rmanki.py export --collection "path\to\collection.anki2" `
      --deck "GCSE" --limit 100 --out batch.json

# apply what you reviewed offline
& $py pc\rmanki.py apply --collection "path\to\collection.anki2" `
      --queue queue.json
```

**Close Anki first** when pointing at a real collection — it holds a lock.

## Device side

Built in GitHub Actions, because the development machine is a locked-down
school PC with no Linux environment. CI fetches reMarkable's official Codex
toolchain (3.27.0.97 / rm1) and produces an ARM binary as a build artifact.

Deploy:

```
scp anki_rm1_3.27.0.97 root@<tablet-ip>:/home/root/anki
ssh root@<tablet-ip>
systemctl stop xochitl
chmod +x /home/root/anki
QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS="rotate=180" QT_QUICK_BACKEND=epaper \
  setsid nohup /home/root/anki -platform epaper </dev/null >/home/root/anki.log 2>&1 &
```

`setsid` matters — plain `nohup ... &` does not survive a scripted SSH
disconnect, because dropbear signals the whole session process group.

To get the notes UI back: `systemctl start xochitl`.

## Licence

`device/` derives from RmAnki and inherits its licence (see `device/LICENSE`).

See [NOTES.md](NOTES.md) for measured device constraints, verified API
behaviour, and the architectures that were considered and rejected.
