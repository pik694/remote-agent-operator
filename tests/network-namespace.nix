# An agent with network.namespace.enable runs in its own network namespace,
# reaching the internet through the host and nothing else. "internet" stands in
# for a public server and DNS resolver on 198.51.100.1, and also for a LAN,
# private-range and tailnet neighbour on its other addresses.
{ self, home-manager }:
let
  privateAddresses = {
    lan = "192.168.50.1";
    tenSlashEight = "10.9.0.1";
    oneSevenTwo = "172.16.0.1";
    tailnet = "100.100.1.1";
  };
  addressOn = address: {
    inherit address;
    prefixLength = 24;
  };
in
{
  name = "network-namespace";

  nodes = {
    internet = {
      networking.interfaces.eth1.ipv4.addresses = map addressOn [
        "198.51.100.1"
        privateAddresses.lan
        privateAddresses.tenSlashEight
        privateAddresses.oneSevenTwo
        privateAddresses.tailnet
      ];
      networking.interfaces.eth1.ipv6.addresses = [
        {
          address = "fd7a:115c:a1e0::1";
          prefixLength = 64;
        }
      ];
      networking.firewall.allowedTCPPorts = [
        53
        80
      ];
      networking.firewall.allowedUDPPorts = [ 53 ];
      services.nginx = {
        enable = true;
        virtualHosts.default.locations."/".return = "200 'internet'";
      };
      services.dnsmasq = {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          address = "/work.example/198.51.100.1";
        };
      };
    };

    box =
      { lib, pkgs, ... }:
      {
        imports = [
          home-manager.nixosModules.home-manager
          self.nixosModules.agents
        ];

        networking.interfaces.eth1.ipv4.addresses = map addressOn [
          "198.51.100.2"
          "192.168.50.2"
          "10.9.0.2"
          "172.16.0.2"
          "100.100.1.2"
        ];
        networking.interfaces.eth1.ipv6.addresses = [
          {
            address = "fd7a:115c:a1e0::2";
            prefixLength = 64;
          }
        ];

        # A host service open on every interface, as Ollama or sshd would be.
        networking.firewall.allowedTCPPorts = [ 80 ];
        services.nginx = {
          enable = true;
          virtualHosts.default.locations."/".return = "200 'box'";
        };

        operator.agents.claude-acme = {
          uid = 1001;
          repo.url = "git@github.com:acme/widget.git";
          git = {
            userName = "Jane Doe";
            userEmail = "jane+acme@example.com";
          };
          githubTokenFile = "/run/secrets/gh-acme";
          githubTokenEnvFile = "/run/secrets/claude-acme.env";
          claudeService.enable = true;
          network.namespace = {
            enable = true;
            nameservers = [ "198.51.100.1" ];
            tailscale.enable = true;
          };
        };

        # The test has no GitHub to clone from, no secret store and no Claude
        # login, so the checkout and token are faked and the claude service runs
        # a name lookup in its place, through the same sandbox and namespace.
        systemd.tmpfiles.rules = [
          "d /run/secrets 0755 root root -"
          "f /run/secrets/claude-acme.env 0400 claude-acme users -"
        ];
        systemd.services.claude-acme-checkout.script = lib.mkForce "mkdir -p /home/claude-acme/widget";
        systemd.services.claude-acme.serviceConfig.ExecStart = lib.mkForce (
          lib.getExe (
            pkgs.writeShellScriptBin "lookup-work-example" ''
              getent hosts work.example > /home/claude-acme/lookup || echo failed > /home/claude-acme/lookup
            ''
          )
        );
      };
    };

  testScript = ''
    start_all()
    internet.wait_for_unit("dnsmasq.service")
    internet.wait_for_unit("nginx.service")
    box.wait_for_unit("nginx.service")
    box.wait_for_unit("claude-acme-netns.service")

    with subtest("agent namespace reaches the internet through the host"):
        box.succeed("ip netns exec claude-acme curl -sf --max-time 5 http://198.51.100.1/ | grep internet")

    with subtest("agent's claude service joins its namespace"):
        box.succeed("systemctl show -p NetworkNamespacePath claude-acme.service | grep -x NetworkNamespacePath=/run/netns/claude-acme")

    with subtest("agent's claude service resolves names through the namespace's nameservers, not the host's"):
        box.fail("getent hosts work.example")
        box.wait_until_succeeds("grep 198.51.100.1 /home/claude-acme/lookup", timeout=120)

    with subtest("admin's agent shell runs as the agent in its namespace, with the namespace's DNS"):
        box.succeed("claude-acme-shell -c 'id -un' | grep -x claude-acme")
        box.succeed('test "$(claude-acme-shell -c "readlink /proc/self/ns/net")" = "$(ip netns exec claude-acme readlink /proc/self/ns/net)"')
        box.succeed("claude-acme-shell -c 'getent hosts work.example' | grep 198.51.100.1")

    with subtest("agent's tailscaled runs inside its namespace, waiting for a manual login"):
        box.wait_for_unit("claude-acme-tailscaled.service")
        box.succeed("ip netns exec claude-acme ip link show tailscale0")
        box.fail("ip link show tailscale0")
        box.wait_until_succeeds(
            "tailscale --socket=/run/claude-acme-tailscale/tailscaled.sock status --json | grep -E '\"BackendState\": *\"NeedsLogin\"'",
            timeout=60,
        )

    for name, address in ${builtins.toJSON privateAddresses}.items():
        with subtest(f"agent namespace cannot reach the {name} neighbour the host reaches"):
            box.succeed(f"curl -sf --max-time 5 http://{address}/ | grep internet")
            box.fail(f"ip netns exec claude-acme curl -sf --max-time 5 http://{address}/")

    # Rootless Docker runs as the agent but stays in the host's namespace.
    for url in ["http://100.100.1.1/", "http://[fd7a:115c:a1e0::1]/"]:
        with subtest(f"agent's processes left in the host namespace cannot reach the host's tailnet at {url}"):
            box.wait_until_succeeds(f"curl -sf --max-time 5 {url} | grep internet", timeout=60)
            box.fail(f"runuser -u claude-acme -- curl -sf --max-time 5 {url}")

    for address in ["192.168.50.2", "10.233.233.1"]:
        with subtest(f"agent namespace cannot reach host services on {address}"):
            internet.succeed("curl -sf --max-time 5 http://192.168.50.2/ | grep box")
            box.fail(f"ip netns exec claude-acme curl -sf --max-time 5 http://{address}/")
  '';
}
