# remote-agent-operator

Reusable NixOS modules for **agent operator boxes**: headless, always-on
machines that run Claude Code (and Codex) as unprivileged, sandboxed systemd
services you drive from `claude.ai/code` or the Claude mobile app.

An **agent** is one entry in `operator.agents.<name>` — one Linux user = one
Claude license = one `claude remote-control`, with its own checkout, Git
identity, GitHub token, network-egress rules and optional rootless Docker. A box
runs as many as you define (for example a work license and a personal one as
separate users).

The modules know nothing about secrets, disks or monitoring; a consuming flake
supplies those. The reference consumer is a separate private repo
(`remote-operator-setup`), which is also the place to look for the full install
walkthrough (disk, keys, sops, `nixos-anywhere`, `deploy`).

## What it exports

```
nixosModules.standalone  # a complete box: agents + admin, SSH, Tailscale, Nix
nixosModules.agents      # just the agents, for a fleet with its own base profile
nixosModules.default     # = standalone
nixosConfigurations.example          # a buildable box from the module alone
checks.x86_64-linux.example          # CI builds it (nix flake check)
```

`examples/single-box/configuration.nix` is a complete, buildable worked example;
`nix flake check` builds it so a change that breaks the module's composition
fails in CI rather than on a consumer's machine.

## Use it from your own flake

Add this repo as an input and import `nixosModules.standalone`.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    sops-nix.url = "github:Mic92/sops-nix";

    operator.url = "github:pik694/remote-agent-operator";
    # Pin the module's nixpkgs to yours, or you evaluate two nixpkgs trees and
    # can end up with two glibcs in one closure. Do the same for the inputs
    # whose modules you also import (here home-manager).
    operator.inputs.nixpkgs.follows = "nixpkgs";
    operator.inputs.home-manager.follows = "home-manager";
  };

  outputs = { nixpkgs, home-manager, sops-nix, operator, ... }: {
    nixosConfigurations.my-box = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        home-manager.nixosModules.home-manager # the agents use home-manager
        sops-nix.nixosModules.sops             # your secret store of choice
        operator.nixosModules.standalone
        ./hosts/my-box/hardware-configuration.nix
        ./hosts/my-box/disk.nix                # your disk layout (e.g. disko)
        ./hosts/my-box/default.nix             # operator.* options + sops wiring
      ];
    };
  };
}
```

The consumer supplies the `home-manager` and secret-store NixOS modules, the
disk and hardware config, and the `operator.*` options. `claude-code` comes
transitively from this flake — you don't declare it. A fleet that already has
its own admin user, SSH and Tailscale imports `nixosModules.agents` instead of
`standalone` and keeps its own base profile.

Everything the two modules share is set with `lib.mkDefault`, so a consumer can
override it without `lib.mkForce`.

## Defining an agent

```nix
operator.agents.claude-acme = {
  uid = 1002;                        # unique per host
  publicKey = "ssh-ed25519 AAAA...";  # or null for no direct login
  repo.url = "git@github.com:acme/widget.git";
  git.userName = "Jane Doe";
  git.userEmail = "jane+acme@example.com";
  # Token paths only; the module never names a secret store. These come from
  # sops-nix, agenix or a file placed by hand.
  githubTokenFile = config.sops.secrets.gh-acme.path;         # bare token
  githubTokenEnvFile = config.sops.templates."claude-acme.env".path; # GH_TOKEN=...
  docker.enable = true;              # rootless Docker for tests (see limits)
  claudeService.enable = true;
};
```

An agent whose user is `claude-acme` produces three systemd units named after
it: `claude-acme` (the `claude remote-control` service), `claude-acme-checkout`
(clones the repo once GitHub accepts the key) and `claude-acme-git-keys`
(creates the per-repo auth and signing keys on first boot).

**Per-host limits:** uids must be unique; at most one agent may set
`docker.enable = true` (nixpkgs' rootless Docker is host-global); and when a
host runs more than one agent, lower each agent's `claudeService.memoryMax`,
since the 6 GB default won't let two coexist on 8 GB. Each agent's Claude and
Codex logins are established by signing in once as that user — Nix creates the
account and service, not the license.

## Security model

Agents run arbitrary code as their own unprivileged user, so the box treats each
agent account as untrusted and limits what a compromised session can reach. The
rules apply per agent.

| Area | What's enforced |
| --- | --- |
| Accounts | The agent has no sudo, isn't a Nix trusted user, and can't read other home folders (`700`). |
| SSH login | The agent accepts only its own key; the build fails if it matches the admin key. Agent forwarding is disabled. |
| Claude service sandbox | The service sees and writes only its own home. The rest of the system is read-only, other homes are hidden, `/tmp` is private, there are no capabilities or setuid, and kernel settings are protected. Syscall groups agents never need (clock, modules, raw I/O, reboot, swap and others) are denied. Memory is capped (6 GB by default). `systemd-analyze security <user>` rates it 2.6. |
| Network | The agent can reach the internet and the tailnet, plus DNS. Anything else on the LAN or other private ranges is rejected (one iptables chain per agent, keyed on its uid). |
| Docker | Rootless: the daemon runs as the agent (a lingering user service), not root, and the agent isn't in the `docker` group. Containers get only the agent's permissions and follow the network rules above. The socket lives under the agent's home, because the service's `ProtectHome=tmpfs` blanks `/run/user`. |
| Secrets | The GitHub token is read from a path the consumer supplies, readable only by the agent. SSH keys and model logins stay in the agent's home, `600`. |

What this does **not** protect against:

- Anything the agent's credentials allow. Agents can use the GitHub auth key,
  the signing key and `GH_TOKEN`; that's how they push, sign and open PRs. Keep
  those scoped (a dedicated machine account with access to one repo).
- SSH sessions (Claude Desktop, Codex) run as the agent without the systemd
  sandbox. The account, network and secrets limits still apply.
- Within the agent's home, each command can touch anything the agent owns,
  including other worktrees and the SSH keys. Claude Code's own command sandbox
  (bubblewrap) can't run under the service: the unit's /proc protections stop
  bubblewrap mounting `/proc`. This is deliberate; to switch, remove
  `ProtectKernelTunables`, `ProtectKernelLogs` and `ProtectHostname`, and
  install `bubblewrap`.
- The tailnet. Restrict what the box can reach with a Tailscale ACL.

## Layout

| Path | Contents |
| --- | --- |
| `modules/agents/` | The agent template: `operator.agents.<name>` options and the per-agent user, checkout, egress, Docker and Claude service |
| `modules/standalone/` | `operator.standalone`: admin user, SSH, Tailscale, boot and Nix settings for a whole box |
| `examples/single-box/` | A complete box from the module alone; the CI check builds it |
