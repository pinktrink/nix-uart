{
  name,
  usbDevice,
  cfg ? "aarch64-unknown-linux-gnu",
  system ? "aarch64-linux",
  keys ? [],
  headless ? true,
  timeZone ? "Etc/UTC",
  ppin ? 8,
  pkgs ? import <nixpkgs> {},
  ...
}:
let
  inherit (pkgs) writeTextFile writeShellScriptBin;
  inherit (pkgs.lib.attrsets) mapAttrs attrValues;

  imports' = if headless then [] else [ <nixpkgs/nixos/modules/profiles/headless.nix> ];
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
    pin = ''
      pin = GPIO(${toString ppin}, "out")
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

    cycle-shell = mkPythonShell "cycle-shell" (fullImport + pin + power + sleep3 + power + close);
    power-shell = mkPythonShell "power-shell" (gpioImport + pin + power + close);
    hard-cycle-shell = mkPythonShell "hard-cycle-shell" (fullImport + pin + hardPower + sleep3 + power + close);
    hard-power-shell = mkPythonShell "hard-poweroff-shell" (fullImport + pin + hardPower + close);
  };
in {
  imports = imports';

  boot.cleanTmpDir = true;

  time.timeZone = timeZone;

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
