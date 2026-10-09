# What an agent with network.namespace sees of the network, as systemd
# settings shared by its claude service and `<user>-shell`: its namespace, its
# namespace's resolv.conf, and its own tailscaled's socket where the tailscale
# CLI looks for one.
#
# nscd answers from the host's namespace with the host's resolvers, so it is
# hidden and glibc resolves through /etc/resolv.conf itself. The host's
# tailscaled socket is replaced (or, without a tailscaled of the agent's own,
# hidden), so `tailscale status` never shows the host's tailnet.
{ lib }:
agent:
let
  paths = import ./paths.nix agent;
  ownTailscale = agent.network.namespace.tailscale.enable;
in
{
  NetworkNamespacePath = paths.networkNamespace;
  BindReadOnlyPaths = [
    "${paths.namespaceResolvConf}:/etc/resolv.conf"
  ]
  ++ lib.optional ownTailscale "${dirOf paths.tailscaleSocket}:/run/tailscale";
  InaccessiblePaths = [ "-/run/nscd" ] ++ lib.optional (!ownTailscale) "-/run/tailscale";
}
