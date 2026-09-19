# Jarvis · © 2026 Upendra Sengar · MIT License · https://github.com/Upendrasengar/jarvis
class Jarvis < Formula
  desc "Personal AI agent on Claude Code: digests, local call notes, recall"
  homepage "https://github.com/upendrasengar/jarvis"
  url "https://github.com/upendrasengar/jarvis/archive/refs/tags/v0.3.31.tar.gz"
  sha256 "a61f67e61b5fc9bb24e1cfc951fbd921cc3cf8468c88d6b3a8cf87f75cc66af4"
  license "MIT"

  # Node and pnpm are BUILD-only now. The published engine carries the exact
  # interpreter its native modules were compiled against (runtime/node), so a
  # prebuilt install needs no Node from Homebrew at all.
  #
  # That is not a tidiness win, it is the difference between installable and
  # not. Homebrew publishes no macOS Intel bottles for node@22, pnpm, llvm@22
  # or rust, so an Intel machine compiled all four from source — Node, then
  # LLVM (167 MB of source) and Rust (529 MB) purely to build pnpm. Observed on
  # a 2019 quad-core i5: most of a day, if it finished at all.
  #
  # It also ends the ABI problem structurally rather than by convention.
  # better-sqlite3 loaded on the wrong Node fails at dlopen and takes the
  # server with it; shipping the matching runtime makes the mismatch
  # impossible instead of something a settings file must keep getting right.
  head do
    url "https://github.com/upendrasengar/jarvis.git", branch: "main"
    depends_on "pnpm" => :build
    depends_on "node@22" # better-sqlite3 v11 predates node 26's V8 API
  end

  depends_on :macos

  # ffmpeg and whisper-cpp are NOT dependencies, deliberately.
  #
  # Nothing outside call recording and voice touches either — chat, notes, the
  # digest and the brain never invoke them, and call recording is off by
  # default. Requiring them made every install pay for a feature it might
  # never use, which on Intel is not a small tax: Homebrew publishes no macOS
  # Intel bottles for ffmpeg, whisper.cpp, llama.cpp or ggml, so all four are
  # compiled from source before Jarvis can start for the first time.
  #
  # Doctor already reports them under "meetings (optional)" with the exact
  # command to install them, so the capability is one `brew install` away at
  # the moment someone actually wants it.

  uses_from_macos "swift" => :build

  # Prebuilt engine, published per architecture. Its filename carries the Node
  # ABI its native modules were compiled against, because better-sqlite3 loaded
  # on the wrong ABI fails at dlopen and takes the server with it.
  resource "engine" do
    on_arm do
      url "https://github.com/upendrasengar/jarvis/releases/download/v#{Jarvis.version}/jarvis-engine-arm64-node127.tar.gz"
      sha256 "297b3d8e0375e3a2295103bd1d50865e11d2db4824d55f4aae8819434519d204"
    end
    on_intel do
      url "https://github.com/upendrasengar/jarvis/releases/download/v#{Jarvis.version}/jarvis-engine-x86_64-node127.tar.gz"
      sha256 "7fe5d790fc91d6de8d9f38ecd7b7330e161b5f1b933fd7cbb933ad77d8a8633b"
    end
  end

  def install
    # build AND run against node 22 LTS (matches the engine's tested stack)
    # Only the source build needs a Homebrew Node; a prebuilt install brings
    # its own and this path never applies.
    ENV.prepend_path "PATH", formula_opt_bin("node@22") if build.head?

    # A prebuilt engine turns installation into an extract: no pnpm, no Vite,
    # no swiftc on the user's Mac. Architectures without a published artifact
    # fall through to the source build below rather than failing — that is what
    # keeps Intel working while only Apple Silicon is published.
    if build_prebuilt?
      ohai "Installing the prebuilt engine (no compilation needed)"
      resource("engine").stage do
        # Homebrew strips a single leading directory when it stages a resource,
        # so the archive's top-level "jarvis/" is already gone here and the
        # tree sits at the CWD. Globbing "jarvis/*" matched nothing, and
        # `install` on an empty array is only a WARNING — producing a 63 KB
        # install that reported success with no engine in it.
        src = File.directory?("jarvis") ? Dir["jarvis/*"] : Dir["*"]
        odie "prebuilt engine staged empty — the artifact layout changed" if src.empty?
        libexec.install src
      end
      # Check the artifact, not the exit status. Everything above can succeed
      # while installing nothing, which is exactly what happened.
      %w[apps/server/src/index.ts node_modules/better-sqlite3 apps/web/dist/index.html].each do |f|
        odie "prebuilt engine is missing #{f} — refusing a broken install" unless (libexec/f).exist?
      end
      write_wrapper
      return
    end

    # Say WHY this is about to compile. Falling through silently is the same
    # failure this whole effort exists to remove: an install that quietly does
    # the slow thing looks identical to one doing the fast thing, until it is
    # twenty minutes deep in a build log. On an architecture with no published
    # artifact the fallback is correct — but correct and silent is still a bad
    # thing to have to diagnose from scrollback.
    # pnpm is only declared for Intel and --HEAD, so an Apple Silicon release
    # install that somehow reaches here has no way to build. That happens if a
    # release publishes a formula whose artifact upload did not succeed: the
    # checksum stays a placeholder and build_prebuilt? goes false. Fail with
    # the actual reason rather than an obscure "pnpm: command not found" forty
    # lines into a build.
    unless build.head?
      odie <<~MSG
        No prebuilt engine was published for this release and this
        architecture, and the source build is not available (Node and pnpm are
        declared only for --HEAD).

        This usually means the release published a formula without its
        artifact. Please report it, or install the development version:

          brew install --HEAD upendrasengar/jarvis/jarvis
      MSG
    end

    ohai "Building Jarvis from source (this takes a while)"
    if Hardware::CPU.intel?
      opoo "No prebuilt engine is published for Intel, only Apple Silicon. " \
           "This is expected on this Mac, not an error."
    else
      opoo "No prebuilt engine matched this machine; falling back to a source build."
    end

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

    write_wrapper
  end

  # True when a prebuilt engine exists for this architecture. Anything else
  # builds from source, so a new platform degrades to "slower install" rather
  # than "no install".
  def build_prebuilt?
    return false if build.head?

    # A published artifact has a 64-character hex checksum. Testing that rather
    # than a sentinel string means `brew style --fix` cannot quietly rewrite the
    # placeholder into something that reads as publishable.
    engine = resource("engine")
    sum = engine.checksum.to_s
    engine.url.to_s.include?("releases/download") &&
      sum.match?(/\A[0-9a-f]{64}\z/) &&
      # all-zeros is the unpublished placeholder — it is valid hex, so the
      # shape test alone would send an unreleased formula chasing an artifact
      # that does not exist yet
      sum != ("0" * 64)
  rescue
    false
  end

  def write_wrapper
    (bin/"jarvis").write <<~WRAPPER
      #!/bin/bash
      # jarvis — Homebrew wrapper. Engine (read-only) lives in the cellar;
      # everything Jarvis knows about YOU lives in $JARVIS_HOME (~/.jarvis),
      # overlaid with symlinks so upgrades never touch your data.
      set -u
      # NOTE: this runs BEFORE ENGINE= is assigned below, so it interpolates
      # the cellar path directly rather than using $ENGINE — under `set -u` a
      # forward reference kills every invocation of `jarvis`.
      #
      # The engine ships the interpreter its native modules were built for.
      # Fall back to a Homebrew Node only for a source (--HEAD) install, which
      # has no bundled runtime.
      if [ -x "#{opt_libexec}/runtime/node" ]; then
        export JARVIS_NODE="#{opt_libexec}/runtime/node"
      elif [ -x "#{formula_opt_bin("node@22")}/node" ]; then
        export PATH="#{formula_opt_bin("node@22")}:$PATH"
        export JARVIS_NODE="#{formula_opt_bin("node@22")}/node"
      fi
      ENGINE="#{opt_libexec}"
      JHOME="${JARVIS_HOME:-$HOME/.jarvis}"
      mkdir -p "$JHOME"
      # runtime belongs here for the same reason artifact.json does: scripts
      # resolve the interpreter as $JARVIS_DIR/runtime/node, and without the
      # link that path does not exist on an installed copy. It worked only
      # because the wrapper also exports JARVIS_NODE — one path happening to
      # cover for another that was missing.
      #
      # artifact.json belongs in this list: it records the version, commit and
      # Node ABI of the installed engine, and three things read it from
      # $JARVIS_DIR — services.sh's ABI guard before starting the server,
      # doctor's ABI mismatch check, and the version the dashboard shows.
      # Omitted, all three silently found nothing and reported no problem, on
      # precisely the installs they exist to protect.
      for item in apps packages tools node_modules package.json artifact.json runtime \\
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

  # Two lines a person will actually read, then one command that does the
  # rest. The previous version listed six commands across twenty-five lines
  # with no indication of which to run first, buried the prerequisite
  # (Claude Code) in the middle, and explained WHY signing matters before
  # saying what to type. `jarvis onboard` already checks every prerequisite,
  # installs what it can, and explains what it cannot — so point at it and
  # stop reprinting its job here.
  def caveats
    <<~EOS
      Next step:

        jarvis onboard     guided setup — checks everything, fixes what it can
        jarvis help        every command, grouped

      Jarvis thinks with Claude Code, so install and sign in to that first:
        https://claude.com/claude-code

      Call recording needs two extra tools, installed only if you want it:
        brew install ffmpeg whisper.cpp

      Your data lives in ~/.jarvis and is never touched by upgrades.
      Recording is OFF by default. It is not announced to other participants,
      consent is your responsibility, and the law varies by jurisdiction.
    EOS
  end

  test do
    # Everything here runs against a throwaway JARVIS_HOME, so the test can
    # never touch a real installation's vault, secrets or services.
    home = testpath/"jarvis-home"
    ENV["JARVIS_HOME"] = home.to_s

    # 1. Doctor runs and reports coherently. It exits non-zero on a fresh
    #    machine (no whisper model yet), which is a finding, not a crash.
    human = shell_output("#{bin}/jarvis doctor 2>&1", 1)
    assert_match "Jarvis doctor", human

    # 2. The machine-readable form is valid JSON with classified checks —
    #    this is what the browser onboarding consumes.
    require "json"
    report = JSON.parse(shell_output("#{bin}/jarvis doctor --json 2>/dev/null", 1))
    assert_kind_of Array, report["checks"]
    refute_empty report["checks"]
    known = %w[pass warning blocked optional]
    unknown = report["checks"].reject { |c| known.include?(c["status"]) }
    assert_empty unknown, "doctor reported a check with an unknown status"

    # 3. The native module loads under the packaged Node. This is the failure
    #    a prebuilt artifact can silently ship: an ABI mismatch surfaces only
    #    at dlopen, long after install has reported success.
    # Test what ships: the bundled runtime when there is one, since that is
    # what every prebuilt install will load better-sqlite3 with.
    node = (opt_libexec/"runtime/node").exist? ? opt_libexec/"runtime/node" : formula_opt_bin("node@22")/"node"
    system node, "-e", <<~JS
      const db = require("#{opt_libexec}/node_modules/better-sqlite3");
      new db(":memory:").prepare("select 1 as ok").get();
    JS

    # 4. The server actually boots and answers. An install that cannot serve
    #    /api/health is broken no matter how cleanly it unpacked.
    port = free_port
    pid = spawn({ "JARVIS_HOME" => home.to_s, "JARVIS_UI_PORT" => port.to_s },
                "#{bin}/jarvis", "start", out: File::NULL, err: File::NULL)
    begin
      healthy = false
      30.times do
        sleep 1
        healthy = system("/usr/bin/curl", "-fsS", "http://127.0.0.1:#{port}/api/health",
                         out: File::NULL, err: File::NULL)
        break if healthy
      end
      assert healthy, "the server did not answer /api/health within 30s"
    ensure
      system "#{bin}/jarvis", "stop", out: File::NULL, err: File::NULL
      begin
        Process.kill("TERM", pid)
      rescue
        nil
      end
    end
  end
end
