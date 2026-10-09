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
(`homelab`), which is also the place to look for the full install
walkthrough (disk, keys, sops, `nixos-anywhere`, `deploy`).

## What it exports

```
nixosModules.standalone  # a complete box: agents + admin, SSH, Tailscale, Nix
nixosModules.agents      # just the agents, for a fleet with its own base profile
nixosModules.default     # = standalone
nixosConfigurations.example          # a buildable box from the module alone
checks.x86_64-linux.example          # CI builds it (nix flake check)
checks.x86_64-linux.network-namespace         # VM test of network.namespace
checks.x86_64-linux.network-namespace-subnets # namespace subnet collision check
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
account and service, not the license (see "Bringing an agent up").

## Bringing an agent up

After the first deploy with a new agent (here `claude-acme`, working on
`widget`), as the admin on the box:

1. **Register its GitHub keys.** `claude-acme-git-keys` has created them;
   print the public halves:
   ```sh
   sudo cat ~claude-acme/.ssh/widget-gh-auth.pub ~claude-acme/.ssh/widget-gh-signing.pub
   ```
   On the GitHub account the agent acts as, add the first as an
   **Authentication** key and the second as a **Signing** key. (A deploy key
   works for the first if the repository accepts them.) `claude-acme-checkout`
   retries every minute and clones the repository once GitHub accepts the key;
   `systemctl status claude-acme-checkout` shows when it has.
2. **Join its tailnet** — only with `network.namespace.tailscale.enable`, and
   only without an `authKeyFile` (with one, `claude-acme-tailscale-autoconnect`
   has already logged it in):
   ```sh
   sudo tailscale --socket=/run/claude-acme-tailscale/tailscaled.sock up \
     --hostname=<host>-<owner>-claude-agent
   ```
   and open the printed link with the account of the tailnet the agent should
   join.
3. **Sign in as the agent.** Open a shell as `claude-acme`: `sudo
   claude-acme-shell` with `network.namespace`, otherwise `sudo -iu
   claude-acme`. In it:
   1. `cd ~/widget && claude auth login`, then start `claude` once and accept
      the workspace trust prompt.
   2. Run `claude remote-control` once, accept its confirmation, and stop it
      with Ctrl-C; from now on the service runs it.
   3. Optionally `codex login --device-auth` (device code login has to be
      enabled in the ChatGPT account's security settings).
   4. Check `claude auth status`, `gh auth status` and, if signed in,
      `codex login status`.
4. **Start the service** with the new login and check it:
   ```sh
   sudo systemctl restart claude-acme
   systemctl status claude-acme
   ```
   The box now shows up as an environment in `claude.ai/code` and the Claude
   app.

The keys have no passphrase, so the agent can use them after a reboot. A
reinstall creates new keys and a new login: repeat these steps.

## Its own network and tailnet

By default an agent shares the host's network: it reaches the internet and the
host's tailnet. To give it a tailnet of its own instead — say the box sits in
your homelab tailnet but the agent needs your work tailnet's databases and
APIs — give it its own network namespace with a `tailscaled` inside:

```nix
operator.agents.claude-acme.network.namespace = {
  enable = true;
  tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets.claude-acme-tailscale-auth-key.path;  # optional
    # hostname = "...";        # default: <networking.hostName>-<operator.owner>-claude-agent
    # extraUpFlags = [ "--advertise-tags=tag:agent" ];
  };
  # nameservers = [ "1.1.1.1" "9.9.9.9" ];  # until the tailnet's MagicDNS takes over
};
```

The namespace (`/run/netns/<user>`) is joined to the host by a veth pair on
`10.233.<uid mod 256>.0/30` and NATed to the internet only. From inside it, the
LAN, the other private ranges, the host's tailnet (100.64.0.0/10) and every
service on the host itself are unreachable. Its DNS is its own
(`/etc/netns/<user>/resolv.conf`), and nscd is hidden from the agent so lookups
don't fall back to the host's resolvers.

The agent's `claude remote-control` service, and so every session it spawns,
runs in the namespace. So does `<user>-tailscaled`, with its own state and
socket. With an `authKeyFile`, `<user>-tailscale-autoconnect` logs it in
whenever it is logged out (a reusable or pre-approved key from the tailnet the
agent should join); a control server it can't reach fails that unit, which
retries every 30 seconds, rather than holding up boot or a deploy. Without
one, log it in once by hand (see "Bringing an agent up").

Its device is named `<networking.hostName>-<operator.owner>-claude-agent`, so
its owner can find it in a shared tailnet; `operator.owner` defaults to the
standalone module's admin user.

Its MagicDNS then applies to the agent only, so `psql -h db.<tailnet>.ts.net`
works as on a laptop in that tailnet. For a shell with the same view — to log
in to Claude, run `psql`, or check what the agent sees — use

```sh
sudo <user>-shell                 # interactive login shell as the agent
sudo <user>-shell -c 'psql ...'   # one command
```

Limits:

- Rootless Docker stays in the host's namespace (the user service manager can't
  join another one), so containers reach the internet but neither tailnet.
- Agents on one host need uids that differ modulo 256; the build fails
  otherwise.
- The firewall rules use iptables, like the rest of the module.
- The host's nscd keeps `/run/nscd` across restarts (`RuntimeDirectoryPreserve`),
  so the agent's units stay cut off from it; otherwise every nscd restart would
  hand them the host's resolvers again.

## Security model

Agents run arbitrary code as their own unprivileged user, so the box treats each
agent account as untrusted and limits what a compromised session can reach. The
rules apply per agent.

| Area | What's enforced |
| --- | --- |
| Accounts | The agent has no sudo, isn't a Nix trusted user, and can't read other home folders (`700`). |
| SSH login | The agent accepts only its own key; the build fails if it matches the admin key. Agent forwarding is disabled. |
| Claude service sandbox | The service sees and writes only its own home. The rest of the system is read-only, other homes are hidden, `/tmp` is private, there are no capabilities or setuid, and kernel settings are protected. Syscall groups agents never need (clock, modules, raw I/O, reboot, swap and others) are denied. Memory is capped (6 GB by default). `systemd-analyze security <user>` rates it 2.6. |
| Network | The agent can reach the internet and the tailnet, plus DNS. Anything else on the LAN or other private ranges is rejected (one iptables chain per agent, keyed on its uid). With `network.namespace`, the agent's service runs in a namespace that reaches the internet and its own tailnet only, and what it still runs on the host (Docker) is kept off the host's tailnet too. |
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
- The tailnet. Restrict what the box can reach with a Tailscale ACL, or give
  the agent its own (see "Its own network and tailnet").

## Layout

| Path | Contents |
| --- | --- |
| `modules/agents/` | The agent template: `operator.agents.<name>` options and the per-agent user, checkout, egress, Docker and Claude service |
| `modules/standalone/` | `operator.standalone`: admin user, SSH, Tailscale, boot and Nix settings for a whole box |
| `examples/single-box/` | A complete box from the module alone; the CI check builds it |
| `tests/` | NixOS VM and evaluation tests run by `nix flake check` |
