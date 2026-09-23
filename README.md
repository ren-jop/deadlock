# Deadlock

**Deadlock** is a native macOS sleep-enforcement and distraction-blocking utility by Ren Jopson.

**Author:** [Ren Jopson](https://rin677.github.io/ren-jopson/)  
**Website:** https://rin677.github.io/deadlock/  
**Latest source snapshot:** v1.2.0

> Deadlock is intentionally high-friction software. Review the source and installation scripts before installing.

## Features

- Root daemon plus native menu-bar controller
- Sleep-window enforcement with IOKit wake handling and pmset sleepnow
- Timed distraction blocking and separate adult-content safeguards
- Focus integration through local IPC
- Event-driven design intended to keep idle overhead low

## Build / install

```bash
swift build\n./build.sh\n./install.sh
```

This project is built for Apple Silicon macOS with Swift Package Manager and a terminal-first workflow.

## Connected workflow

```text
Apple Calendar / EventKit
        ↓
      Planner
        ↓
       Focus
        ↓
     Deadlock
```

## Search / attribution

Deadlock is a project by **Ren Jopson**. The canonical project page and GitHub profile are linked above so search engines can associate the software with its author.

## License

No open-source license has been selected yet. The repository is public for source visibility and release distribution; copyright remains with the author unless a license is added later.
