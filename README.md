# Offline Anki for reMarkable 1

Review Anki flashcards **offline** on a reMarkable 1, syncing when the tablet
reconnects. Includes an in-app Wi-Fi panel and a boot-time launcher, so the
tablet is usable without a computer attached.

The existing [RmAnki](https://github.com/Jayy001/RmAnki) is an online-only
wrapper around AnkiWeb's web reviewer: every card is fetched live, and a
dropped connection silently loses reviews.

## How it works

The PC is the brain; the tablet is a review terminal.

```
PC  --- batch.json --->  tablet      questions, answers, button labels,
                                     opaque scheduling states
tablet --- queue.json ---> PC        card_id, rating, time taken
PC applies via Anki's real library, then syncs onward
```

The tablet holds no scheduler and speaks no sync protocol, so it cannot
corrupt the collection. Answers are written with an atomic rename and fsync
*before* the screen advances, so an answer you see accepted is already on disk.

## Everyday use

```powershell
# review what you did offline, and load the next batch
.\pc\sync.ps1

# against your real collection (close Anki first -- it locks the file)
.\pc\sync.ps1 -Collection "$env:APPDATA\Anki2\User 1\collection.anki2"

# a single deck instead of everything due
.\pc\sync.ps1 -Deck "GCSE::Physics"
```

The tablet is found by **MAC address**, not a fixed IP, so this works on
school Wi-Fi, at home, or on a PC-hosted hotspot with no edits.

## Installing / updating the app

```powershell
.\pc\deploy.ps1                    # fetch latest CI build, install, run
.\pc\deploy.ps1 -InstallLauncher   # also start Anki at boot
.\pc\deploy.ps1 -RemoveLauncher    # back to a stock reMarkable
.\pc\ci-status.ps1                 # check the last build
```

Builds run in GitHub Actions because the development machine is a locked-down
school PC with no Linux environment. CI fetches reMarkable's official Codex
toolchain (3.27.0.97 / rm1) and verifies the output really is an ARM binary.

## On the tablet

- **Home** — choose *Study Anki* or *reMarkable Notes*
- **Deck list** — real Anki decks, `Parent::Child` indented, parents collapsible
- **Wi-Fi panel** — bottom-right; scan, join, forget, disconnect. Needed
  because running a Qt epaper app requires stopping xochitl, which takes
  reMarkable's own settings UI with it
- **Finished screen** — says whether answers are still waiting for the PC
- New batches pushed by `sync.ps1` appear **live**, without a restart

Leaving via *reMarkable Notes* hands the screen back to xochitl. Getting back
into Anki needs a **reboot** — xochitl offers no way to launch another app,
and both want the framebuffer.

## Safety

The launcher unit is ordered `After=xochitl.service` and deliberately has **no
`Requires=`**. xochitl boots first and Anki then takes over, so a broken or
missing binary can never lock you out — the tablet just boots as a normal
reMarkable.

Escape hatch, if it is ever needed:

```
ssh root@<tablet-ip> "systemctl disable --now anki-launcher; systemctl start xochitl"
```

## Licence

`device/` derives from RmAnki and inherits its licence (`device/LICENSE`).

See [NOTES.md](NOTES.md) for measured device constraints, verified API
behaviour, and the bugs worth remembering.
