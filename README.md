# homebrew-jarvis

Homebrew tap for [Jarvis](https://github.com/upendrasengar/jarvis) — a
personal AI agent on Claude Code: daily project digests with attention
triage, fully-local call recording + minutes, a knowledge graph,
second-brain recall, voice, Telegram, an optional calendar adapter, and a
dashboard.

## Install

```bash
brew tap upendrasengar/jarvis
brew install jarvis
jarvis init           # short interview: who you are, which repos to watch
jarvis start          # → http://localhost:4321
```

Requires [Claude Code](https://claude.com/claude-code) installed and logged
in (Jarvis's brain — your own account, no API keys).

Your data lives in `~/.jarvis`; `brew upgrade jarvis` never touches it.

## Release process (maintainers)

```bash
./release.sh 0.2.0    # tags jarvis repo, pushes, updates formula sha256
```
