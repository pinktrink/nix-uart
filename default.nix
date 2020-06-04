{
  serialID ? false,
  usbDevice ? if !serialID then "/dev/ttyUSB0" else "/dev/uart-${serialID}",
  keys ? [],
  gpioChip ? "/dev/gpiochip0",
  ppin ? 8,
  spin ? 9,
  idVendor ? "0403",
  idProduct ? "6001",
  pkgs ? import <nixpkgs> {},
  ...
}:
let
  inherit (pkgs) writeTextFile;
  inherit (pkgs.lib) mkIf;
  inherit (pkgs.lib.attrsets) mapAttrs attrValues;
  inherit (pkgs.python3) withPackages;

  withKeys = u: mapAttrs (_: v: v // { openssh.authorizedKeys.keys = keys; }) ({ root = { }; } // u);

  shells = let
    py3 = withPackages (pp: with pp; [ python-periphery ]);

    writeShellSCScriptBin = name: text: writeTextFile {
      inherit name;
      executable = true;
      destination = "/bin/${name}";
      text = ''
        #!${pkgs.stdenv.shell}
        ${text}
      '';
      checkPhase = ''
        ${pkgs.shellcheck}/bin/shellcheck -s bash $out/bin/${name}
      '';
    };
    writePythonScriptBin = name: text: writeTextFile {
      inherit name;
      executable = true;
      destination = "/bin/${name}";
      text = ''
        #!${py3}/bin/python
        ${text}
      '';

      checkPhase = ''
        ${pkgs.python37Packages.black}/bin/black --check --diff --quiet $out/bin/${name}
      '';
    };

    shellOverride = name: _: {
      passthru.shellPath = "/bin/${name}";
    };

    mkShell = name: text: (writeShellSCScriptBin name text).overrideAttrs (shellOverride name);
    mkPythonShell = name: text: (writePythonScriptBin name text).overrideAttrs (shellOverride name);

    gpioImport = ''
      from periphery import GPIO

    '';
    fullImport = gpioImport + ''
      import time

    '';
    pin = s: ''
      pin = GPIO("${gpioChip}", ${if s then (toString ppin) else (toString spin)}, "${if s then "out" else "in"}")
    '';
    high = ''
      pin.write(True)
    '';
    low = ''
      pin.write(False)
    '';
    power = high + low;
    sleep = s: ''
      time.sleep(${toString s})
    '';
    hardPower = high + sleep 11 + low;
    close = ''
      pin.close()'';
  in {
    uart-shell = mkShell "uart-shell" ''
      ${pkgs.minicom}/bin/minicom -b 115200 -o -D ${usbDevice}
      exit
    '';

    cycle-shell = mkPythonShell "cycle-shell" (fullImport + pin true + power + sleep 3 + power + close);
    power-shell = mkPythonShell "power-shell" (gpioImport + pin true + power + close);
    hard-cycle-shell = mkPythonShell "hard-cycle-shell" (fullImport + pin true + hardPower + sleep 3 + power + close);
    hard-power-shell = mkPythonShell "hard-power-shell" (fullImport + pin true + hardPower + close);

    status-shell = mkPythonShell "status-shell" (gpioImport + pin false + ''
      print("on" if pin.read() else "off")
    '' + close);
  };
in {
  environment.systemPackages = with pkgs; [
    bashInteractive_5
  ] ++ attrValues shells;

  services = {
    openssh.enable = true;
    udev.packages = mkIf serialID [
      (writeTextFile {
        name = "uart-rules";
        destination = "/etc/udev/rules.d/99-uart.rules";
        text = ''
          SUBSYSTEM=="tty", ATTRS{idVendor}=="${idVendor}", ATTRS{idProduct}=="${idProduct}", ATTRS{serial}=="${serialID}", SYMLINK+="uart-${serialID}"
        '';
      })
    ];
  };

  users = {
    mutableUsers = false;
    users = withKeys {
      uart.shell = shells.uart-shell;
      cycle.shell = shells.cycle-shell;
      power.shell = shells.power-shell;
      hard-cycle.shell = shells.hard-cycle-shell;
      hard-power.shell = shells.hard-power-shell;
      status.shell = shells.status-shell;
    };
    defaultUserShell = pkgs.bashInteractive_5;
  };
}
