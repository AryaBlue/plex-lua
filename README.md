# Reel (PlexLove)

A Plex client for LÖVE (written for 11.5, tested on 12.0), Windows only for now.

Run: `lovec E:\PlexLove` (F11 toggles fullscreen).

## Controls

| Action | Keyboard | Controller |
|---|---|---|
| Move | Arrows / WASD | D-pad / left stick |
| Select | Enter | A |
| Back | Esc / Backspace | B |
| Play / pause | Space | X |
| Poster options, menu, sort | Tab | Y / Start |
| Seek -30 s / +30 s | J / L | LB / RB |

Search: the **Search** tab on Home, or `/` / Ctrl+F on Home and library pages. Type on the keyboard
(Backspace deletes, Ctrl+Backspace deletes a word, Ctrl+V pastes), or use the on-screen keyboard with a
controller or the mouse (X deletes). Enter jumps to the results, which are grouped into rows (Shows, Movies,
Episodes...). Esc goes from the results back to the keyboard, then leaves. With an empty query the
recent searches are listed; a search is saved there when you open one of its results.

Genres and sorting: under a library's title (Films, TV shows) is a toolbar like Plex's: **Genre ▾** and
**Sort ▾** dropdowns, a ✕ to clear the genre, and the title count on the right. Click a dropdown, or press up
from the top row of posters (left/right moves along the toolbar); Tab / Y there opens Sort. The genre menu has a filter
box (just type, e.g. "sci"), and the current choice is ticked in the accent colour. Searching a genre name (e.g.
"anime", "action") shows a **Genres** row first, one tile per library, that opens the library filtered.
`lovec . --shots genre` checks both (read-only; puts your recent searches back).

For You: **Sort ▾ → For You** ranks a library by what you've watched (`plex/recommend.lua`, worked out in
Reel from your server's listings, nothing sent anywhere). Every title you've watched, in the films and TV libraries
both, adds its genres, director, writer, top cast, studio, country, decade and rating to a taste profile, counted
by how much you watched it (rewatches and finished shows more, a show you stopped after an episode or two less,
older watches less, a low star rating against). Rare tags count more than common ones, so a shared actor matters
more than "Comedy". Unwatched titles are ranked 80% by that match and 20% by audience rating, and anything you've
watched or started goes last. The focused poster says why ("Because you watched Zombieland", or "Because you like
Comedy"), and it works inside a genre too. The libraries are read once and kept for 10 minutes (a few seconds on
first use). Home shows the top 30 of each as **Recommended Films** / **Recommended TV shows**, after the
Watchlist. `lovec . --shots foryou` prints the top picks and the Home rows (read-only).

A film's or show's page lists its **Cast** under More Like This: portraits with each actor's character. Choose one
to see everything they're in on your server, one row per library, newest first.

Poster options: right-click a poster, click the **⋯** that appears on it under the mouse, or press Tab / Y on a
focused one (Home, libraries, search results, episodes and More Like This). The menu has **Play** (or **Resume
from 12:34** and **Play from Start**), **Mark as Watched** / **Mark as Unwatched** (both for something half
watched, as in Plex), **Add to Watchlist** / **Remove from Watchlist** (episodes: **Add Show to Watchlist**),
**Remove from Continue Watching** on that row, and **Go to Show** for episodes. Marking
updates the poster straight away; removing reloads Home. `lovec . --shots options` walks through it with the
server calls stubbed out, so nothing on your server changes.

Watchlist: your Plex watchlist (the same one as plex.tv and Plex's apps) is a **Watchlist** row on Home after
Continue Watching / On Deck. Titles your server has open their own page; ones it doesn't are marked **Not in
library** and open their Seerr request page (their menu has **Request** and **Remove from Watchlist**). Film and
show pages have a **Watchlist** button too. `lovec . --shots watchlist` checks the row, menus and buttons with
every change answered locally, so your watchlist isn't touched.

Show audio and subtitles: a show's page (and its episodes' pages) has **Audio & Subtitles**: the show's own
settings on the server, as in Plex Web's Edit > Advanced: **Audio language**, **Subtitle language** (type to filter,
e.g. "japanese") and **Subtitles shown** (Account default, Manually selected, Shown with foreign audio, Always
enabled). The server uses them to choose the tracks for every episode; a track picked in the player still wins
for that episode.

Requests: search also asks Seerr (`https://seerr.proddy.xyz`, or `seerrUrl` in `settings.json`; set it to
`false` to turn requests off). Matches that aren't on the server appear in a last row, **Not in your library ·
Request**, with a badge if they're already requested or partly available. Opening one shows its request page:
**Request** for a film, or **Request All Seasons** / **Request N Missing Seasons** for a show. The app signs in to
Seerr with your Plex account, so requests are made as you and follow your Seerr permissions and approval.
While the app is open it checks your requests every minute and pops up a notification (top right, with the
poster) when one is **approved** or **declined**, or when it's **now on Plex**. Changes that happen while the app
is closed are announced the next time it starts.

In the player, Left/Right seek 10 s. Seeks wait 0.45 s for further presses before running.
Down moves from the seek bar to the control row: play/pause, back 10 s, forward 10 s, volume, and fullscreen.
Up goes to the back button. With volume selected, Up and Down change it. `+`/`-` change the volume and `F` toggles fullscreen at any time.
The volume is remembered between sessions.

Audio and subtitles: the speech-bubble button next to fullscreen (or `C`) opens the track menu: **Audio** (every
audio track, e.g. English / Japanese) then **Subtitles**. Choosing an audio track restarts the stream at the same
point with it; when playing the file directly the app picks the track itself, otherwise the server converts with
it. A section with many tracks lists the first five (and the one in use) and a "Show N more" row that lists the
rest. Tracks Windows can't decode (DTS, TrueHD) are marked "server converts it". Surround (5.1/7.1) Opus, which
Windows' own decoder refuses, is decoded with libopus (the `opus.dll` LÖVE ships, found next to the exe) and
downmixed to stereo; without it the server converts those tracks. If a file played directly still opens
without a decoder for its sound, the player asks the server to convert it instead of playing silently. Separate subtitle files and text
tracks inside the video (ASS, SRT) are drawn by the app; picture subtitles (PGS, VobSub) are burned in by the
server ("server draws it in"). Choices are saved on the server like in Plex's own apps, so they're the default
next time. The menu ends with **Quality** (see Settings); picking one restarts the stream at that quality and
makes it the default. `lovec . --shots audio` checks switching on a local two-track clip (by the tone each track plays).

Auto play: near the end of an episode a **Playing Next** card shows the next one (the next in the season,
then the first of the next season) with a countdown ring, **Play Now** and **Cancel**. It appears when the credits
start if the server has a credits marker for the episode, otherwise the countdown's length before the end, so the
next episode starts as this one finishes. Cancel (or Esc) keeps watching; `N` skips to the next episode at any time.
With auto play off the card still appears but waits for Play Now.

Profile and settings: the avatar at the top right of Home opens the account menu (your Plex picture, name and
username, then **Settings**, **Switch Server**, **Sign Out**), laid out like Plex's own account menu. **Settings** has
Auto Play on/off, the countdown (3, 5, 10, 15 or 30 s; 10 is Plex's own), the colour theme (Reel, Plex Gold, Cinema,
Ocean, Emerald, Violet, Sunset, OLED Black; applied straight away), and the account actions. Everything is saved in
`settings.json` (`autoPlay`, `autoPlayDelay`, `theme`, `qualityHome`, `qualityAway`).

Quality: like Plex's apps, Settings has one quality for **At Home** (the server's address is on this network) and
one for **Away** (internet or relay); the one in use is marked "(in use now)". **Original** plays files as they are
whenever Windows can decode them. A limit (20 Mbps 1080p down to 1.5 Mbps 480p) plays files under it directly and
has the server convert anything bigger to that bitrate and size. The player's info line says "at 4 Mbps 720p" when
it's converting to a limit.

Casting: **Cast** on a film's or episode's page (next to Play), or the cast button in the player's control row
(left of subtitles), opens **Play on…**, which lists the TVs it finds. Choosing one starts the title there, from where
you left it (from the player: from the current point). The TV plays it in its own Plex app, streaming straight from
the server, so progress is saved as usual. The player becomes the remote: the title's art with "Playing on <TV>",
and the usual timeline drives the TV: the seek bar (click or drag), play / pause, back / forward, volume and mute,
and subtitles and audio (Chromecast: saved on the server, and the TV reloads the title at the same point). The cast
button, now lit, opens **Play on this computer** (takes it back where the TV got to), **Stop casting** and
**Disconnect** (leaves it playing). Leaving the player keeps the TV playing, and the Cast button on the title's page
then reads **On <TV name>** and brings the remote back.
- **Chromecast / Google TV:** found with mDNS. Reel launches Plex's own Chromecast app (`9AC194DC`) and sends it the
  title, the server's address and token, and a play queue (so a show carries on to the next episode).
- **Fire TV sticks and other DIAL TVs:** found at the addresses in `castDialHosts` in `settings.json` (Fire TV
  sticks only answer searches sent to the whole network, so their description address is read directly too;
  `castDialScan: true` also searches the whole network). Reel opens Plex on the stick and you pick the title
  there (playing a chosen title directly needs the Fire TV app's launch data, still to be read from the app).
  Plex on Fire TV takes no remote control from other apps, so Reel controls it over **ADB** instead: turn on
  **Settings > My Fire TV > Developer options > ADB debugging** on the stick, and the first time Reel connects the
  TV asks "Allow USB debugging?" (tick Always allow). Reel then reads what Plex is playing (title, position,
  playing or paused) from the TV and presses the remote's buttons: play, pause, fast forward / rewind (Plex's own
  skips, 30 s / 10 s by default, so a seek lands on the nearest skip), stop, and the TV's volume / mute.
  `castAdb: false` turns this off. Audio and subtitles are changed with the TV's remote.
- `castBlock` lists device names or addresses Reel never lists or sends anything to.

Mouse:
- Hover focuses cards, tabs and buttons, and clicking opens them.
- The wheel scrolls the page. Shift+wheel, or a horizontal wheel, scrolls the row under the pointer.
- Show pages, library pages and search have a back arrow at the top left (on a show page, Up from the buttons selects it).
- Pointing at a row of cards (Home rows, search results, a show's episodes, "More Like This") shows arrows at
  its ends; click them to page through.
- Right-click or the mouse Back button goes back. On the sign-in and server screens it is ignored, so it can't quit or sign you out.
- In the player, moving the mouse shows the controls. Clicking the picture plays or pauses, and **double-clicking it toggles fullscreen**.
  You can click or drag on the seek bar and the volume slider, and the wheel changes the volume. The arrow at the top left exits.
  The pointer hides after 2.5 s while playing.

## How it works

- **Sign-in:** plex.tv PIN / link code (`plex/auth.lua`). The token is kept in the LÖVE save folder (`settings.json`).
- **Servers:** `clients.plex.tv/api/v2/resources`, with every connection tested in parallel on `/identity`.
  The best one wins: direct before relay, then loopback, then LAN, then HTTPS (`plex/servers.lua`, see `E:\PlexRE\FINDINGS.md`).
  The server used last is cached (`lastServer` in `settings.json`), so later launches go straight to Home: only
  the address that worked last time is checked, while the sign-in check and a fresh server list run in the
  background (if the old address doesn't answer, every connection from the fresh list is tested). The server
  screen only shows on first run, from **Switch Server**, or if the server can't be reached.
- **HTTP:** WinHTTP through the FFI on 6 worker threads (`lib/http.lua`, `lib/winhttp.lua`); artwork is decoded on the workers.
- **API:** paths and parameters come from the official PMS OpenAPI spec, saved as `docs/pms-openapi.json`.
- **Seerr:** `seerr/api.lua` signs in with `POST /api/v1/auth/plex` (Plex token) and keeps the `connect.sid`
  cookie; uses `/search`, `/movie|tv/{id}` and `POST /request`. `seerr/notify.lua` polls
  `/user/{id}/requests` and compares each request's status and media status with the last ones seen
  (`seerrSeen` in `settings.json`; the first check only records them). `lovec . --shots notify` fakes two
  of your requests as still pending to show the notifications (read-only, restores `seerrSeen`).
- **Search:** `/hubs/search` (`api.search`), 0.3 s after the last keystroke; stale responses are dropped.
- **Playback:** `plex/playback.lua` direct-plays the file when Windows has a decoder for the codec
  (checked once at start-up with `NativeVideo.hasVideoDecoder`). Otherwise the server converts it
  (universal transcoder, H.264 in progressive MKV, audio copied where possible).
  Converted streams seek by restarting at an offset. If the file won't open for direct play, the player asks
  for its first byte; when the server refuses it (an HTTP error, which Media Foundation reports as a network
  timeout), it asks the server to convert the file instead, and says so if that fails too.
- **Video and audio:** NativeVideo (`lib/NativeVideo.lua` + `nativevideo.dll`, built from `E:\Documents\nativevideo`).
  The player uses it through `lib/VideoStream.lua`: each stream gets its own thread
  (`lib/videostream_worker.lua`) that opens the file, seeks and decodes picture and sound ahead (6 frames,
  4 at 4K; about 1.7 s of sound), so a slow network or decoder never holds up the app. The main thread only
  queues the sound into OpenAL, shows the newest frame whose time has come on the sound's clock, and uploads
  it. Frames and sound carry the generation of the seek they follow, so whatever was decoded before a seek
  is dropped. Closing a stream never waits: its thread closes the reader when its current read returns.
  The audio track is chosen at open (`nv_set_audio_track` in the DLL).
- **Next episode:** `api.nextEpisode` walks `/library/metadata/{season}/children`, then the show's seasons;
  credits come from `Marker` entries (`includeMarkers=1`, `api.creditsStart`).
- **Casting:** `cast/init.lua` (sessions, play queue, the LOAD message), `cast/session_worker.lua` (Cast v2 on its
  own thread: TLS through `castsock.dll`, built from `native/castsock.c` with `native/build.bat` (Schannel, no
  certificate check, as Cast devices use self-signed ones), protobuf framing in `cast/proto.lua`, heartbeats),
  `cast/discovery_worker.lua` (mDNS + SSDP/DIAL), `cast/dial.lua`, the Fire TV remote (`cast/adb.lua`: ADB over the
  network, signed in with an RSA key `castsock.dll` makes with Windows CNG and keeps as `adbkey` in the save folder;
  `cast/adb_worker.lua` reads `dumpsys media_session` and sends `input keyevent`), `ui/castpicker.lua`, and the
  player's casting mode in `player/scene.lua`.
  The LOAD message follows pychromecast's Plex controller.
- **Branding:** `theme.lua` (name, tagline, colours, and the theme presets).

## Tools

- `lovec . --selftest`: JSON, URL and connection-ranking checks, plus live HTTPS to plex.tv.
- `lovec . --shots [tv|player|mouse|controls|search|detail|request|subs|hover|rows|profile|upnext|nextep|genre|audio|notify|options|watchlist|foryou|cast|casting|fileerror|stall|tracks|opus51]` (request never presses Request; profile puts your settings back; fileerror and stall need `python tools/refuse500.py` / `python tools/slowserve.py` running): scripted walkthrough that saves screenshots to the save folder `shots/`.
- `lovec . --casttest`: casting against stand-in devices on this PC (run `python tools/fakecast.py` first): finding a
  Chromecast and two Fire TV sticks (one blocked), launch, LOAD, pause, seek, mute and stop from the player's
  controls, opening Plex over DIAL, and the Fire TV remote over ADB (key sign-in checked with real RSA maths).
  Nothing reaches a real TV or the server. `--shots casting` shows the Cast button on a film page (read-only).
- `lovec . --castscan [dial-only]`: lists the TVs Reel can see and quits (looks only; launches nothing).
- `lovec . --nvtest [ratingKey]`: opens one item's direct-play URL with nv_open and reports decode and seek timings.
- `lovec . --transcodetest <ratingKey>`: runs the conversion path step by step (decision, stream headers, interleaved reads).
- `lovec . --playtest <ratingKey> [seconds]`: runs the real player muted and logs state, clock and reconnects.

**These three start real streams on the server under your account, and the play test reports progress for the item.**
Don't run them while you're watching something, especially on a server with a stream limit.
