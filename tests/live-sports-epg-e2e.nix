{ pkgs, lib, extraModules }:

pkgs.testers.runNixOSTest {
  name = "live-sports-epg-e2e";

  # Run under emulation when KVM is unavailable (e.g. GitHub-hosted runners).
  requiredFeatures.kvm = false;

  nodes.machine = { config, pkgs, lib, ... }: {
    imports = [ ../modules/media-server.nix ../modules/monitoring.nix ] ++ extraModules;

    services.mediaServer = {
      enable = true;
      domainBase = "epg.test";
      tlsMode = "none";
      gpu = "none";
      jellyfin.enable = false;
      emby.enable = false;
      audiobookshelf.enable = false;
      wizarr.enable = false;
      samba.enable = false;
      nanitor.enable = false;
      liveSportsEpg = {
        enable = true;
        # Loopback-only fixture served by epg-fixture.service below.
        m3uUrlFile = "/etc/live-sports-epg-e2e.url";
        listenPort = 8098;
        refreshMinutes = 1;
        lookAheadDays = 1;
        sports = [ "NFL" ];
        logLevel = "debug";
      };
    };

    environment.etc."live-sports-epg-e2e.url".text = "http://127.0.0.1:9192/m3u\n";

    # Stand-in for the public ESPN API so the test is fully offline.
    systemd.services.live-sports-epg.environment.ESPN_BASE_URL = "http://127.0.0.1:9192/espn";
    systemd.services.live-sports-epg.after = [ "epg-fixture.service" ];
    systemd.services.live-sports-epg.wants = [ "epg-fixture.service" ];

    systemd.services.epg-fixture = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./live-sports-epg-e2e-server.py}";
        Restart = "always";
      };
    };

    services.caddy.enable = lib.mkForce false;
    services.smartd.enable = lib.mkForce false;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("epg-fixture.service")
    machine.wait_for_unit("live-sports-epg.service")

    # The service writes its first EPG before serving /status.
    machine.wait_until_succeeds(
      "${pkgs.curl}/bin/curl -fsS http://127.0.0.1:8098/status | grep -q '\"matched\": 3'",
      timeout=300,
    )

    epg = machine.succeed("${pkgs.curl}/bin/curl -fsS http://127.0.0.1:8098/epg.xml")

    # Regression guard: hyphenated/run-together provider tvg-ids must resolve.
    assert "Indianapolis Colts at Dallas Cowboys" in epg, "hyphenated tvg-id not matched"
    assert "San Francisco 49ers at Las Vegas Raiders" in epg, "punctuated/numeric tvg-id not matched"
    assert "New Orleans Saints at Cleveland Browns" in epg, "run-together tvg-id not matched"

    # No 60-minute placeholder leakage for matched games, and real logos present.
    assert "[Live event (unmatched" not in epg, "matched games still rendered unmatched placeholders"
    assert "https://logo.example/dal.png" in epg, "home-team logo missing"
    assert "https://logo.example/lv.png" in epg, "home-team logo missing (numeric tvg-id)"
    assert "https://logo.example/no.png" in epg, "away-feed logo missing"
  '';
}
