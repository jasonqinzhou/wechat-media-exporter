# WeChat Media Exporter for Mac

This tool exports normal image and video files by automating WeChat's own **Chat History → Media → Save** workflow. It does not extract encryption keys, decrypt WeChat databases, inject code, or upload your data.

It was built and tested against WeChat **4.1.12 (build 269341)** on this Mac.

> Status: early beta. WeChat UI updates can require selector changes, so test a
> small export after updating WeChat.

## What it does

- Walks the Recent Chats list, or only an exact allow-list of chat names.
- Creates one destination subfolder per chat.
- Saves both images and videos using WeChat's own decoder.
- Skips media that WeChat reports as expired, deleted, or no longer available.
- Uses WeChat's suggested filename for stable incremental runs.
- Stops a chat at the first filename already present by default.
- Can install a daily `launchd` schedule.

## Important limitations

- The exporter controls the WeChat interface while it runs. Do not use WeChat during an export.
- Scheduled runs require WeChat to be running and logged in, with the Mac awake and unlocked.
- It can export only media WeChat can still display. Expired/deleted media cannot be recovered and is counted as `unavailable skipped`, not as a warning.
- A brand-new Mac install may have only recent history. Use WeChat's **Import chat history from phone** feature first if you want older phone history.
- `allRecentChats` covers conversations in WeChat's Recent Chats list. Set `chats` to exact names if you want only selected conversations.
- The UI labels are version-sensitive. Re-run `doctor` after a major WeChat update and test one chat before a large export.

## One-time setup

1. Clone the repository and build the app:

   ```bash
   ./build.sh
   ```

2. Duplicate `config.example.json` as `config.json` and replace `destination` with an absolute path. `config.json` is ignored by Git.
3. Keep `chats` empty to process all Recent Chats, or use exact names:

   ```json
   "chats": ["Family", "Project Photos"]
   ```

4. Run the doctor command from Terminal:

   ```bash
   '/path/to/WeChat Media Exporter/WeChat Media Exporter.app/Contents/MacOS/WeChat Media Exporter' doctor --prompt
   ```

5. If macOS opens **Privacy & Security → Accessibility**, enable **WeChat Media Exporter**. You may need to run the doctor command once more.

## Run an export

Open WeChat, make sure it is unlocked, and run:

```bash
'/path/to/WeChat Media Exporter/WeChat Media Exporter.app/Contents/MacOS/WeChat Media Exporter' run --config '/path/to/WeChat Media Exporter/config.json'
```

For a cautious first test, select one chat in WeChat and export one item:

```bash
'/path/to/WeChat Media Exporter/WeChat Media Exporter.app/Contents/MacOS/WeChat Media Exporter' export-current --destination '/path/to/test-folder' --max-items 1
```

## Daily schedule

This example runs every day at 3:00 AM:

```bash
'/path/to/WeChat Media Exporter/WeChat Media Exporter.app/Contents/MacOS/WeChat Media Exporter' schedule-install --config '/path/to/WeChat Media Exporter/config.json' --hour 3 --minute 0
```

Remove it with:

```bash
'/path/to/WeChat Media Exporter/WeChat Media Exporter.app/Contents/MacOS/WeChat Media Exporter' schedule-remove
```

The first archive can take a long time. For that run, keep the Mac awake and start with a small `maxItemsPerChat`; increase it after verifying the result. Later incremental runs should stop quickly when they encounter an already-exported filename.

## Recommended WeChat settings

Keep these enabled under WeChat **Settings → General**:

- Save chat history
- Auto download files less than 20 MB
- Automatically download content viewed on other devices

These were already enabled when this tool was tested on this Mac.

## Privacy and implementation

The exporter uses macOS Accessibility APIs to operate WeChat's visible controls.
It does not read WeChat's private data directory, extract encryption keys,
decrypt databases, inject code, or send analytics. Exported media stays in the
destination you configure.
