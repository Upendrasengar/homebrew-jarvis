# Jarvis · © 2026 Upendra Sengar · MIT License · https://github.com/Upendrasengar/jarvis
class Jarvis < Formula
  desc "Personal AI agent on Claude Code: digests, local call notes, recall"
  homepage "https://github.com/upendrasengar/jarvis"
  url "https://github.com/upendrasengar/jarvis/archive/refs/tags/v0.2.11.tar.gz"
  sha256 "69eeda4a79de64caa6cbe46788572599896cbfb375b0103f28837dc49f07d16c"
  license "MIT"
  head "https://github.com/upendrasengar/jarvis.git", branch: "main"

  depends_on :macos
  depends_on "ffmpeg"
  depends_on "node@22"   # better-sqlite3 v11 predates node 26's V8 API
  depends_on "pnpm"
  depends_on "whisper-cpp"

  def install
    # build AND run against node 22 LTS (matches the engine's tested stack)
    ENV.prepend_path "PATH", Formula["node@22"].opt_bin

    # engine lives read-only in the cellar; user data lives in ~/.jarvis
    # (the wrapper below overlays the two with symlinks)
    libexec.install Dir["*"]

    cd libexec do
      # JS workspace: install + build inside the cellar so upgrades are atomic
      system "pnpm", "install", "--frozen-lockfile",
             "--store-dir", buildpath/"pnpm-store"
      cd "apps/web" do
        system "pnpm", "exec", "vite", "build"
      end
      # native audio helpers (ScreenCaptureKit recorder + mic-holder probe)
      mkdir_p "tools/call-capture/bin"
      system "swiftc", "-O", "tools/call-capture/audiocap.swift",
             "-o", "tools/call-capture/bin/audiocap"
      system "swiftc", "-O", "tools/call-capture/miccheck.swift",
             "-o", "tools/call-capture/bin/miccheck"
      # JarvisAudio.app — recording with its own permission identity
      appdir = "tools/call-capture/JarvisAudio.app/Contents"
      mkdir_p "#{appdir}/MacOS"
      (Pathname.new(appdir)/"Info.plist").write <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleIdentifier</key><string>com.jarvis.audio</string>
          <key>CFBundleName</key><string>Jarvis Audio</string>
          <key>CFBundleDisplayName</key><string>Jarvis Audio</string>
          <key>CFBundleExecutable</key><string>audiocap</string>
          <key>CFBundlePackageType</key><string>APPL</string>
          <key>CFBundleShortVersionString</key><string>1.0</string>
          <key>LSUIElement</key><true/>
          <key>NSMicrophoneUsageDescription</key>
          <string>Jarvis records your side of calls to transcribe them locally.</string>
        </dict>
        </plist>
      PLIST
      cp "tools/call-capture/bin/audiocap", "#{appdir}/MacOS/audiocap"
      system "codesign", "--force", "-s", "-", "tools/call-capture/JarvisAudio.app"
    end

    (bin/"jarvis").write <<~WRAPPER
      #!/bin/bash
      # jarvis — Homebrew wrapper. Engine (read-only) lives in the cellar;
      # everything Jarvis knows about YOU lives in $JARVIS_HOME (~/.jarvis),
      # overlaid with symlinks so upgrades never touch your data.
      set -u
      export PATH="#{Formula["node@22"].opt_bin}:$PATH"
      export JARVIS_NODE="#{Formula["node@22"].opt_bin}/node"
      ENGINE="#{opt_libexec}"
      JHOME="${JARVIS_HOME:-$HOME/.jarvis}"
      mkdir -p "$JHOME"
      for item in apps packages tools node_modules package.json \\
                  pnpm-workspace.yaml pnpm-lock.yaml tsconfig.base.json \\
                  CLAUDE.md memory.example install.sh jarvis docs LICENSE; do
        ln -sfn "$ENGINE/$item" "$JHOME/$item"
      done
      if [ ! -d "$JHOME/memory" ]; then
        cp -R "$ENGINE/memory.example" "$JHOME/memory"
        echo "jarvis: created $JHOME/memory — edit memory/about-me.md and"
        echo "        memory/active-projects.md (or just tell Jarvis who you are)."
      fi
      mkdir -p "$JHOME/reports" "$JHOME/brain" "$JHOME/data" \\
               "$JHOME/secrets" "$JHOME/models"
      export JARVIS_DIR="$JHOME"
      exec bash "$JHOME/jarvis" "$@"
    WRAPPER
  end

  def caveats
    <<~EOS
      Jarvis needs Claude Code (its brain) installed and logged in:
        https://claude.com/claude-code   — then run: claude

      First start downloads a whisper speech model (~150 MB):
        jarvis doctor    # see what else is needed
        jarvis start     # server + call watcher -> http://localhost:4321

      Recording permissions: run `jarvis setup` — it requests Screen
      Recording + Microphone for "Jarvis Audio" (its own identity; your
      terminal never needs these grants). After upgrades the grant may
      need re-toggling (ad-hoc signature changes).

      Auto-start at login: jarvis service install

      Your data lives in ~/.jarvis (never touched by upgrades).
      Call recording is OFF by default. When you enable it, obtaining the
      other participants' consent is your responsibility — recording is not
      announced to them, and recording laws vary by jurisdiction.
      Grant Microphone + Screen Recording permission when macOS prompts.
    EOS
  end

  test do
    # doctor exits non-zero on a fresh machine (model not downloaded yet);
    # we only assert it runs and reports coherently
    output = shell_output("#{bin}/jarvis doctor 2>&1", 1)
    assert_match "Jarvis doctor", output
  end
end
