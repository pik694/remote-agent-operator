# Each agent may reach the internet and the tailnet, but not the LAN or other
# private ranges. DNS stays allowed for when Tailscale DNS is down. One iptables
# chain per agent, keyed on its uid.
#
# An agent with its own network namespace reaches its tailnet from there, so
# what it still runs in the host's namespace (sudo -u, an SSH login) is kept
# off the host's tailnet too.
{ config, lib, ... }:
let
  agents = lib.filterAttrs (_: a: a.enable && a.egressFirewall.enable) config.operator.agents;

  tailnetVerdict = agent: if agent.network.namespace.enable then "REJECT" else "RETURN";

  startChain = agent: ''
    for cmd in iptables ip6tables; do
      $cmd -D OUTPUT -m owner --uid-owner ${agent.user} -j ${agent.user}-egress 2>/dev/null || true
      $cmd -F ${agent.user}-egress 2>/dev/null || $cmd -N ${agent.user}-egress
      $cmd -A ${agent.user}-egress -o lo -j RETURN
      $cmd -A ${agent.user}-egress -p udp --dport 53 -j RETURN
      $cmd -A ${agent.user}-egress -p tcp --dport 53 -j RETURN
    done
    iptables -A ${agent.user}-egress -d 100.64.0.0/10 -j ${tailnetVerdict agent}
    for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do
      iptables -A ${agent.user}-egress -d "$net" -j REJECT
    done
    ip6tables -A ${agent.user}-egress -d fd7a:115c:a1e0::/48 -j ${tailnetVerdict agent}
    for net in fc00::/7 fe80::/10; do
      ip6tables -A ${agent.user}-egress -d "$net" -j REJECT
    done
    iptables -A OUTPUT -m owner --uid-owner ${agent.user} -j ${agent.user}-egress
    ip6tables -A OUTPUT -m owner --uid-owner ${agent.user} -j ${agent.user}-egress
  '';

  stopChain = agent: ''
    for cmd in iptables ip6tables; do
      $cmd -D OUTPUT -m owner --uid-owner ${agent.user} -j ${agent.user}-egress 2>/dev/null || true
      $cmd -F ${agent.user}-egress 2>/dev/null || true
      $cmd -X ${agent.user}-egress 2>/dev/null || true
    done
  '';
in
{
  config = lib.mkIf (agents != { }) {
    networking.firewall.extraCommands = lib.concatMapStringsSep "\n" startChain (lib.attrValues agents);
    networking.firewall.extraStopCommands = lib.concatMapStringsSep "\n" stopChain (lib.attrValues agents);
  };
}
