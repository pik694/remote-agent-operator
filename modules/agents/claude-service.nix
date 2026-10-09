{ config, pkgs, lib, ... }:
let
  agents = lib.filterAttrs (_: a: a.enable && a.claudeService.enable) config.operator.agents;

  claudeService =
    agent:
    let
      paths = import ./paths.nix agent;
      namespaceUnits = lib.optionals agent.network.namespace.enable [
        "${agent.user}-netns.service"
        # Its /run/nscd mask needs the directory to exist (see network-namespace.nix).
        "nscd.service"
      ];
      # `claude remote-control` records its environment ID in this pointer and
      # asks to reuse it on the next start, so open sessions reconnect. But
      # after 10 minutes without reaching Anthropic it gives up, deletes the
      # pointer and exits, and the restart registers a new environment that the
      # open sessions can't reach. Keep a copy while it runs and put it back
      # before a start that finds the pointer missing. While offline, every
      # start fails within seconds, so the copy has to survive many restarts.
      # If the server refuses the old ID, Claude Code deletes the pointer and
      # runs without one; a pointer missing for two checks in a row means that,
      # so the copy is dropped then.
      startScript = pkgs.writeShellScript "${agent.user}-start" ''
        set -u
        pointer=${paths.bridgePointer}
        copy=$pointer.keep
        if ! test -s "$pointer" && test -s "$copy"; then
          cp "$copy" "$pointer"
          # Claude Code ignores a pointer whose mtime is older than 4 hours.
          touch "$pointer"
        fi
        missing=0
        while sleep 60; do
          if ${pkgs.jq}/bin/jq -e '.environmentId' "$pointer" > /dev/null 2>&1; then
            missing=0
            cp "$pointer" "$copy.tmp" && mv "$copy.tmp" "$copy"
          else
            missing=$((missing + 1))
            if test "$missing" -ge 2; then
              rm -f "$copy"
            fi
          fi
        done &
        exec ${config.operator.claudePackage}/bin/claude remote-control --spawn worktree --capacity ${toString agent.claudeService.capacity}
      '';
    in
    {
      description = "Claude Code Remote Control for ${agent.user} (${agent.repo.directory})";
      wantedBy = [ "multi-user.target" ];
      requires = [ "${agent.user}-checkout.service" ] ++ namespaceUnits;
      after = [ "${agent.user}-checkout.service" ] ++ namespaceUnits;
      path = [
        "/run/wrappers"
        "/run/current-system/sw"
        "/etc/profiles/per-user/${agent.user}"
      ];
      serviceConfig = {
        Type = "simple";
        User = agent.user;
        WorkingDirectory = paths.repoPath;
        EnvironmentFile = agent.githubTokenEnvFile;
        Environment =
          [
            # PrivateTmp's /tmp is invisible to the Docker daemon, so files
            # that tests bind-mount into containers must live under the home.
            "TMPDIR=${paths.tmpDir}"
          ]
          ++ lib.optionals agent.docker.enable [
            "DOCKER_HOST=unix://${paths.dockerSocket}"
            "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=${paths.dockerSocket}"
          ];
        ExecStart = startScript;
        Restart = "always";
        RestartSec = 30;

        # Sandbox: agents see and write only their own home; the rest is
        # read-only and other homes are hidden. Not restricted, because agent
        # tooling needs them: W^X memory (Node's JIT) and the network.
        # ProtectKernelTunables/-Logs and ProtectHostname cover parts of /proc,
        # so bubblewrap (and Claude Code's /sandbox) can't run under this unit.
        # That's intentional; see "Security model" in README.md.
        UMask = "0077";
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        BindPaths = [ paths.home ];
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectProc = "invisible";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        KeyringMode = "private";
        RemoveIPC = true;
        SystemCallArchitectures = "native";
        # Deny syscall groups agents never need. @mount (bubblewrap) and
        # @debug (strace, debuggers) stay allowed.
        SystemCallFilter = [ "~@clock @cpu-emulation @module @obsolete @raw-io @reboot @swap" ];
        SystemCallErrorNumber = "EPERM";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];

        MemoryHigh = agent.claudeService.memoryHigh;
        MemoryMax = agent.claudeService.memoryMax;
        TasksMax = 4096;
      }
      // lib.optionalAttrs agent.network.namespace.enable {
        NetworkNamespacePath = paths.networkNamespace;
        BindReadOnlyPaths = [ "${paths.namespaceResolvConf}:/etc/resolv.conf" ];
        # nscd answers from the host's namespace with the host's resolvers, so
        # lookups would bypass the namespace's DNS; without it glibc resolves
        # through /etc/resolv.conf itself.
        InaccessiblePaths = [ "-/run/nscd" ];
      };
    };
in
{
  config = lib.mkIf (agents != { }) {
    systemd.services = lib.mapAttrs' (
      _: agent: lib.nameValuePair agent.user (claudeService agent)
    ) agents;
  };
}
