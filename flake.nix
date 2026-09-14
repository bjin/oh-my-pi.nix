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

      # `cli.ts` enforces `engines.bun` at startup and every `Bun.Image` caller
      # relies on it unguarded, so the entire build runs on exactly that Bun
      # release; nixpkgs' bun trails it (1.3.13 against a >=1.3.14 floor).
      # `scripts/update.py` resolves that floor to the version it records here.
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
          --replace-fail 'const reset = process.argv.includes("--reset");' \
            'const reset = true;'
      '';
      # `collab-cli.ts` is the one file in the tree that imports the npm
      # `chalk`; the ~60 other call sites import `@oh-my-pi/pi-utils/chalk`,
      # the behaviour-compatible reimplementation that lives in the repository.
      # No workspace manifest declares `chalk`, so that import resolves only
      # where a hoisted `node_modules` lifts chalk@4.1.2 to the root as a
      # transitive dependency of the `@typescript/analyze-trace` devtool.
      # bun2nix installs with `--linker=isolated`, which gives every package
      # exactly its declared dependencies, so the phantom import surfaces as
      # `Could not resolve: "chalk"` out of `Bun.build`. Point it at the sibling
      # module the rest of the tree uses.
      #
      # Drop this once can1357/oh-my-pi#12003 lands upstream; until then
      # `--replace-fail` is what makes the patch retire itself loudly rather
      # than silently going stale.
      useInternalChalk = ''
        substituteInPlace packages/coding-agent/src/cli/collab-cli.ts \
          --replace-fail 'import chalk from "chalk";' \
            'import chalk from "@oh-my-pi/pi-utils/chalk";'
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
        # `audiopus_sys`' bundled opus fallback declares a
        # cmake_minimum_required below what CMake 4.x accepts unaided.
        export CMAKE_POLICY_VERSION_MINIMUM=3.5
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

      # Bun's standalone writer corrupts patchelf'd templates until
      # oven-sh/bun#31024 ships (oven-sh/bun#31023), so the payload is written
      # into the pristine release binary from the same Bun the build runs on.
      bunRuntimeTemplate = pkgs.stdenvNoCC.mkDerivation {
        pname = "omp-bun-runtime-template";
        inherit (pkgs.bun) version;
        src = pkgs.bun.src;

        nativeBuildInputs = [ pkgs.unzip ];
        strictDeps = true;
        dontUnpack = true;
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;

        installPhase = ''
          runHook preInstall

          unzip -q "$src"
          install -Dm755 bun-*/bun "$out/libexec/bun"

          runHook postInstall
        '';
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
          # `audiopus_sys` builds its vendored static libopus fallback with CMake.
          pkgs.cmake
          pkgs.installShellFiles
          pkgs.pkg-config
          pkgs.removeReferencesTo
          toolchainWithTarget
          rustPlatform.cargoSetupHook
          # `maudio-sys` generates bindings with libclang; this hook also provides
          # its Nix libc include flags.
          rustPlatform.bindgenHook
        ];

        buildInputs = [
          pkgs.stdenv.cc.cc.lib
          # `audiopus_sys` enables its `static` feature; pkg-config locates this
          # libopus archive instead of falling back to the bundled CMake build.
          pkgs.opus
          pkgs.zlib
          # `pi-natives`' `wayland-pipewire` feature links system libpipewire
          # through pkg-config.
          pkgs.pipewire
        ];
        strictDeps = true;
        dontConfigure = true;
        # CMake belongs to `audiopus_sys`, not this derivation's source root.
        dontUseCmakeConfigure = true;
        dontStrip = true;
        # Nix builders cannot hardlink cache files into node_modules.
        bunInstallFlags = [
          "--linker=isolated"
          "--backend=copyfile"
        ];
        dontRunLifecycleScripts = true;

        env = {
          # Upstream reads this in `packages/coding-agent/scripts/build-binary.ts`
          # and hands it to `Bun.build`'s `compile.executablePath`.
          BUN_COMPILE_EXECUTABLE_PATH = "${bunRuntimeTemplate}/libexec/bun";
        };

        postPatch = useLooseNativeAddons + useInternalChalk;

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

        # Bun's bundler stamps the building interpreter's shebang
        # (`#!${pkgs.bun}/bin/bun`) onto the embedded entry module, which the
        # reference scanner turns into a runtime dependency on a Bun the
        # standalone binary never executes. Strip it before fixup; the mangled
        # shebang stays inert and `disallowedReferences` catches regressions.
        preFixup = ''
          remove-references-to -t ${pkgs.bun} "$out/lib/omp/omp"

          ohMyPiPostFixup() {
            ${addonAudioRunpath}
            ${installShellCompletions}
          }
          postFixupHooks+=(ohMyPiPostFixup)
        '';
        disallowedReferences = [
          pkgs.bun
          bunRuntimeTemplate
        ];

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

          ${installCheckCompletions}

          ${checkNativeAddons}
          if [ -e "$XDG_DATA_HOME/omp/natives" ] || [ -e "$HOME/.omp/natives" ]; then
            echo "omp wrote native addons to a user cache"
            exit 1
          fi

          runHook postInstallCheck
        '';

        passthru = {
          inherit
            bunDeps
            bunRuntimeTemplate
            toolchainWithTarget
            ;
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
