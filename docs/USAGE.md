# Use Windows VM

[← Home](../README.md) · [Install](INSTALLATION.md) · [Update and back up](UPDATING.md)

## Open a saved machine

Select it in the library and click **Start**. If it is already running, **Open Windows** reconnects to its current session. The ISO is only needed for installation and recovery; your Windows disk persists independently.

Closing the console window disconnects the display. It does not shut down the guest. Quitting the app can leave guests running after confirmation. Use a normal Windows shutdown before updating the app or doing storage maintenance.

## Find the controls

Hover over the tab at the top centre of the console. Click **VM Controls** to open the floating island; it collapses when the pointer leaves. **Hide** closes it immediately and **Move** lets you reposition the window. **Options** contains display details, media, and power actions.

| Action | Behaviour |
| --- | --- |
| Click the guest | Focus the keyboard and pointer |
| **Control–Option** | Release input back to macOS |
| Command key while focused | Maps to the Windows key |
| Pause / Resume | Temporarily stop / continue guest execution; this is not a saved snapshot |
| Shut down | Requests a normal ACPI shutdown; Windows may take time or ask you to finish work |
| Reset | Reboots virtual hardware after confirmation |
| Force stop | Stops the guest after confirmation; unsaved work can be lost |
| Reconnect display | Recreates the console connection without restarting Windows |
| Full screen | Uses the console's native macOS full-screen window |
| Mount / Eject ISO | Changes the one removable virtual CD/DVD drive |

## Resolution, colour, and capture

**Match Mac Retina** advertises the host display's physical dimensions at VM startup. The console fits the whole guest picture proportionally when its aspect ratio differs from the window. The SPICE agent and VirtIO serial driver are needed for automatic guest resize requests. An older VM may need a complete shutdown/start after adding the agent channel.

Metal presents through a 10-bit surface, but the current guest scanout is **8-bit SDR tagged sRGB**. This is not HDR support. The host display's refresh rate is a presentation target; it does not establish guest frame delivery or game performance.

For games, **Options → Capture Mouse for Games** enables relative pointer movement after you click the guest. **Control–Option** releases capture.

## Choose a graphics mode

Shut down the guest before changing **Settings → Devices**.

| Mode | Use |
| --- | --- |
| Compatibility (VNC) | Original display-only path and older running sessions |
| SPICE / Metal (display only) | Metal presentation with the display-only VirtIO GPU; a sensible initial choice |
| Metal and Direct3D 11 (experimental) | VirtIO 3D with DXMT and a separate rendering worker; requires the matching signed ARM64 3D guest driver |

Before switching an existing guest from display-only to 3D, back up its stopped `.wvm` package and follow the [upstream uninstall/migration procedure](https://docs.getutm.app/guest-support/windows/#directx-graphics). If the console goes black, see [troubleshooting](TROUBLESHOOTING.md). Do not infer DirectX 12, broad game support, or measured frame rates from the mode name.

## Manage storage

Stop the guest before CPU/RAM/network changes, disk expansion, disk import/export, or duplication. Increasing capacity grows the QCOW2 disk; extend the Windows partition in **Disk Management** afterwards. Shrinking is unsupported.

**Export disk** creates a standalone QCOW2 image. It does not include firmware variables or TPM state. **Duplicate** copies the whole stopped VM and assigns a new app identity. Imported disks must be self-contained, without external backing files.

For a restorable backup, copy the whole stopped `.wvm` package. Its TPM and firmware state matter, especially with guest encryption. Save Windows recovery keys separately through Windows' normal tools. Removal moves a stopped VM to the Mac's Trash; inspect the Trash before emptying it.

## Networking and privacy

Networking uses QEMU user-mode NAT when enabled. The app does not create host port forwards or shared host directories. Display and control connections use private Unix sockets. Clipboard and SPICE agent file transfer are disabled. The app has no telemetry service or app account. Windows and the software inside it have their own network behaviour and privacy settings.
