# Set up SupersEmu on your Mac mini

The server runs on the Mac mini. Your Mac, iPhone and iPad pair with it, download games, and play them on the device.
Steps marked **[untested]** haven't been run on real hardware yet. Please report what happens.

## 1. Before you start
- macOS 26, signed in as an admin.
- Storage: a 256 GB Mac mini fills up quickly with disc games. An external drive works for the library.
- Install Homebrew, then run `brew install xcodegen cmake ninja` and install Xcode from the App Store.

## 2. Install the app
Until the notarized Mac build exists (in progress), build it from source:

```bash
git clone https://github.com/Chadillac6/SupersEmu.git && cd SupersEmu
git submodule update --init --depth 1
./scripts/build.sh
ditto build/mac/Build/Products/Debug/SupersEmu.app /Applications/SupersEmu.app
```

## 3. Turn on the server
1. Open SupersEmu and click **Server Mode**.
2. To try it right away, click **Start Server for This Session** (port 8488). It stops when you quit the app.
3. To keep it running, click **Register Boot Daemon**, then **Open Login Items Settings** and allow it. The server then runs on port 8487 at boot, even before anyone logs in. **[untested]**
4. Server data lives in `/Library/Application Support/SupersEmu Server`.
5. A **SupersEmu Server** icon appears in the menu bar and shows the server status. Use it to open the Server window or jump straight to its Add Games, Review Needed, BIOS and Storage sections. Hide or show the icon from the Server window.

## 4. Remote Access
1. In Server Mode, open **Remote Access**.
2. Create a Cloudflare API token from the **Edit zone DNS** template and limit it to the
   `supersemu.com` zone. Paste it into the panel; the token is stored locally on the server.
3. In the Eero app, open **Settings → Network settings → Reservations & port forwarding**, reserve
   the Mac mini, and forward TCP ports **443** and **80** to it.
4. Click **Turn On**. macOS asks for the administrator password once. Caddy obtains and renews the
   public HTTPS certificate, and Cloudflare DNS is kept current automatically.
5. The public address is `https://games.supersemu.com`. Admin APIs remain private; only player
   routes are available through the public listener.

Use **Turn Off** in the same panel to disable Remote Access. The optional purge removes its saved
Cloudflare token and local DDNS state as well.

## 5. Add games and BIOS files
Everything below is in the Server Mode window; no Terminal needed.

- **Add Games**: drag files, folders or .zip archives anywhere onto the window, or click **Add Games…**. Messy
  folders are fine: the server sorts games by console, skips duplicates and shows a summary (imported, duplicates,
  review needed, unsupported). Files are copied to the server, so your originals are never moved or deleted.
- **Open Incoming Folder** opens the server's drop folder in Finder. Anything you copy there is imported when you
  click **Scan Incoming**.
- **Review Needed** lists what couldn't be sorted and why: a .cue whose track files are missing, a ROM whose console
  couldn't be told apart, an unsupported format such as .pbp. Fixes: **Pick Console** for a single cartridge ROM,
  **Retry** after dropping the missing files again, or **Delete**.
- **BIOS**: PS1 and Sega CD games need BIOS files from your own consoles. Drop them on the BIOS screen; it shows,
  per console, which files are present, missing or wrong, and which games need them. SupersEmu never downloads or
  includes BIOS files. **[untested with real BIOS dumps]**
- **From another Mac**: on a Mac paired as an admin device, open Server Mode and choose **Paired server**. Adding
  games, Review Needed, BIOS and Storage work the same way; files are uploaded over the paired connection
  (up to 4 GB per file).

## 6. Storage and external drives
- The **Storage** screen shows where the library is and how much space is free.
- **Move Library…** moves games, BIOS, artwork and Incoming to another folder or an external drive. It copies
  everything, verifies every file, switches over, and only then removes the old copy. Settings, users and saves stay
  in the data folder. **Move Back to Data Folder…** undoes it.
- If the drive isn't connected when the Mac mini starts, the server still runs and the Storage screen says the drive
  is missing. Nothing is created in its place. Connect the drive and it's picked up again.
- Tested with a second local folder only. **[untested with a real external drive]**

## Alternative: the command line
Build the command-line tool once:

```bash
cd Server && swift build -c release --product supersemu
sudo cp .build/release/supersemu /usr/local/bin/
supersemu server status
```

- Import a folder, files or .zip archives: `supersemu library import ~/ROMs`.
- Or drop files into the server's Incoming folder and run `supersemu library scan`.
- See what needs attention: `supersemu library review`.
- BIOS files import like games (they're recognised by their contents).
- Connection options (other servers, tokens) are in [docs/specs/cli.md](specs/cli.md).

## 7. Pair your devices
1. On the Mac mini, the **Pair a device** section of the Server Mode window shows a QR code and a pairing code.
2. On another Mac, or on the iPhone once TestFlight is set up: open SupersEmu, choose **Connect to your SupersEmu Server**,
   then scan the code or type the address and pairing code.
3. Paired devices show up under **Paired devices**, where you can revoke them.

## 8. Check it works
- At home: the library loads, a game downloads and plays, and a save made on the iPhone continues on the Mac.
- Away: turn off Wi-Fi on the iPhone. The public library should still load and games should download. **[untested]**
- Restart the Mac mini without logging in, then open the app on the iPhone. The server should answer. **[untested]**

## 9. Bots (OpenClaw)
See [docs/openclaw.md](openclaw.md) to create a scoped token for a bot.

## 10. Backups

The server backs itself up every day at 03:00 (and catches up after the Mac mini was off) into
`<data folder>/Backups`, keeping the last 7. A backup has the database (save history, users,
devices, the game and BIOS index), save files, artwork, the server's certificate and settings.
ROMs and BIOS files are left out unless you turn them on, since you can re-import them.

Put backups on an external drive:

```sh
supersemu backup config --destination /Volumes/Backup/SupersEmu --keep 14
supersemu backup config --include-roms     # optional, needs much more space
supersemu backup create                    # back up now
supersemu backup list --verify             # re-check every backup
```

Server mode › Backups in the app shows the last result and destination, with Back Up Now and
Change… for the folder. If the drive isn't plugged in, the backup fails (nothing is written to the
internal disk instead) and the last result says so.

Restore: `supersemu backup restore <id> --yes`. The server checks the backup, stops serving,
replaces its data, and comes back up. Paired devices keep working because the certificate is
restored too. Saves made after that backup are replaced; the data the restore replaced is kept in
`<data folder>/.pre-restore` until the next restore. On a fresh Mac mini, set the destination to
the drive first, then `backup list` and `backup restore`.

## Updating
- **Mac [untested]:** Run `./scripts/update-mac.sh` to pull the latest code, rebuild and replace the app, restart the boot server if it is registered, and reopen SupersEmu. This script is only for source-built (Debug) installs; update the notarized release build with the newer release .dmg instead. macOS may ask you to approve the boot server again in Login Items after an update. Games, saves and settings are kept outside the app.
- **iPhone/iPad:** Plug in the device, open the project in Xcode, select the device, and press Run. Data is kept.

## What to send back
Whether each **[untested]** step worked, plus how your Retrolink and 8BitDo pads behave and whether games run at full speed.
