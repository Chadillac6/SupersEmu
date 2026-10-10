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
cp -R build/mac/Build/Products/Debug/SupersEmu.app /Applications/
```

## 3. Turn on the server
1. Open SupersEmu and click **Server Mode**.
2. To try it right away, click **Start Server for This Session** (port 8488). It stops when you quit the app.
3. To keep it running, click **Register Boot Daemon**, then **Open Login Items Settings** and allow it. The server then runs on port 8487 at boot, even before anyone logs in. **[untested]**
4. Server data lives in `/Library/Application Support/SupersEmu Server`.

## 4. Remote access with Tailscale
1. Install Tailscale on the Mac mini and sign in. Use the standalone download from tailscale.com, not the Mac App Store
   version: the App Store version only runs while someone is logged in. **[untested]**
2. Install Tailscale on your iPhone/iPad with the same account.
3. No router port forwarding is needed. Don't open any ports.

## 5. Add games and BIOS files
Build the command-line tool once:

```bash
cd Server && swift build -c release --product supersemu
sudo cp .build/release/supersemu /usr/local/bin/
supersemu server status
```

- Import a folder, files or .zip archives: `supersemu library import ~/ROMs`. Messy folders are fine:
  duplicates are skipped, multi-disc games become one tile, and anything unclear goes to Review Needed.
- Or drop files into the server's Incoming folder and run `supersemu library scan`.
- See what needs attention: `supersemu library review`.
- PS1 and Sega CD need BIOS files from your own consoles. Import them like games (they're recognised by
  their contents), then check with `supersemu bios status`.
- Connection options (other servers, tokens) are in [docs/specs/cli.md](specs/cli.md).

## 6. Pair your devices
1. On the Mac mini, the **Pair a device** section of the Server Mode window shows a QR code and a pairing code.
2. On another Mac, or on the iPhone once TestFlight is set up: open SupersEmu, choose **Connect to your SupersEmu Server**,
   then scan the code or type the address and pairing code.
3. Paired devices show up under **Paired devices**, where you can revoke them.

## 7. Check it works
- At home: the library loads, a game downloads and plays, and a save made on the iPhone continues on the Mac.
- Away: turn off Wi-Fi on the iPhone (Tailscale on). The library should still load and games should download. **[untested]**
- Restart the Mac mini without logging in, then open the app on the iPhone. The server should answer. **[untested]**

## 8. Bots (OpenClaw)
See [docs/openclaw.md](openclaw.md) to create a scoped token for a bot.

## 9. Backups

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

## What to send back
Whether each **[untested]** step worked, plus how your Retrolink and 8BitDo pads behave and whether games run at full speed.
