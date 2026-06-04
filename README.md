<p align="center">
  <img src="icon/AppIcon-1024.png" width="120" alt="Lidless icon">
</p>

<h1 align="center">Lidless</h1>

<p align="center"><b>Keep your Mac awake with the lid closed.</b><br>
<sub>One menu-bar switch. Auto-off timer + battery-floor so it can’t drain you flat. Notarized, universal, tiny.</sub></p>

<p align="center">
  <img src="assets/menu.png" width="560" alt="Lidless menu-bar dropdown">
</p>

---

Close the lid and your Mac keeps running — finishing a build, an upload, an AI agent, a render — on battery, with no external display and no HDMI dummy plug.

The catch most apps hit: a closed lid sleeps your Mac, and `caffeinate`-based apps (KeepingYouAwake & friends) **can’t** change that — by design. Lidless flips the one setting that can, `pmset disablesleep`, and wraps it in safety nets so it’s safe to forget.

## Why Lidless

- ✦ **Actually works lid-closed** — not just idle-sleep like the caffeine apps.
- 🔒 **Notarized by Apple** — double-click and it opens. No “unidentified developer”, no right-click dance.
- 💻 **Universal** — Apple Silicon **and** Intel, macOS 13+.
- 🪶 **Native & tiny** — a plain menu-bar menu (no custom pop-over UI), one Swift file, no Dock icon, no daemon, no kext, no telemetry.

## Features

- **One switch** — click the star, flip it. ✦ yellow = awake, grey = normal.
- **Auto-off timer** — Off / 1h / 2h, with a live countdown.
- **Battery floor** — auto-off on battery at 10–30% (default 20%) so it never drains flat.
- **Launch at login** — optional, off by default.

## Lidless vs the alternatives

| | **Lidless** | Amphetamine | KeepingYouAwake | `caffeinate` |
|---|:---:|:---:|:---:|:---:|
| Awake, lid closed, no monitor | ✅ | ⚠️ opt-in | ❌ | ❌ |
| On battery | ✅ | ✅ | lid open | ⚠️ |
| Auto-off timer | ✅ | ✅ | ✅ | ❌ |
| Battery-floor cutoff | ✅ | ❌ | ❌ | ❌ |
| Intel **and** Apple Silicon | ✅ | ✅ | ✅ | ✅ |
| Native menu, no custom UI | ✅ | ❌ | ✅ | — |
| Open source | ✅ | ❌ | ✅ | ✅ |

## Install

**Download** the latest [release](../../releases/latest), unzip to `/Applications`, double-click. It’s notarized — it just opens.

**Build from source:**
```sh
git clone https://github.com/sshykvlv/lidless.git
cd lidless && ./install.sh
```
`install.sh` builds a universal app, installs it, and (optionally) sets up a passwordless `pmset` grant so toggling never asks for a password. Without that grant, Lidless simply asks for your admin password via the standard macOS dialog the first time you toggle.

## A note on bags & batteries

With Lidless on, your Mac doesn’t sleep — even closed. On a fanless MacBook Air that means it runs warm with no airflow, and the battery drains. The **battery-floor** cutoff stops it before zero, but don’t leave it sealed in a bag for hours. For work not tied to this machine, a server + `tmux` is the calmer path.

## How it works

Lidless runs `pmset -a disablesleep 1/0`. That needs admin rights, so either:
- a one-time `sudoers` grant (`install.sh`) → silent toggling, or
- the standard macOS admin-password prompt per toggle (no setup).

It reads state back from `pmset -g`. That’s the whole trick.

## Support

Free and open source under [MIT](LICENSE). If it saves your bacon — **L✦ve it? Fuel it** → *(coming soon)*.

---

<sub>Not affiliated with Apple. Use with sense — keeping a Mac awake on battery in an enclosed bag generates heat.</sub>
