# A network namespace per agent that enables network.namespace, joined to the
# host by a veth pair on a /30 derived from the agent's uid and NATed out to the
# internet only.
#
# Forwarding to private ranges and the tailnet is refused by routing rules, not
# by FORWARD rules: tailscaled keeps its ts-forward chain at the top of FORWARD
# and accepts everything leaving through tailscale0, so a FORWARD rule would not
# keep the namespace off the host's tailnet. The host's own addresses are
# delivered locally before any routing rule, so INPUT rejects them.
{ config, pkgs, lib, ... }:
let
  agents = lib.filterAttrs (_: a: a.enable && a.network.namespace.enable) config.operator.agents;
  tailscaleAgents = lib.filterAttrs (_: a: a.network.namespace.tailscale.enable) agents;
  autoconnectAgents = lib.filterAttrs (
    _: a: a.network.namespace.tailscale.authKeyFile != null
  ) tailscaleAgents;
  tailscale = config.services.tailscale.package;

  unreachableRanges = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16"
    "100.64.0.0/10"
  ];

  routingRule = agent: range: "iif ${(veth agent).hostInterface} to ${range} prohibit priority 100";

  veth =
    agent:
    let
      subnet = "10.233.${toString (lib.mod agent.uid 256)}";
    in
    {
      inherit subnet;
      hostInterface = "vh${toString agent.uid}";
      namespaceInterface = "vn${toString agent.uid}";
      hostAddress = "${subnet}.1";
      namespaceAddress = "${subnet}.2";
    };

  namespaceService =
    agent:
    let
      v = veth agent;
      name = agent.user;
      paths = import ./paths.nix agent;
    in
    {
      description = "Network namespace for the ${agent.user} agent";
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        ip netns delete ${name} 2>/dev/null || true
        ip link delete ${v.hostInterface} 2>/dev/null || true
        ${removeRoutingRules agent}
        ip netns add ${name}
        ip link add ${v.hostInterface} type veth peer name ${v.namespaceInterface} netns ${name}
        ip address add ${v.hostAddress}/30 dev ${v.hostInterface}
        ip link set ${v.hostInterface} up
        ip -n ${name} link set lo up
        ip -n ${name} address add ${v.namespaceAddress}/30 dev ${v.namespaceInterface}
        ip -n ${name} link set ${v.namespaceInterface} up
        ip -n ${name} route add default via ${v.hostAddress}
        install -d -m 755 "$(dirname ${paths.namespaceResolvConf})"
        printf 'nameserver %s\n' ${lib.escapeShellArgs agent.network.namespace.nameservers} > ${paths.namespaceResolvConf}
        ${lib.concatMapStringsSep "\n" (range: "ip rule add ${routingRule agent range}") unreachableRanges}
      '';
      preStop = ''
        ip netns delete ${name} || true
        ip link delete ${v.hostInterface} 2>/dev/null || true
        ${removeRoutingRules agent}
      '';
    };

  removeRoutingRules =
    agent:
    lib.concatMapStringsSep "\n" (
      range: "while ip rule del ${routingRule agent range} 2>/dev/null; do :; done"
    ) unreachableRanges;

  # Its own state and socket, so it never touches the host's tailscaled. The
  # host's resolv.conf is replaced by the namespace's, which tailscaled then
  # manages directly (no resolvconf on its PATH), so the tailnet's MagicDNS
  # applies to the agent only.
  tailscaledService =
    agent:
    let
      paths = import ./paths.nix agent;
      namespaceUnit = "${agent.user}-netns.service";
    in
    {
      description = "Tailscale inside the ${agent.user} agent's network namespace";
      wantedBy = [ "multi-user.target" ];
      bindsTo = [ namespaceUnit ];
      after = [
        namespaceUnit
        "nscd.service"
      ];
      path = [
        config.networking.firewall.package
        pkgs.iproute2
        pkgs.procps
      ];
      serviceConfig = {
        ExecStart = "${tailscale}/bin/tailscaled --statedir=${paths.tailscaleStateDir} --socket=${paths.tailscaleSocket} --port=0";
        StateDirectory = baseNameOf paths.tailscaleStateDir;
        StateDirectoryMode = "0700";
        RuntimeDirectory = baseNameOf (dirOf paths.tailscaleSocket);
        # The agent's units mount this directory over /run/tailscale; removing
        # it on a restart would drop that mount (see the host's tailscaled below).
        RuntimeDirectoryPreserve = "yes";
        NetworkNamespacePath = paths.networkNamespace;
        BindPaths = [ "${paths.namespaceResolvConf}:/etc/resolv.conf" ];
        InaccessiblePaths = [ "-/run/nscd" ];
        Restart = "on-failure";
      };
    };

  # Logs the agent's tailscaled in with its auth key whenever it is logged out,
  # like nixpkgs' tailscaled-autoconnect does for the host's.
  autoconnectService =
    agent:
    let
      paths = import ./paths.nix agent;
      cfg = agent.network.namespace.tailscale;
      tailscaledUnit = "${agent.user}-tailscaled.service";
      cli = "${tailscale}/bin/tailscale --socket=${paths.tailscaleSocket}";
    in
    {
      description = "Log the ${agent.user} agent's tailscaled in to its tailnet";
      wantedBy = [ "multi-user.target" ];
      requires = [ tailscaledUnit ];
      after = [ tailscaledUnit ];
      path = [ pkgs.jq ];
      # A control server it can't reach fails the unit, rather than holding up
      # boot and switches with a login that never finishes; it retries later.
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = 30;
      };
      script = ''
        set -eu
        state=
        for _ in $(seq 60); do
          state=$(${cli} status --json --peers=false | jq -r .BackendState) || true
          case "$state" in NeedsLogin|NeedsMachineAuth|Running|Stopped) break ;; esac
          sleep 1
        done
        if [ "$state" = NeedsLogin ] || [ "$state" = NeedsMachineAuth ]; then
          ${cli} up --timeout=60s --auth-key "file:${cfg.authKeyFile}" --hostname=${lib.escapeShellArg cfg.hostname} ${lib.escapeShellArgs cfg.extraUpFlags}
        fi
      '';
    };

  # `sudo <user>-shell` opens a login shell as the agent with the same network
  # view as its claude service; arguments go to the shell (`-c 'psql ...'`).
  shellCommand =
    agent:
    let
      paths = import ./paths.nix agent;
    in
    pkgs.writeShellScriptBin "${agent.user}-shell" ''
      if [ -t 0 ] && [ -t 1 ]; then io=--pty; else io=--pipe; fi
      exec ${config.systemd.package}/bin/systemd-run "$io" --wait --collect --quiet \
        --uid=${agent.user} \
        -p WorkingDirectory=${paths.home} \
        ${lib.escapeShellArgs (namespaceViewProperties agent)} \
        -- ${pkgs.bashInteractive}/bin/bash -l "$@"
    '';

  namespaceViewProperties =
    agent:
    lib.concatLists (
      lib.mapAttrsToList (name: values: map (value: "--property=${name}=${value}") (lib.toList values)) (
        import ./namespace-view.nix { inherit lib; } agent
      )
    );

  rejectHostInput = agent: "iptables -I INPUT -i ${(veth agent).hostInterface} -j REJECT";
  removeHostInput =
    agent: "while iptables -D INPUT -i ${(veth agent).hostInterface} -j REJECT 2>/dev/null; do :; done";
in
{
  config = lib.mkIf (agents != { }) {
    assertions = lib.mapAttrsToList (subnet: sharing: {
      assertion = lib.length sharing == 1;
      message = "Agents ${lib.concatMapStringsSep ", " (a: a.user) sharing} would share the network namespace subnet ${subnet}.0/30; give them uids that differ modulo 256.";
    }) (lib.groupBy (agent: (veth agent).subnet) (lib.attrValues agents));

    networking.firewall.extraCommands = lib.concatMapStringsSep "\n" (
      agent: removeHostInput agent + "\n" + rejectHostInput agent
    ) (lib.attrValues agents);
    networking.firewall.extraStopCommands = lib.concatMapStringsSep "\n" removeHostInput (
      lib.attrValues agents
    );

    networking.nat = {
      enable = true;
      internalIPs = lib.mapAttrsToList (_: agent: "${(veth agent).subnet}.0/30") agents;
    };

    environment.systemPackages =
      lib.mapAttrsToList (_: shellCommand) agents ++ lib.optional (tailscaleAgents != { }) tailscale;

    systemd.services =
      lib.mapAttrs' (_: agent: lib.nameValuePair "${agent.user}-netns" (namespaceService agent)) agents
      // lib.mapAttrs' (
        _: agent: lib.nameValuePair "${agent.user}-tailscaled" (tailscaledService agent)
      ) tailscaleAgents
      // lib.mapAttrs' (
        _: agent: lib.nameValuePair "${agent.user}-tailscale-autoconnect" (autoconnectService agent)
      ) autoconnectAgents
      // {
        # The agents' units hide /run/nscd from their own view. systemd would
        # remove and recreate it on every nscd restart, dropping that mask and
        # handing the agents the host's resolvers again; kept, only the socket
        # inside is replaced.
        nscd.serviceConfig.RuntimeDirectoryPreserve = "yes";
      }
      // lib.optionalAttrs config.services.tailscale.enable {
        # Likewise for /run/tailscale, which the agents' units cover with their
        # own tailscaled's directory or hide.
        tailscaled.serviceConfig.RuntimeDirectoryPreserve = "yes";
      };
  };
}
