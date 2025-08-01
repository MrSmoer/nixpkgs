{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.security.duosec;

  boolToStr = b: if b then "yes" else "no";

  configFilePam = ''
    [duo]
    ikey=${cfg.integrationKey}
    host=${cfg.host}
    ${lib.optionalString (cfg.groups != "") ("groups=" + cfg.groups)}
    failmode=${cfg.failmode}
    pushinfo=${boolToStr cfg.pushinfo}
    autopush=${boolToStr cfg.autopush}
    prompts=${toString cfg.prompts}
    fallback_local_ip=${boolToStr cfg.fallbackLocalIP}
  '';

  configFileLogin = configFilePam + ''
    motd=${boolToStr cfg.motd}
    accept_env_factor=${boolToStr cfg.acceptEnvFactor}
  '';
in
{
  imports = [
    (lib.mkRenamedOptionModule [ "security" "duosec" "group" ] [ "security" "duosec" "groups" ])
    (lib.mkRenamedOptionModule [ "security" "duosec" "ikey" ] [ "security" "duosec" "integrationKey" ])
    (lib.mkRemovedOptionModule [ "security" "duosec" "skey" ]
      "The insecure security.duosec.skey option has been replaced by a new security.duosec.secretKeyFile option. Use this new option to store a secure copy of your key instead."
    )
  ];

  options = {
    security.duosec = {
      ssh.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "If enabled, protect SSH logins with Duo Security.";
      };

      pam.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "If enabled, protect logins with Duo Security using PAM support.";
      };

      integrationKey = lib.mkOption {
        type = lib.types.str;
        description = "Integration key.";
      };

      secretKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          A file containing your secret key. The security of your Duo application is tied to the security of your secret key.
        '';
        example = "/run/keys/duo-skey";
      };

      host = lib.mkOption {
        type = lib.types.str;
        description = "Duo API hostname.";
      };

      groups = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "users,!wheel,!*admin guests";
        description = ''
          If specified, Duo authentication is required only for users
          whose primary group or supplementary group list matches one
          of the space-separated pattern lists. Refer to
          <https://duo.com/docs/duounix> for details.
        '';
      };

      failmode = lib.mkOption {
        type = lib.types.enum [
          "safe"
          "secure"
        ];
        default = "safe";
        description = ''
          On service or configuration errors that prevent Duo
          authentication, fail "safe" (allow access) or "secure" (deny
          access). The default is "safe".
        '';
      };

      pushinfo = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Include information such as the command to be executed in
          the Duo Push message.
        '';
      };

      autopush = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          If `true`, Duo Unix will automatically send
          a push login request to the user’s phone, falling back on a
          phone call if push is unavailable. If
          `false`, the user will be prompted to
          choose an authentication method. When configured with
          `autopush = yes`, we recommend setting
          `prompts = 1`.
        '';
      };

      motd = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Print the contents of `/etc/motd` to screen
          after a successful login.
        '';
      };

      prompts = lib.mkOption {
        type = lib.types.enum [
          1
          2
          3
        ];
        default = 3;
        description = ''
          If a user fails to authenticate with a second factor, Duo
          Unix will prompt the user to authenticate again. This option
          sets the maximum number of prompts that Duo Unix will
          display before denying access. Must be 1, 2, or 3. Default
          is 3.

          For example, when `prompts = 1`, the user
          will have to successfully authenticate on the first prompt,
          whereas if `prompts = 2`, if the user
          enters incorrect information at the initial prompt, he/she
          will be prompted to authenticate again.

          When configured with `autopush = true`, we
          recommend setting `prompts = 1`.
        '';
      };

      acceptEnvFactor = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Look for factor selection or passcode in the
          `$DUO_PASSCODE` environment variable before
          prompting the user for input.

          When $DUO_PASSCODE is non-empty, it will override
          autopush. The SSH client will need SendEnv DUO_PASSCODE in
          its configuration, and the SSH server will similarly need
          AcceptEnv DUO_PASSCODE.
        '';
      };

      fallbackLocalIP = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Duo Unix reports the IP address of the authorizing user, for
          the purposes of authorization and whitelisting. If Duo Unix
          cannot detect the IP address of the client, setting
          `fallbackLocalIP = yes` will cause Duo Unix
          to send the IP address of the server it is running on.

          If you are using IP whitelisting, enabling this option could
          cause unauthorized logins if the local IP is listed in the
          whitelist.
        '';
      };

      allowTcpForwarding = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          By default, when SSH forwarding, enabling Duo Security will
          disable TCP forwarding. By enabling this, you potentially
          undermine some of the SSH based login security. Note this is
          not needed if you use PAM.
        '';
      };
    };
  };

  config = lib.mkIf (cfg.ssh.enable || cfg.pam.enable) {
    environment.systemPackages = [ pkgs.duo-unix ];

    security.wrappers.login_duo = {
      setuid = true;
      owner = "root";
      group = "root";
      source = "${pkgs.duo-unix.out}/bin/login_duo";
    };

    systemd.services.login-duo = lib.mkIf cfg.ssh.enable {
      wantedBy = [ "sysinit.target" ];
      before = [
        "sysinit.target"
        "shutdown.target"
      ];
      conflicts = [ "shutdown.target" ];
      unitConfig.DefaultDependencies = false;
      script = ''
        if test -f "${cfg.secretKeyFile}"; then
          mkdir -p /etc/duo
          chmod 0755 /etc/duo

          umask 0077
          conf="$(mktemp)"
          {
            cat ${pkgs.writeText "login_duo.conf" configFileLogin}
            printf 'skey = %s\n' "$(cat ${cfg.secretKeyFile})"
          } >"$conf"

          chown sshd "$conf"
          mv -fT "$conf" /etc/duo/login_duo.conf
        fi
      '';
    };

    systemd.services.pam-duo = lib.mkIf cfg.ssh.enable {
      wantedBy = [ "sysinit.target" ];
      before = [
        "sysinit.target"
        "shutdown.target"
      ];
      conflicts = [ "shutdown.target" ];
      unitConfig.DefaultDependencies = false;
      script = ''
        if test -f "${cfg.secretKeyFile}"; then
          mkdir -p /etc/duo
          chmod 0755 /etc/duo

          umask 0077
          conf="$(mktemp)"
          {
            cat ${pkgs.writeText "login_duo.conf" configFilePam}
            printf 'skey = %s\n' "$(cat ${cfg.secretKeyFile})"
          } >"$conf"

          mv -fT "$conf" /etc/duo/pam_duo.conf
        fi
      '';
    };

    /*
      If PAM *and* SSH are enabled, then don't do anything special.
      If PAM isn't used, set the default SSH-only options.
    */
    services.openssh.extraConfig = lib.mkIf (cfg.ssh.enable || cfg.pam.enable) (
      if cfg.pam.enable then
        "UseDNS no"
      else
        ''
          # Duo Security configuration
          ForceCommand ${config.security.wrapperDir}/login_duo
          PermitTunnel no
          ${lib.optionalString (!cfg.allowTcpForwarding) ''
            AllowTcpForwarding no
          ''}
        ''
    );
  };
}
