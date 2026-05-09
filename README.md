# sing-box-drover (tray controller for sing-box on Windows)

sing-box-drover is a lightweight utility for Windows that runs the original `sing-box` in the background and provides
minimal, convenient control from the system tray:

- Tray icon reflects the current mode: idle, system proxy enabled, or TUN active
- Click on the tray icon to toggle system proxy
- Toggle TUN mode via context menu (requests elevation if needed)
- Switch outbound selectors via context menu

The goal is to keep the full power of a native `sing-box` config while adding just enough integration with Windows,
without turning into another heavy all-in-one client.

## Screenshot

<img alt="sing-box-drover screenshot" height="235" src="./screenshot.png?v=2"/>

## About sing-box and why this tool exists

sing-box is one of the main proxy/VPN engines used inside many modern clients. It is powerful and flexible but is
designed as a console application with JSON configuration files and no GUI. This is usually inconvenient for non-technical users.

There are many GUI clients built on top of sing-box, but they usually:

- do not expose all features of the original config format
- are large and overcomplicated for simple use cases
- ship their own embedded, sometimes outdated, sing-box binaries

sing-box-drover takes a different approach:

- you download and use the official `sing-box.exe` yourself
- you keep your normal sing-box config as-is
- the program only adds a small tray UI on top

This is close to how the official client works: full control stays in the config, and the UI is only a thin layer on
top.

## Not implemented

- No profile/config switching: only one sing-box config file is used (path is set in the program config).
- No Clash Mode switcher.

## Installation

1. Download sing-box-drover. Get the latest version of the program from
   the [latest release page](https://github.com/hdrover/sing-box-drover/releases/latest).

2. Download the official sing-box for Windows from the upstream project:  
   <https://github.com/SagerNet/sing-box/releases>  
   Choose the archive with `windows-amd64` in the filename.

3. Place files
    - Put `sing-box-drover.exe` (and its config file from the archive) into any folder.
    - Put `sing-box.exe` into the same folder, or specify another folder via `sb-dir` (see below).
    - Prepare your sing-box config file and point the program to it.

After that, run `sing-box-drover.exe`. A tray icon should appear.

## sing-box configuration requirements

sing-box-drover expects some specific fields in the sing-box config.

### Required inbound

There must be an inbound of type `mixed`. The program reads its `listen` and `listen_port` and uses them to configure
the Windows system proxy:

```jsonc
{
  // ...
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in", // any tag, not used by the program
      "listen": "127.0.0.1",
      "listen_port": 1080 // can be changed
    }
  ],
  // ...
}
```

The tag value is ignored by the program; only the type and address/port are important.

If your config also contains a `tun` inbound, the TUN toggle will appear in the tray context menu.

### Required Clash API section

To allow outbound switching from the tray menu, `experimental.clash_api` must be enabled:

```jsonc
{
  // ...
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090", // can be changed
      "secret": "change-me" // any non-empty string
    }
  },
  // ...
}
```

- `external_controller` — address for the Clash-compatible API.
- `secret` — API token.

If this section is missing but your config has selectors, the program will add it automatically.

### Selectors for outbound switching (optional)

In your `outbounds` section, define one or more `selector` outbounds. They will appear in the tray menu:

```jsonc
{
  // ...
  "outbounds": [
    {
      "type": "selector",
      "tag": "proxy-select",
      "outbounds": [
        "Proxy1",
        "Proxy2"
      ],
      "default": "Proxy1",
      "interrupt_exist_connections": true
    },
    // plus your normal outbounds
  ],
  // ...
}
```

The selector `tag` becomes the menu title, `outbounds` become menu items, and `default` sets the initial selection.

## Program configuration

The program uses a simple INI-style config file included in the archive. The default content looks like this:

```ini
[sing-box-drover]
sb-dir =
sb-config-file = config.json
tun-start-mode = off
system-proxy-auto = 1
; Selector menu layout: "auto", "flat" or "nested"
selector-menu-layout = auto
selector-persist = 1
```

Parameters:

- `sb-dir` — path to the folder with `sing-box.exe`.  
  If empty, the program searches for `sing-box.exe` in its own folder.

- `sb-config-file` — sing-box config file (JSON or `.bpf`).  
  You can specify just a file name or an absolute path.

- `tun-start-mode` — whether to enable TUN mode on program start (requires a `tun` inbound in your sing-box config):
    - `off` — start without TUN; you can enable it later from the tray menu.
    - `on` — enable TUN immediately on start.

- `system-proxy-auto` — automatic system proxy management:
    - `1` — enable on start, disable on exit.
    - `0` — manual toggling only.

- `selector-menu-layout` — layout of selectors in the tray menu:
    - `auto` — picks `nested` when there are many items, otherwise `flat`.
    - `flat` — each selector name is shown as a disabled header, with its options as radio items below, separated by a divider.
    - `nested` — each selector is shown as a submenu containing its options.

- `selector-persist` — remember selector choices across program restarts:
    - `1` — restore the last selected option for each selector on the next launch (default).
    - `0` — start with the `default` from the sing-box config every time.

The rest of the behavior is fully controlled by your sing-box configuration.

## BPF profiles

In addition to plain JSON configs, sing-box-drover supports `.bpf` profile files — the binary format used by the
official sing-box clients (SFA for Android, SFI/SFM for Apple platforms) for profile export/import.

For remote BPF profiles (profiles with a URL and auto-update enabled), sing-box-drover automatically checks for config updates.
The program checks for updates about one minute after launch and then periodically based on the interval from the profile (at least every 15 minutes).
The running sing-box instance is not restarted automatically — the new config will be used on the next program launch.

### About the format

`.bpf` is an undocumented binary container. There is no specification published by the sing-box project —
the format is defined only by the source code in the `libbox` package of the sing-box repository.

A `.bpf` file consists of a 1-byte message type, a 1-byte version, and a gzip-compressed payload containing the profile
name, type, JSON config, and (for remote profiles) the URL, auto-update flag, update interval, and last-updated timestamp.

The easiest way to obtain a `.bpf` file is to export a profile from an official sing-box client.
To create one from scratch or edit an existing profile in the browser, use
[sing-box-bpf-editor](https://hdrover.github.io/sing-box-bpf-editor/) — it runs fully client-side.
