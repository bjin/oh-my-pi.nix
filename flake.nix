{
  description = "Package oh-my-pi from source and upstream binaries";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    bun2nix = {
      url = "github:nix-community/bun2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-bun = {
      url = "github:ryoppippi/nix-bun";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      bun2nix,
      nix-bun,
      rust-overlay,
      # `self` is always passed; this flake has no use for it.
      ...
    }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      pname = "oh-my-pi";
      binData = builtins.fromJSON (builtins.readFile ./bin-hashes.json);

      # Everything evaluation needs to know about the upstream release lives in
      # this repository: `hashes.json` holds the scalars and the release
      # tarball's hash, `upstream/` holds verbatim copies of the files the
      # derivation parses. Reading any of it out of the tarball instead — the
      # way a `flake = false` source input invites — would make every
      # evaluation, `nix profile add` included, download 44 MiB from GitHub
      # before Nix could even name the derivation, let alone substitute it from
      # the binary cache.
      #
      # Pinned by commit, not by tag: upstream force-moves release tags onto new
      # commits. `scripts/update.py` resolves the tag with `git ls-remote`,
      # records the commit it saw, and rewrites the pin and `upstream/` with it.
      srcData = builtins.fromJSON (builtins.readFile ./hashes.json);
      sourceVersion = srcData.version;

      # One Bun release runs the build and is embedded in the binary, so the pin
      # must clear both floors upstream declares: `engines.bun` (>=1.3.14), which
      # `cli.ts` enforces at startup for its unguarded `Bun.Image` calls, and the
      # root `packageManager` (bun@>=1.4). The latter is load bearing —
      # `bytecode: true` in `compile-binary.ts` switches Bun's output format to
      # CommonJS, and only 1.4 lowers this graph's `import.meta.resolve` out of
      # that program wrapper; 1.3.x emits no bytecode and dies before `main`
      # with `TypeError: Expected CommonJS module to have a function wrapper`.
      # nixpkgs' bun (1.3.13) clears neither floor, hence nix-bun;
      # `scripts/update.py` rechecks the pin on every update.
      requiredBunVersion = srcData.bunVersion;
      bunSourcesFile = nix-bun + "/versions/${requiredBunVersion}.json";

      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          rust-overlay.overlays.default
          bun2nix.overlays.default
          (final: _previous: {
            bun =
              if builtins.pathExists bunSourcesFile then
                final.callPackage (nix-bun + "/package.nix") { sourcesFile = bunSourcesFile; }
              else
                throw "nix-bun packages no Bun ${requiredBunVersion}; update the nix-bun input";
          })
        ];
      };

      # A fixed-output fetch rather than a flake input: the store path follows
      # from `hashes.json` alone, so nothing is downloaded until something
      # actually builds from source.
      sourceSrc = pkgs.fetchzip {
        name = "${pname}-${sourceVersion}-source";
        url = "https://github.com/can1357/oh-my-pi/archive/${srcData.rev}.tar.gz";
        hash = srcData.hash;
      };

      # `--smoke-test` starts a daemon broker whose runtime directory is a
      # `mkdtemp` straight under `os.tmpdir()` (upstream
      # `launch/client.ts:smokeTestDaemonBroker`), and every broker sweeps that
      # directory's *siblings*: 17.3.5's `pruneDeadDaemonRuntimeDirs` deletes
      # each neighbouring directory that has no live broker and has not been
      # touched for five minutes. Rooted at the builder's `TMPDIR` that sweep
      # reaches `$NIX_BUILD_TOP/source` — this phase's own working directory —
      # once the build outlives the grace period, and the next worker thread
      # then dies in `getcwd` with `CurrentWorkingDirectoryUnlinked`. Give omp a
      # private, freshly created tmpdir so the sweep only ever sees scratch
      # directories the check itself just made.
      installCheckEnvironment = ''
        export HOME="$TMPDIR/check-home"
        export XDG_DATA_HOME="$TMPDIR/check-xdg-data"
        export TMPDIR="$TMPDIR/check-tmp"
        export TMP="$TMPDIR" TEMP="$TMPDIR" TEMPDIR="$TMPDIR"
        mkdir -p "$HOME" "$XDG_DATA_HOME/omp" "$TMPDIR"
      '';
      installShellCompletions = ''
        completion_dir="$TMPDIR/completions"
        completion_runtime_dir="$TMPDIR/completion-runtime"
        rm -rf "$completion_dir" "$completion_runtime_dir"
        mkdir -p "$completion_dir" "$completion_runtime_dir/home" "$completion_runtime_dir/xdg"

        HOME="$completion_runtime_dir/home" XDG_DATA_HOME="$completion_runtime_dir/xdg" \
          "$out/bin/omp" completions bash > "$completion_dir/omp.bash"
        HOME="$completion_runtime_dir/home" XDG_DATA_HOME="$completion_runtime_dir/xdg" \
          "$out/bin/omp" completions zsh > "$completion_dir/_omp"
        HOME="$completion_runtime_dir/home" XDG_DATA_HOME="$completion_runtime_dir/xdg" \
          "$out/bin/omp" completions fish > "$completion_dir/omp.fish"

        installShellCompletion --bash --name omp "$completion_dir/omp.bash"
        installShellCompletion --zsh --name _omp "$completion_dir/_omp"
        installShellCompletion --fish --name omp.fish "$completion_dir/omp.fish"
      '';
      installCheckCompletions = ''
        test -s "$out/share/bash-completion/completions/omp"
        test -s "$out/share/zsh/site-functions/_omp"
        test -s "$out/share/fish/vendor_completions.d/omp.fish"
      '';
      # `pi-voice` dlopens these by bare name, so nothing links them and
      # autoPatchelf cannot discover them: PulseAudio drives `/live` capture and
      # ALSA is its fallback device backend.
      dlopenedAudioLibraries = [
        pkgs.libpulseaudio
        pkgs.alsa-lib
      ];
      useLooseNativeAddons = ''
        # Nix ships native addons as loose .node files next to the compiled
        # executable. Reuse upstream's reset path so the standalone binary does
        # not embed a compressed native archive that every new version would
        # unpack into ~/.omp/natives (138 MiB per release) on first start; the
        # loader then falls back to those loose files from process.execPath's
        # directory.
        substituteInPlace packages/natives/scripts/embed-native.ts \
          --replace-fail 'process.argv.includes("--reset")' \
            'true'
      '';
      # `bun2nix`'s hook runs `patchShebangs .`, so `cli.ts` carries
      # `#!${pkgs.bun}/bin/bun` by the time Bun bundles it, and Bun copies the
      # entry shebang verbatim into the payload — a store reference in a binary
      # that never execs it. Drop the line instead of rewriting the finished
      # payload: `remove-references-to` edits the embedded source JSC keys its
      # bytecode cache on (the 1.4 CommonJS payload survives it, the ESM one
      # does not), and a rejected cache still starts, just 7x slower. `//` keeps
      # the line numbering stack traces report.
      stripEntrypointShebang = ''
        substituteInPlace packages/coding-agent/src/cli.ts \
          --replace-fail '#!/usr/bin/env bun' '//'
      '';
      commonMeta = {
        description = "AI coding agent for the terminal";
        homepage = "https://github.com/can1357/oh-my-pi";
        license = lib.licenses.mit;
        mainProgram = "omp";
        platforms = [ system ];
      };

      rustTarget = "x86_64-unknown-linux-gnu";
      # Upstream drives the shipping addons through Bazel since 17.1.6, but the
      # rule (upstream `bazel/defs.bzl`, `crates/pi-natives/BUILD.bazel`) only
      # compiles the `pi_natives` cdylib at opt/thin-LTO/cgu=16/strip-symbols —
      # exactly the cargo `ci` profile — with a per-variant `-Ctarget-cpu` floor,
      # then renames it to the loader's canonical filename. Cargo covers that, so
      # the build stays Bazel-free. The napi CLI is not needed either:
      # `packages/natives/native/index.{js,d.ts}` are committed and regenerated
      # only when the Rust API changes.
      nativeAddonVariants = {
        baseline = "x86-64-v2";
        modern = "x86-64-v3";
      };
      nativeAddonFile = variant: "pi_natives.linux-x64-${variant}.node";
      buildNativeAddons = ''
        # pcre2-sys links a pkg-config libpcre2 when it finds one; upstream
        # release builds force the vendored static build instead.
        export PCRE2_SYS_STATIC=1
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (variant: targetCpu: ''

          echo "Building pi_natives addon: ${variant} (-Ctarget-cpu=${targetCpu})"
          RUSTFLAGS="-C target-cpu=${targetCpu}" \
            cargo build --offline --profile ci --package pi-natives \
              ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux "--features wayland-pipewire"} \
              --target ${rustTarget}
          install -Dm755 "$CARGO_TARGET_DIR/${rustTarget}/ci/libpi_natives.so" \
            "packages/natives/native/${nativeAddonFile variant}"
        '') nativeAddonVariants
      );
      installNativeAddons = lib.concatStrings (
        lib.mapAttrsToList (variant: _: ''
          install -Dm755 "packages/natives/native/${nativeAddonFile variant}" \
            "$out/lib/omp/${nativeAddonFile variant}"
        '') nativeAddonVariants
      );
      addonAudioRunpath = lib.concatStrings (
        lib.mapAttrsToList (variant: _: ''
          patchelf --add-rpath "${lib.makeLibraryPath dlopenedAudioLibraries}" \
            "$out/lib/omp/${nativeAddonFile variant}"
        '') nativeAddonVariants
      );
      checkNativeAddons = lib.concatStrings (
        lib.mapAttrsToList (variant: _: ''
          test -x "$out/lib/omp/${nativeAddonFile variant}"
        '') nativeAddonVariants
      );

      rustToolchainChannel = srcData.rustToolchainChannel;
      toolchainWithTarget =
        let
          nightlyDateMatch = builtins.match "nightly-(.+)" rustToolchainChannel;
          stableVersionMatch = builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" rustToolchainChannel;
          baseToolchain =
            if nightlyDateMatch != null then
              pkgs.rust-bin.nightly."${builtins.head nightlyDateMatch}".minimal
            else if rustToolchainChannel == "nightly" then
              pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.minimal)
            else if rustToolchainChannel == "stable" then
              pkgs.rust-bin.stable.latest.minimal
            else if rustToolchainChannel == "beta" then
              pkgs.rust-bin.beta.latest.minimal
            else if stableVersionMatch != null then
              pkgs.rust-bin.stable."${rustToolchainChannel}".minimal
            else
              throw "Unsupported rustToolchainChannel: ${rustToolchainChannel}";
        in
        baseToolchain.override {
          targets = [ rustTarget ];
        };

      rustPlatform = pkgs.makeRustPlatform {
        cargo = toolchainWithTarget;
        rustc = toolchainWithTarget;
      };

      # `fetchBunDeps` hands the file to `pkgs.callPackage`, whose autofill
      # supplies `copyPathToStore` — an eval-time `builtins.path`. Upstream
      # applies it to every workspace member through a path relative to
      # `bun.nix` itself (`copyPathToStore ../packages/agent`), and the verbatim
      # copy keeps that spelling, so those literals land beside `upstream/`,
      # where nothing exists. Redirect them into the fetched tree, and copy in a
      # derivation: an eval-time copy would realise `sourceSrc`, downloading the
      # tarball during evaluation.
      #
      # The root comes from `bunNixFile` itself, through `toString`. Anything
      # else drifts: interpolating a directory (`"${./.}"`) copies the whole
      # working tree into the store a second time, under a path that no longer
      # prefixes the literals it is meant to strip.
      bunNixFile = ./upstream/bun.nix;
      bunNixRoot = dirOf (dirOf (toString bunNixFile));
      bunWorkspaceMember =
        path:
        let
          relative = lib.removePrefix "${bunNixRoot}/" (toString path);
        in
        if lib.hasPrefix "/" relative then
          throw "upstream/bun.nix reads ${toString path}, which is outside ${bunNixRoot}"
        else
          pkgs.runCommandLocal "bun-workspace-${baseNameOf relative}" { } ''
            cp -r "${sourceSrc}/${relative}" "$out"
          '';
      bunNix =
        args:
        import bunNixFile (
          {
            inherit (pkgs) fetchFromGitHub fetchgit fetchurl;
            copyPathToStore = bunWorkspaceMember;
          }
          // args
        );

      bunDeps = pkgs.bun2nix.fetchBunDeps {
        inherit bunNix;
        overrides = pkgs.bun2nix.patchedDependenciesToOverrides {
          # Applying a patch copies it into the store during evaluation, so
          # these have to be repository files as well.
          patchedDependencies = lib.mapAttrs (_: patch: ./upstream + "/${patch}") srcData.patchedDependencies;
        };
      };

      ohMyPi = pkgs.stdenv.mkDerivation {
        inherit pname bunDeps;
        version = sourceVersion;
        src = sourceSrc;

        cargoDeps = rustPlatform.importCargoLock {
          lockFile = ./upstream/Cargo.lock;
        };

        nativeBuildInputs = [
          pkgs.autoPatchelfHook
          pkgs.bun
          pkgs.bun2nix.hook
          # `opusic-sys` — the `-sys` layer under the `opus` crate — has no
          # system-libopus path: its default `bundled` feature always compiles
          # and statically links the libopus it vendors, with CMake.
          pkgs.cmake
          pkgs.installShellFiles
          # Upstream's `.cargo/config.toml` pins `CMAKE_GENERATOR=Ninja` for the
          # whole workspace, so every cmake-rs build script configures with `-G
          # Ninja` and dies unless that generator's build program is on PATH.
          pkgs.ninja
          pkgs.pkg-config
          toolchainWithTarget
          rustPlatform.cargoSetupHook
          # `pipewire-sys` and `libspa-sys` generate bindings with libclang; this
          # hook also provides their Nix libc include flags.
          rustPlatform.bindgenHook
        ];

        buildInputs = [
          pkgs.stdenv.cc.cc.lib
          pkgs.zlib
          # `pi-natives`' `wayland-pipewire` feature links system libpipewire
          # through pkg-config.
          pkgs.pipewire
        ];
        strictDeps = true;
        dontConfigure = true;
        # CMake belongs to `opusic-sys`, not this derivation's source root.
        dontUseCmakeConfigure = true;
        dontStrip = true;
        # Nix builders cannot hardlink cache files into node_modules.
        bunInstallFlags = [
          "--linker=isolated"
          "--backend=copyfile"
        ];
        dontRunLifecycleScripts = true;

        postPatch = useLooseNativeAddons + stripEntrypointShebang;

        buildPhase = ''
          runHook preBuild

          export HOME="$TMPDIR/home"
          export XDG_CACHE_HOME="$TMPDIR/xdg-cache"
          export CARGO_TARGET_DIR="$TMPDIR/cargo-target"
          mkdir -p "$HOME" "$XDG_CACHE_HOME" "$CARGO_TARGET_DIR"
          export LD_LIBRARY_PATH="${lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]}"

          ${buildNativeAddons}

          bun --cwd=packages/coding-agent run build

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          install -Dm755 packages/coding-agent/dist/omp "$out/lib/omp/omp"
          ${installNativeAddons}
          install -d "$out/bin"
          # A symlink, not a wrapper: process.execPath resolves through it to
          # the real binary, so the loader still finds the loose addons beside
          # it, and no LD_LIBRARY_PATH leaks into everything omp spawns.
          ln -s ../lib/omp/omp "$out/bin/omp"
          install -Dm644 LICENSE "$out/share/licenses/${pname}/LICENSE"

          runHook postInstall
        '';

        preFixup = ''
          ohMyPiPostFixup() {
            ${addonAudioRunpath}
            ${installShellCompletions}
          }
          postFixupHooks+=(ohMyPiPostFixup)
        '';
        # Without the entry shebang the payload holds no store path at all, so a
        # reappearing Bun reference means the shebang came back.
        disallowedReferences = [ pkgs.bun ];

        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck

          ${installCheckEnvironment}
          smoke_output=$("$out/bin/omp" --smoke-test)
          if [ "$smoke_output" != "smoke-test: ok" ]; then
            echo "unexpected smoke test output: $smoke_output"
            exit 1
          fi

          bun_runtime=$(BUN_BE_BUN=1 "$out/bin/omp" \
            -e 'console.log(`''${Bun.version} ''${typeof Bun.Image}`)')
          if [ "$bun_runtime" != "${requiredBunVersion} function" ]; then
            echo "unexpected embedded Bun runtime: $bun_runtime"
            exit 1
          fi

          # Bytecode costs +52 MiB and pays for it only while JSC accepts it:
          # `--version` on 18.2.2 takes 67 ms on a hit and 499 ms on a miss, and
          # a miss still starts. JSC reports the verdict on stderr.
          if ! BUN_JSC_verboseDiskCache=1 "$out/bin/omp" --version 2>&1 >/dev/null |
            grep -q 'Cache hit for sourceCode'; then
            echo "startup rejected the embedded JSC bytecode"
            exit 1
          fi

          ${installCheckCompletions}

          ${checkNativeAddons}
          if [ -e "$XDG_DATA_HOME/omp/natives" ] || [ -e "$HOME/.omp/natives" ]; then
            echo "omp wrote native addons to a user cache"
            exit 1
          fi

          runHook postInstallCheck
        '';

        passthru = {
          inherit bunDeps toolchainWithTarget;
          bun = pkgs.bun;
        };

        meta = commonMeta;
      };

      binVersion = binData.version;
      binAssetNames = {
        x86_64-linux = "omp-linux-x64";
      };
      binAssetName = binAssetNames.${system} or (throw "oh-my-pi-bin is not packaged for ${system}");
      binHash = binData.hashes.${system} or (throw "missing oh-my-pi-bin hash for ${system}");
      binSrc = pkgs.fetchurl {
        url = "https://github.com/can1357/oh-my-pi/releases/download/v${binVersion}/${binAssetName}";
        hash = binHash;
      };

      ohMyPiBin = pkgs.stdenv.mkDerivation {
        pname = "${pname}-bin";
        version = binVersion;
        src = binSrc;

        nativeBuildInputs = [
          pkgs.autoPatchelfHook
          pkgs.makeWrapper
          pkgs.installShellFiles
        ];
        buildInputs = [
          pkgs.stdenv.cc.cc.lib
          pkgs.zlib
        ];
        strictDeps = true;
        dontUnpack = true;
        dontConfigure = true;
        dontBuild = true;
        dontStrip = true;

        installPhase = ''
          runHook preInstall

          install -Dm755 "$src" "$out/lib/omp/omp"
          # Release binaries embed a compressed addon that is unpacked into
          # ~/.omp/natives at first start, so its dlopen()s cannot be resolved
          # with patchelf the way the source build does it. Upstream ships the
          # addon without the pipewire link, so PulseAudio and ALSA are the only
          # libraries the loader path has to provide.
          makeWrapper "$out/lib/omp/omp" "$out/bin/omp" \
            --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath dlopenedAudioLibraries}"

          runHook postInstall
        '';

        preFixup = ''
          installShellCompletionsHook() {
            ${installShellCompletions}
          }
          postFixupHooks+=(installShellCompletionsHook)
        '';

        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck

          ${installCheckEnvironment}
          smoke_output=$("$out/bin/omp" --smoke-test)
          if [ "$smoke_output" != "smoke-test: ok" ]; then
            echo "unexpected smoke test output: $smoke_output"
            exit 1
          fi

          ${installCheckCompletions}

          runHook postInstallCheck
        '';

        meta = commonMeta;
      };
    in
    {
      formatter.${system} = pkgs.nixfmt;

      packages.${system} = {
        default = ohMyPi;
        "oh-my-pi" = ohMyPi;
        "oh-my-pi-bin" = ohMyPiBin;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${ohMyPi}/bin/omp";
        };
        "oh-my-pi" = {
          type = "app";
          program = "${ohMyPi}/bin/omp";
        };
        "oh-my-pi-bin" = {
          type = "app";
          program = "${ohMyPiBin}/bin/omp";
        };
      };
    };
}
