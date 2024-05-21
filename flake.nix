{
  description = "A Nix-based continuous build system";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.05-small";
  inputs.nix.url = "github:NixOS/nix/2.20-maintenance";
  inputs.nix.inputs.nixpkgs.follows = "nixpkgs";

  # TODO get rid of this once https://github.com/NixOS/nix/pull/9546 is
  # mered and we upgrade or Nix, so the main `nixpkgs` input is at least
  # 23.11 and has `lib.fileset`.
  inputs.nixpkgs-for-fileset.url = "github:NixOS/nixpkgs/nixos-23.11";

  outputs = { self, nixpkgs, nix, nixpkgs-for-fileset }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;

      overlayList = [ self.overlays.default nix.overlays.default ];

      pkgsBySystem = forEachSystem (system: import nixpkgs {
        inherit system;
        overlays = overlayList;
      });

      # NixOS configuration used for VM tests.
      hydraServer =
        { config, pkgs, ... }:
        {
          imports = [ self.nixosModules.hydraTest ];

          virtualisation.memorySize = 1024;
          virtualisation.writableStore = true;

          environment.systemPackages = [ pkgs.perlPackages.LWP pkgs.perlPackages.JSON ];

          nix = {
            # Without this nix tries to fetch packages from the default
            # cache.nixos.org which is not reachable from this sandboxed NixOS test.
            binaryCaches = [ ];
          };
        };

    in
    rec {

      # A Nixpkgs overlay that provides a 'hydra' package.
      overlays.default = final: prev: {

        # Add LDAP dependencies that aren't currently found within nixpkgs.
        perlPackages = prev.perlPackages // {

          PrometheusTiny = final.perlPackages.buildPerlPackage {
            pname = "Prometheus-Tiny";
            version = "0.007";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/R/RO/ROBN/Prometheus-Tiny-0.007.tar.gz";
              sha256 = "0ef8b226a2025cdde4df80129dd319aa29e884e653c17dc96f4823d985c028ec";
            };
            buildInputs = with final.perlPackages; [ HTTPMessage Plack TestException ];
            meta = {
              homepage = "https://github.com/robn/Prometheus-Tiny";
              description = "A tiny Prometheus client";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

        };

        hydra = final.callPackage ./package.nix {
          inherit (nixpkgs-for-fileset.lib) fileset;
          rawSrc = self;
        };
      };

      hydraJobs = {

        build = forEachSystem (system: packages.${system}.hydra);

        buildNoTests = forEachSystem (system:
          packages.${system}.hydra.overrideAttrs (_: {
            doCheck = false;
          })
        );

        manual = forEachSystem (system:
          let pkgs = pkgsBySystem.${system}; in
          pkgs.runCommand "hydra-manual-${pkgs.hydra.version}" { }
            ''
              mkdir -p $out/share
              cp -prvd ${pkgs.hydra}/share/doc $out/share/

              mkdir $out/nix-support
              echo "doc manual $out/share/doc/hydra" >> $out/nix-support/hydra-build-products
            '');

        tests.install = forEachSystem (system:
          with import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; };
          simpleTest {
            name = "hydra-install";
            nodes.machine = hydraServer;
            testScript =
              ''
                machine.wait_for_job("hydra-init")
                machine.wait_for_job("hydra-server")
                machine.wait_for_job("hydra-evaluator")
                machine.wait_for_job("hydra-queue-runner")
                machine.wait_for_open_port(3000)
                machine.succeed("curl --fail http://localhost:3000/")
              '';
          });

        tests.notifications = forEachSystem (system:
          let pkgs = pkgsBySystem.${system}; in
          with import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; };
          simpleTest {
            name = "hydra-notifications";
            nodes.machine = { pkgs, ... }: {
              imports = [ hydraServer ];
              services.hydra-dev.extraConfig = ''
                <influxdb>
                  url = http://127.0.0.1:8086
                  db = hydra
                </influxdb>
              '';
              services.influxdb.enable = true;
            };
            testScript = ''
              machine.wait_for_job("hydra-init")

              # Create an admin account and some other state.
              machine.succeed(
                  """
                      su - hydra -c "hydra-create-user root --email-address 'alice@example.org' --password foobar --role admin"
                      mkdir /run/jobset
                      chmod 755 /run/jobset
                      cp ${./t/jobs/api-test.nix} /run/jobset/default.nix
                      chmod 644 /run/jobset/default.nix
                      chown -R hydra /run/jobset
              """
              )

              # Wait until InfluxDB can receive web requests
              machine.wait_for_job("influxdb")
              machine.wait_for_open_port(8086)

              # Create an InfluxDB database where hydra will write to
              machine.succeed(
                  "curl -XPOST 'http://127.0.0.1:8086/query' "
                  + "--data-urlencode 'q=CREATE DATABASE hydra'"
              )

              # Wait until hydra-server can receive HTTP requests
              machine.wait_for_job("hydra-server")
              machine.wait_for_open_port(3000)

              # Setup the project and jobset
              machine.succeed(
                  "su - hydra -c 'perl -I ${pkgs.hydra.perlDeps}/lib/perl5/site_perl ${./t/setup-notifications-jobset.pl}' >&2"
              )

              # Wait until hydra has build the job and
              # the InfluxDBNotification plugin uploaded its notification to InfluxDB
              machine.wait_until_succeeds(
                  "curl -s -H 'Accept: application/csv' "
                  + "-G 'http://127.0.0.1:8086/query?db=hydra' "
                  + "--data-urlencode 'q=SELECT * FROM hydra_build_status' | grep success"
              )
            '';
          });

        tests.gitea = forEachSystem (system:
          let pkgs = pkgsBySystem.${system}; in
          with import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; };
          makeTest {
            name = "hydra-gitea";
            nodes.machine = { pkgs, ... }: {
              imports = [ hydraServer ];
              services.hydra-dev.extraConfig = ''
                <gitea_authorization>
                root=d7f16a3412e01a43a414535b16007c6931d3a9c7
                </gitea_authorization>
              '';
              nixpkgs.config.permittedInsecurePackages = [ "gitea-1.19.4" ];
              nix = {
                settings.substituters = [ ];
              };
              services.gitea = {
                enable = true;
                database.type = "postgres";
                disableRegistration = true;
                httpPort = 3001;
              };
              services.openssh.enable = true;
              environment.systemPackages = with pkgs; [ gitea git jq gawk ];
              networking.firewall.allowedTCPPorts = [ 3000 ];
            };
            skipLint = true;
            testScript =
              let
                scripts.mktoken = pkgs.writeText "token.sql" ''
                  INSERT INTO access_token (id, uid, name, created_unix, updated_unix, token_hash, token_salt, token_last_eight, scope) VALUES (1, 1, 'hydra', 1617107360, 1617107360, 'a930f319ca362d7b49a4040ac0af74521c3a3c3303a86f327b01994430672d33b6ec53e4ea774253208686c712495e12a486', 'XRjWE9YW0g', '31d3a9c7', 'all');
                '';

                scripts.git-setup = pkgs.writeShellScript "setup.sh" ''
                  set -x
                  mkdir -p /tmp/repo $HOME/.ssh
                  cat ${snakeoilKeypair.privkey} > $HOME/.ssh/privk
                  chmod 0400 $HOME/.ssh/privk
                  git -C /tmp/repo init
                  cp ${smallDrv} /tmp/repo/jobset.nix
                  git -C /tmp/repo add .
                  git config --global user.email test@localhost
                  git config --global user.name test
                  git -C /tmp/repo commit -m 'Initial import'
                  git -C /tmp/repo remote add origin gitea@machine:root/repo
                  GIT_SSH_COMMAND='ssh -i $HOME/.ssh/privk -o StrictHostKeyChecking=no' \
                    git -C /tmp/repo push origin master
                  git -C /tmp/repo log >&2
                '';

                scripts.hydra-setup = pkgs.writeShellScript "hydra.sh" ''
                  set -x
                  su -l hydra -c "hydra-create-user root --email-address \
                    'alice@example.org' --password foobar --role admin"

                  URL=http://localhost:3000
                  USERNAME="root"
                  PASSWORD="foobar"
                  PROJECT_NAME="trivial"
                  JOBSET_NAME="trivial"
                  mycurl() {
                    curl --referer $URL -H "Accept: application/json" \
                      -H "Content-Type: application/json" $@
                  }

                  cat >data.json <<EOF
                  { "username": "$USERNAME", "password": "$PASSWORD" }
                  EOF
                  mycurl -X POST -d '@data.json' $URL/login -c hydra-cookie.txt

                  cat >data.json <<EOF
                  {
                    "displayname":"Trivial",
                    "enabled":"1",
                    "visible":"1"
                  }
                  EOF
                  mycurl --silent -X PUT $URL/project/$PROJECT_NAME \
                    -d @data.json -b hydra-cookie.txt

                  cat >data.json <<EOF
                  {
                    "description": "Trivial",
                    "checkinterval": "60",
                    "enabled": "1",
                    "visible": "1",
                    "keepnr": "1",
                    "enableemail": true,
                    "emailoverride": "hydra@localhost",
                    "type": 0,
                    "nixexprinput": "git",
                    "nixexprpath": "jobset.nix",
                    "inputs": {
                      "git": {"value": "http://localhost:3001/root/repo.git", "type": "git"},
                      "gitea_repo_name": {"value": "repo", "type": "string"},
                      "gitea_repo_owner": {"value": "root", "type": "string"},
                      "gitea_status_repo": {"value": "git", "type": "string"},
                      "gitea_http_url": {"value": "http://localhost:3001", "type": "string"}
                    }
                  }
                  EOF

                  mycurl --silent -X PUT $URL/jobset/$PROJECT_NAME/$JOBSET_NAME \
                    -d @data.json -b hydra-cookie.txt
                '';

                api_token = "d7f16a3412e01a43a414535b16007c6931d3a9c7";

                snakeoilKeypair = {
                  privkey = pkgs.writeText "privkey.snakeoil" ''
                    -----BEGIN EC PRIVATE KEY-----
                    MHcCAQEEIHQf/khLvYrQ8IOika5yqtWvI0oquHlpRLTZiJy5dRJmoAoGCCqGSM49
                    AwEHoUQDQgAEKF0DYGbBwbj06tA3fd/+yP44cvmwmHBWXZCKbS+RQlAKvLXMWkpN
                    r1lwMyJZoSGgBHoUahoYjTh9/sJL7XLJtA==
                    -----END EC PRIVATE KEY-----
                  '';

                  pubkey = pkgs.lib.concatStrings [
                    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHA"
                    "yNTYAAABBBChdA2BmwcG49OrQN33f/sj+OHL5sJhwVl2Qim0vkUJQCry1zFpKTa"
                    "9ZcDMiWaEhoAR6FGoaGI04ff7CS+1yybQ= sakeoil"
                  ];
                };

                smallDrv = pkgs.writeText "jobset.nix" ''
                  { trivial = builtins.derivation {
                      name = "trivial";
                      system = "${system}";
                      builder = "/bin/sh";
                      allowSubstitutes = false;
                      preferLocalBuild = true;
                      args = ["-c" "echo success > $out; exit 0"];
                    };
                   }
                '';
              in
              ''
                import json

                machine.start()
                machine.wait_for_unit("multi-user.target")
                machine.wait_for_open_port(3000)
                machine.wait_for_open_port(3001)

                machine.succeed(
                    "su -l gitea -c 'GITEA_WORK_DIR=/var/lib/gitea gitea admin user create "
                    + "--username root --password root --email test@localhost'"
                )
                machine.succeed("su -l postgres -c 'psql gitea < ${scripts.mktoken}'")

                machine.succeed(
                    "curl --fail -X POST http://localhost:3001/api/v1/user/repos "
                    + "-H 'Accept: application/json' -H 'Content-Type: application/json' "
                    + f"-H 'Authorization: token ${api_token}'"
                    + ' -d \'{"auto_init":false, "description":"string", "license":"mit", "name":"repo", "private":false}\'''
                )

                machine.succeed(
                    "curl --fail -X POST http://localhost:3001/api/v1/user/keys "
                    + "-H 'Accept: application/json' -H 'Content-Type: application/json' "
                    + f"-H 'Authorization: token ${api_token}'"
                    + ' -d \'{"key":"${snakeoilKeypair.pubkey}","read_only":true,"title":"SSH"}\'''
                )

                machine.succeed(
                    "${scripts.git-setup}"
                )

                machine.succeed(
                    "${scripts.hydra-setup}"
                )

                machine.wait_until_succeeds(
                    'curl -Lf -s http://localhost:3000/build/1 -H "Accept: application/json" '
                    + '|  jq .buildstatus | xargs test 0 -eq'
                )

                data = machine.succeed(
                    'curl -Lf -s "http://localhost:3001/api/v1/repos/root/repo/statuses/$(cd /tmp/repo && git show | head -n1 | awk "{print \\$2}")" '
                    + "-H 'Accept: application/json' -H 'Content-Type: application/json' "
                    + f"-H 'Authorization: token ${api_token}'"
                )

                response = json.loads(data)

                assert len(response) == 2, "Expected exactly three status updates for latest commit (queued, finished)!"
                assert response[0]['status'] == "success", "Expected finished status to be success!"
                assert response[1]['status'] == "pending", "Expected queued status to be pending!"

                machine.shutdown()
              '';
          });

        tests.validate-openapi = forEachSystem (system:
          let pkgs = pkgsBySystem.${system}; in
          pkgs.runCommand "validate-openapi"
          { buildInputs = [ pkgs.openapi-generator-cli ]; }
          ''
            openapi-generator-cli validate -i ${./hydra-api.yaml}
            touch $out
          '');

        container = nixosConfigurations.container.config.system.build.toplevel;
      };

      checks = forEachSystem (system: {
        build = hydraJobs.build.${system};
        install = hydraJobs.tests.install.${system};
        validate-openapi = hydraJobs.tests.validate-openapi.${system};
      });

      packages = forEachSystem (system: {
        hydra = pkgsBySystem.${system}.hydra;
        default = pkgsBySystem.${system}.hydra;
      });

      nixosModules = import ./nixos-modules {
        overlays = overlayList;
      };

      nixosConfigurations.container = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules =
          [
            self.nixosModules.hydraTest
            self.nixosModules.hydraProxy
            {
              system.configurationRevision = self.lastModifiedDate;

              boot.isContainer = true;
              networking.useDHCP = false;
              networking.firewall.allowedTCPPorts = [ 80 ];
              networking.hostName = "hydra";

              services.hydra-dev.useSubstitutes = true;
            }
          ];
      };

    };
}
