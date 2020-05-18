{
  name,
  usbDevice ? "/dev/ttyUSB0",
  cfg ? "aarch64-unknown-linux-gnu",
  system ? "aarch64-linux",
  keys ? [],
  headless ? true,
  timeZone ? "Etc/UTC",
  gpioChip ? "/dev/gpiochip0",
  ppin ? 8,
  spin ? 9,
  pkgs ? import <nixpkgs> {},
  ...
}:
let
  inherit (pkgs) writeTextFile writeShellScriptBin;
  inherit (pkgs.lib.attrsets) mapAttrs attrValues;

  imports' = if headless then [ <nixpkgs/nixos/modules/profiles/headless.nix> ] else [];
  withKeys = u: mapAttrs (_: v: v // { openssh.authorizedKeys.keys = keys; }) ({ root = { }; } // u);
  writePythonScriptBin = name: text: writeTextFile {
    inherit name;
    text = ''
      #!${pkgs.python3}
      ${text}
    '';

    checkPhase = ''
      ${pkgs.python3}/bin/python -m py_compile $out/${name}
    '';
  };

  shells = let
    mkShell = name: text: (writeShellScriptBin {
      inherit name text;
    }).overrideAttrs (_: {
      passthru.shellPath = "/bin/${name}";
    });
    mkPythonShell = name: text: (writePythonScriptBin name text).overrideAttrs (_: {
      passthru.shellPath = "/bin/${name}";
    });

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
    sleep11 = ''
      time.sleep(11)
    '';
    hardPower = high + sleep11 + low;
    sleep3 = ''
      time.sleep(3)
    '';
    close = ''
      pin.close()
    '';
    power-text = gpioImport + pin + power + close;
  in {
    uart-shell = writeShellScriptBin "uart-shell" ''
      ${pkgs.minicom}/bin/minicom -b 115200 -o -D ${usbDevice}
      exit
    '';

    cycle-shell = mkPythonShell "cycle-shell" (fullImport + pin true + power + sleep3 + power + close);
    power-shell = mkPythonShell "power-shell" (gpioImport + pin true + power + close);
    hard-cycle-shell = mkPythonShell "hard-cycle-shell" (fullImport + pin true + hardPower + sleep3 + power + close);
    hard-power-shell = mkPythonShell "hard-poweroff-shell" (fullImport + pin true + hardPower + close);

    status-shell = mkPythonShell "status-shell" (gpioImport + pin false + ''
      state = pin.read()
      print("on" if state else "off")
    '' + close);
  };
in {
  imports = imports';

  boot.cleanTmpDir = true;

  time.timeZone = timeZone;

  networking.hostName = "${name}-gateway";

  programs.bash = {
    enableCompletion = true;
    promptInit = ''
      export TERM=xterm
    '';
  };

  environment.systemPackages = with pkgs; [ bashInteractive_5 ] ++ attrValues shells;

  services.openssh = {
    enable = true;
    passwordAuthentication = false;
  };

  users = {
    mutableUsers = false;
    users = withKeys {
      uart = {
        description = "${name} UART access";
        shell = shells.uart-shell;
      };
      cycle = {
        description = "Reboot ${name}";
        shell = shells.cycle-shell;
      };
      power = {
        description = "Power ${name}";
        shell = shells.power-shell;
      };
      hard-cycle = {
        description = "Hard reboot ${name}";
        shell = shells.hard-cycle-shell;
      };
      hard-power = {
        description = "Hard power ${name}";
        shell = shells.hard-power-shell;
      };
      status = {
        description = "Status of ${name}";
        shell = shells.status-shell;
      };
    };
    defaultUserShell = pkgs.bashInteractive_5;
  };

  nix.extraOptions = ''
    trusted-users = [ @wheel ]
  '';

  nixpkgs.localSystem = {
    config = cfg;
    inherit system;
  };
}
