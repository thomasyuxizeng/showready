ShowReady 1.3.3 - can these PCs and this line run the show?
===========================================================

Show: 2 x OMT/NDI 1080p60 in; 3 x 1080p60 out (SRT to France, YouTube, Twitch).
Three PCs, one kit: the prod PC (vMix/OBS, sends the 3 outputs) and the 2 observer PCs
(each sends one 1080p60 feed to the prod PC). NDI/OMT does not need to be installed yet.
Runs on Windows 10/11 with the built-in PowerShell. Nothing to install.
The checks need no admin rights; the prep step (step 0) does.

Download (no GitHub login needed):
    https://github.com/thomasyuxizeng/showready/releases/latest/download/ShowReady-kit.zip


BEFORE YOU RUN IT
-----------------
1. Copy the whole ShowReady folder to all three PCs, e.g. C:\ShowReady.
   If it arrived as a zip: right-click the zip > Properties > tick "Unblock" > OK, then extract.
   (Downloaded with a browser: Edge/Chrome may warn about the zip. Choose Keep.)
2. Set each PC up exactly as on show day:
   - Ethernet cable to the production switch, Wi-Fi off
   - on mains power
3. Prod PC: close vMix/OBS, browsers and anything else heavy.
   Observer PCs: close everything except the game / observer client.
   Never run this during a live show: the tests max out the CPU and send network traffic.


STEP 0: PREP EACH PC (as administrator, once, NOT on show day)
--------------------------------------------------------------
Double-click Run-Prep.cmd and say Yes to the administrator prompt. It asks whether this is
the PROD PC or an OBSERVER PC, shows everything it would change, then asks per section:
  - language   switches Windows to English (keeps the Korean keyboard). Downloading English
               takes 5-30 minutes. Windows Home "Single Language" PCs first need an edition
               switch: prep offers it (type HOME to confirm). Windows is then NOT activated
               (watermark, no undo), and you run Run-Prep.cmd again after the restart to get
               English.
  - drivers    installs the driver updates Windows Update offers, and tells you if the
               graphics driver is too old (NVIDIA needs 570 or newer) with the download link
  - disk       warns if the system drive has less than 50 GB free (under 20 GB is serious)
  - power      Ultimate/High performance plan, never sleep, no USB/PCIe power saving
  - startup    disables startup apps that aren't needed (security, drivers, NDI/OMT, vMix/OBS,
               remote access and anti-cheat are kept), including Korean banking security
               plugins and updater tasks. Same as "Disable" in Task Manager: reversible.
  - background closes browsers, cloud sync, chat and updaters now (game clients stay open on
               observer PCs). Save your work first. Discord/Slack etc. are asked one by one.
  - network    Energy-Efficient Ethernet off, adapter power saving off, network set to
               Private. Turning Wi-Fi or VPN adapters off is asked separately (default No).
  - capture / notifications   Xbox Game Bar background recording off, pop-ups off
  - updates    pauses Windows Update for 7 days (done last, after the driver updates)
At the end it lists anything you must do by hand and offers to restart. Restart, then run
the checks below.
Undo everything it changed: Undo-Prep.cmd (drivers and the English language pack stay).
Just look without changing anything: Run-Prep.cmd -PlanOnly
Only some sections: Run-Prep.cmd -Only power,startup


AUDIO DEVICE NAMES IN ENGLISH (any PC, optional)
------------------------------------------------
Windows names each audio device in the language it had when the device was installed, and
keeps that name after prep switches Windows to English. vMix/OBS then list devices such as
"<Korean word> (Blackmagic DeckLink Quad 2 (1) Audio)". To rename them, close vMix/OBS and
double-click Rename-AudioDevices.cmd. It lists every Korean name with its English name
(Speakers, Headphones, Microphone, ...), asks once, then renames. No admin rights needed.
  - Only the first part changes; the part in brackets is the driver's name.
  - Restart vMix/OBS afterwards and check Settings > Audio Outputs: outputs you picked
    before may need picking again.
  - Names it doesn't know are listed as UNKNOWN: rename those by hand (Win+R, mmsys.cpl,
    right-click the device > Properties).
  - Just look: Rename-AudioDevices.cmd -PlanOnly     Undo: Rename-AudioDevices.cmd -Undo


RUN ORDER (three PCs)
---------------------
1. On BOTH observer PCs: double-click Run-Observer.cmd.
   When it asks, start the game / observer client as on show day, then press Enter.
   It checks the PC (about 2 minutes), then shows the PC's IP address in big digits and
   waits for the prod PC. Write down both IP addresses and leave both windows open.
   If Windows Firewall asks about iperf3: tick "Private networks" and click "Allow access"
   (needs an administrator password). If you click Cancel, the prod PC can't connect:
   ask IT to allow TCP and UDP port 5201 on that PC.
2. On the prod PC, open a Command Prompt in the ShowReady folder and run, with the two
   real addresses:

    Run-ShowReady.cmd -LanHosts 192.168.10.31,192.168.10.32

   It tests the network from each observer PC on its own, then from both at once
   (about 7 minutes in total). The observer windows show "Prod PC ... connected - testing".
3. When the prod PC has finished, press any key in both observer windows.
   (They stop by themselves after 30 minutes.)
4. Results upload by themselves (see UPLOADS below). If a PC was offline, run
   Upload-Results.cmd on it later, or send back its results\<date-time>\ folder.


MORE WAYS TO RUN IT
-------------------
Prod PC, quick check (about 5 minutes):   double-click  Run-ShowReady.cmd
Prod PC, full check (about 10 minutes):   double-click  Run-ShowReady-Full.cmd
Observer PC, longer sender test (2 min):  Run-Observer.cmd -Mode full

Once the French partner sends the IP or hostname of their SRT receiver, test against it
on the prod PC:

    Run-ShowReady.cmd -SrtHost 203.0.113.10 -LanHosts 192.168.10.31,192.168.10.32

(Use their real address. The SRT latency is then calculated for their actual route.
Routes from Seoul to different French networks differ by about 90 ms.)

Prod PC options:
  -LanHosts <IPs>   test the network speed from these observer PCs
  -Skip load        skip the load test (e.g. when re-checking only the network)
  -Skip network     skip the internet tests
  -Skip lan         skip the local network step (feeds, devices, observer PC speed)
  -NoOpen           don't open the report at the end
Observer PC options (Run-Observer.cmd ...):
  -Mode full        2-minute sender test instead of 45 seconds
  -Skip sender      skip the sender test
  -NoPrompt         don't wait for Enter before the sender test
  -ServerMinutes 0  don't wait for the prod PC afterwards

Run-LanPartner.cmd only waits for the prod PC's speed test, without checking the PC.
Use it on any other PC that sends a feed.


WHAT YOU GET
------------
The window ends with GO / CAUTION / NO-GO, the problems to fix, and the settings to use
(on the prod PC: SRT latency, overhead, bitrates, ingest servers, encoder).

A full report opens in the browser. It and the raw data are saved in
results\<date-time>\report.html and results.json.
Send both files back after each run.

  GO       nothing blocking found
  CAUTION  works, but something is risky or could not be measured
  NO-GO    something will break the show - fix the MUST FIX items and run again


UPLOADS
-------
Every run (checks, observer checks, prep) uploads its results folder to the public repo
https://github.com/thomasyuxizeng/showready-results (folder runs/<date-time>_<PC name>_<kind>).
No login is needed: the upload key is in upload.json. The window prints "Uploaded: <link>".
Prep backups (undo data) are never uploaded.
  "Not uploaded: run Setup-Upload.cmd"   upload.json is missing: run Setup-Upload.cmd and
                                         paste a GitHub key with Contents read/write access
  "upload key rejected or expired"       make a new key and run Setup-Upload.cmd
  no internet at the time                run Upload-Results.cmd later
Add -NoUpload to any Run-*.cmd to keep a run local.


GOOD TO KNOW
------------
- Run it again at show time on show day. Evening congestion is different from daytime.
- The network test sends UDP to public test servers in Paris (ports 5200-5240 and 9200-9240).
  If the venue firewall blocks it, UDP loss shows "not measured" and the result can't be GO.
  That's worth knowing anyway: SRT is also UDP. Ask IT to allow outbound UDP to the partner.
- It can't prove that Twitch will accept the stream from Korea. Do a 30-second test stream
  with the real key from the venue.
- The load test copies 2 feeds in and 3 encodes out, but not vMix/OBS mixing or graphics.
  Still do a 30-minute rehearsal with the real scene.
- The GPU encoder test needs NVIDIA driver 570 or newer. With an older driver the report says
  so and the test falls back to the CPU; vMix/OBS can usually still use NVENC on that driver.
- The observer check encodes one 1080p60 SpeedHQ feed while the game runs. SpeedHQ is the
  codec full NDI uses; OMT's VMX codec has no ffmpeg encoder, so SpeedHQ stands in for both.
  ffmpeg's SpeedHQ encoder uses one CPU core and the real NDI/OMT sender several, so falling
  behind is a warning, not a NO-GO. The CPU load during the test is the stronger signal.
- The local network step looks for the OMT/NDI senders the same way vMix and OBS do (mDNS).
  Until NDI/OMT is installed on the observer PCs it finds none; that's expected and does not
  block GO. It only finds senders on the same subnet: senders on another subnet/VLAN, or only
  registered with an NDI/OMT Discovery Server, don't show up; add those by IP in vMix/OBS.
  A Public network profile or Wi-Fi that blocks multicast also hides them.
- Windows Defender may scan bin\ffmpeg.exe the first time. That's normal.


WHAT'S IN THE FOLDER
--------------------
Run-Prep.cmd / Undo-Prep.cmd                 step 0 on every PC (as administrator) / undo it
Run-ShowReady.cmd / Run-ShowReady-Full.cmd   prod PC: start here
Run-Observer.cmd                             observer PCs: start here
Run-LanPartner.cmd                           speed-test server only (for any other source PC)
Setup-Upload.cmd / Upload-Results.cmd        set the upload key / upload runs made offline
Rename-AudioDevices.cmd                      audio device names in English (backups in audio-names\)
ShowReady.ps1, Prep.ps1, lib\                the tests, the prep steps and the rules
config.json, prep-config.json                show profile, thresholds, prep keep/close lists
upload.json                                  upload key (results repo only)
report-template.html                         the report layout
bin\  ffmpeg (GPL, see FFMPEG-LICENSE.txt, BtbN build n8.1),
      iperf3 3.22 (BSD) with cygwin1.dll (LGPL)
tests\, fixtures\, CONTRACT.md               for whoever maintains the tool
