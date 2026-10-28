# A new agent's first deploy runs before anyone can finish setting it up: its
# GitHub key was only just created, so the clone cannot succeed yet, and nobody
# has signed in to Claude. Neither may leave a failed unit behind, since
# switch-to-configuration reports one and deploy tools roll back on it. The
# repository is a local one the test creates late, standing in for GitHub
# starting to accept the key.
{ self, home-manager }:
{ ... }:
let
  origin = "/srv/widget.git";
in
{
  name = "first-deploy";

  nodes.box =
    { lib, pkgs, ... }:
    {
      imports = [
        home-manager.nixosModules.home-manager
        self.nixosModules.agents
      ];

      environment.systemPackages = [ pkgs.git ];

      operator.agents.claude-acme = {
        uid = 1001;
        repo.url = "file://${origin}";
        git = {
          userName = "Jane Doe";
          userEmail = "jane+acme@example.com";
        };
        githubTokenFile = "/run/secrets/gh-acme";
        githubTokenEnvFile = "/run/secrets/claude-acme.env";
        claudeService.enable = true;
      };

      systemd.tmpfiles.rules = [
        "d /run/secrets 0755 root root -"
        "f /run/secrets/claude-acme.env 0400 claude-acme users -"
      ];
      systemd.services.claude-acme.serviceConfig.ExecStart = lib.mkForce "${pkgs.coreutils}/bin/sleep infinity";
    };

  testScript = ''
    box.wait_for_unit("multi-user.target")

    def failed_units():
        return box.succeed("systemctl list-units --state=failed --no-legend --plain").strip()

    with subtest("checkout waits for the repository without failing"):
        box.wait_until_succeeds("journalctl -u claude-acme-checkout | grep 'Cannot clone file://${origin} yet'", timeout=60)
        box.succeed("systemctl is-active claude-acme-checkout")
        box.succeed("systemctl show -p NRestarts --value claude-acme-checkout | grep -x 0")
        assert failed_units() == "", f"no unit may fail before the clone can succeed, got: {failed_units()}"

    with subtest("claude service is skipped, not failed, without a checkout"):
        box.succeed("systemctl show -p ConditionResult --value claude-acme | grep -x no")
        box.fail("systemctl is-failed claude-acme")

    with subtest("checkout clones once the repository accepts it"):
        box.succeed(
            "git init -q --bare ${origin}",
            "git -C /tmp init -q seed",
            "git -C /tmp/seed -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init",
            "git -C /tmp/seed push -q ${origin} HEAD:refs/heads/main",
            "git -C ${origin} symbolic-ref HEAD refs/heads/main",
            "chown -R claude-acme ${origin}",
        )
        box.wait_until_succeeds("test -d /home/claude-acme/widget/.git", timeout=150)
        box.succeed("runuser -u claude-acme -- git -C /home/claude-acme/widget log --oneline | grep init")

    with subtest("claude service stays skipped until the agent signs in to Claude"):
        box.succeed("systemctl restart claude-acme")
        box.succeed("systemctl show -p ConditionResult --value claude-acme | grep -x no")
        box.succeed("install -d -o claude-acme -m 700 /home/claude-acme/.claude")
        box.succeed("install -o claude-acme -m 600 /dev/null /home/claude-acme/.claude/.credentials.json")
        box.succeed("systemctl restart claude-acme")
        box.wait_for_unit("claude-acme.service")
        assert failed_units() == "", f"no unit may fail once the agent is set up, got: {failed_units()}"
  '';
}
