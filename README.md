# oh-my-pi.nix

[oh-my-pi](https://github.com/can1357/oh-my-pi) publishes an official Nix flake. This repository also packages it, offering a moving `oh-my-pi` target for the latest upstream release.

Why use this flake?

- **Hands-off updates:** an hourly updater follows new releases, so `nix profile upgrade` picks them up.
- **Linux integrations:** shell completions and Wayland/PipeWire screencasting are enabled by default.
- **Fast installs:** builds are available from the public Cachix cache, and evaluation reads only this repository, so a cached install fetches the package instead of upstream's source tarball.
- **Official binary release:** `oh-my-pi-bin` packages the upstream release binary alongside the source build.
- **Upstream choice:** the same cache also builds and carries upstream's official flake for every release this repository has picked up.

## Install

This flake currently supports `x86_64-linux` only. Patches and pull requests to extend it to additional platforms are welcome.

Fastest path, using the public Cachix cache:

```bash
nix shell nixpkgs#cachix -c cachix use oh-my-pi
nix profile add github:bjin/oh-my-pi.nix#oh-my-pi
```

Directly from GitHub, without configuring Cachix first:

```bash
nix profile add github:bjin/oh-my-pi.nix#oh-my-pi
```

Install the upstream binary package instead:

```bash
nix profile add github:bjin/oh-my-pi.nix#oh-my-pi-bin
```

The same cache also carries `x86_64-linux` builds of upstream's own flake, for every release this repository has picked up, so a released tag installs from upstream directly without building:

```bash
nix shell nixpkgs#cachix -c cachix use oh-my-pi
nix profile add github:can1357/oh-my-pi/v17.3.0
```

After installation, `omp` will be available from your profile.

## Run without installing

```bash
nix run github:bjin/oh-my-pi.nix#oh-my-pi -- --version
```

## Build locally

```bash
nix build .
./result/bin/omp --version
```

The native addons build with the latest stable Rust rather than the nightly upstream pins, with `RUSTC_BOOTSTRAP` unlocking the unstable features upstream relies on. Each `-Ctarget-cpu` variant is a derivation of its own (`.#oh-my-pi.nativeAddons.{baseline,modern}`), so changes to the JS build reuse both.

The source build ships native addons beside the executable rather than extracting an embedded archive into `~/.omp/natives`. Since 18.7.0, the flake disables embedding with `native: null` in upstream's `build-binary.ts`; the previous `embed-native.ts --reset` path no longer exists.
