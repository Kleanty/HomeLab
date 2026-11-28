# HomeLab Panel (Android)

The app that turns an old Android phone into a wall/desk panel for the HomeLab server. Licence: MIT (see the root `LICENSE`).

- App name "HomeLab Panel", package `net.homelab.panel`. The app is in English by default; another language is used only if you choose it.
- Widgets: Docker (start/stop), push, inbox, system charts and meters, processes, shortcuts, clock, weather and the HomeLab settings page. Page 1 shows simple CPU, RAM, temperature and network cards; the System page has the charts, and tapping one opens the large graph.
- While the computer cannot be reached, the app shows a "Not Connected" screen.
- On the System page, tapping a chart opens the large graph; a large alert window shows HomeLab alerts; vibration and sound can be set.
- Swiping between pages also works over lists; tapping the dot at the bottom jumps to that page.

Build: GitHub > Actions > build-apk > Run workflow, then download the `homelab-panel-apk` file.
