{ config, pkgs, lib, ... }:
let
  enabled = lib.filterAttrs (_: a: a.enable) config.operator.agents;

  gitKeysService = agent:
    let
      paths = import ./paths.nix agent;
    in
    {
      description = "Create the ${agent.user} GitHub keys and local signing trust";
      wantedBy = [ "multi-user.target" ];
      requires = [ "home-manager-${agent.user}.service" ];
      after = [ "home-manager-${agent.user}.service" ];
      path = [
        pkgs.openssh
        pkgs.coreutils
      ];
      environment.HOME = paths.home;
      serviceConfig = {
        Type = "oneshot";
        User = agent.user;
        WorkingDirectory = paths.home;
        UMask = "0077";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        install -d -m 700 ${paths.home}/.ssh
        for name in ${agent.repo.directory}-gh-auth ${agent.repo.directory}-gh-signing; do
          key=${paths.home}/.ssh/$name
          if test -f "$key"; then
            if ! test -f "$key.pub"; then
              ssh-keygen -y -f "$key" > "$key.pub"
            fi
          elif test -e "$key.pub"; then
            echo "$key.pub exists without its private key; refusing to replace it" >&2
            exit 1
          else
            ssh-keygen -q -t ed25519 -N "" -f "$key" -C "${agent.user}@${config.networking.hostName} $name"
          fi
          chmod 600 "$key" "$key.pub"
        done

        install -d -m 700 ${paths.home}/.config/git
        signers=${paths.allowedSigners}
        if test -L "$signers"; then
          rm -- "$signers"
        fi
        printf '%s %s\n' '${agent.git.userEmail}' "$(cat ${paths.signingKey}.pub)" > "$signers"
        chmod 600 "$signers"
      '';
    };

  checkoutService = agent:
    let
      paths = import ./paths.nix agent;
    in
    {
      description = "Clone ${agent.repo.directory} for the ${agent.user} agent account";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      requires = [ "${agent.user}-git-keys.service" ];
      after = [
        "network-online.target"
        "${agent.user}-git-keys.service"
      ];
      path = [
        pkgs.git
        pkgs.openssh
        pkgs.coreutils
      ];
      environment.HOME = paths.home;
      serviceConfig = {
        Type = "oneshot";
        User = agent.user;
        WorkingDirectory = paths.home;
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = "60s";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        repo=${paths.repoPath}
        url=${agent.repo.url}

        if test -e "$repo"; then
          if test "$(git -C "$repo" remote get-url origin 2>/dev/null)" = "$url"; then
            exit 0
          fi
          echo "$repo exists but is not the expected Git checkout" >&2
          exit 1
        fi

        if ! test -f ${paths.authKey}; then
          echo "Waiting for the ${agent.user} GitHub authentication key" >&2
          exit 1
        fi

        export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -i ${paths.authKey}"
        staging=$(mktemp -d ${paths.home}/.${agent.repo.directory}-clone.XXXXXX)
        trap 'rm -rf -- "$staging"' EXIT
        git clone "$url" "$staging/${agent.repo.directory}"
        mv "$staging/${agent.repo.directory}" "$repo"
      '';
    };
in
{
  config = lib.mkIf (enabled != { }) {
    # The checkout clones over SSH with StrictHostKeyChecking=yes, so the
    # remote's host key has to be known before the first boot.
    # Published at https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
    programs.ssh.knownHosts.github = {
      hostNames = [ "github.com" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };

    systemd.services = lib.mkMerge (
      lib.mapAttrsToList (_: agent: {
        "${agent.user}-git-keys" = gitKeysService agent;
        "${agent.user}-checkout" = checkoutService agent;
      }) enabled
    );
  };
}
