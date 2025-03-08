{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
    devenv.url = "github:cachix/devenv/1e4701fb1f51f8e6fe3b0318fc2b80aed0761914";
    foundry.url = "github:shazow/foundry.nix";
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs = { self, nixpkgs, devenv, systems, foundry, ... } @ inputs:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);
    in
    {
      devShells = forEachSystem
        (system:
          let
            # pkgs = nixpkgs.legacyPackages.${system};
            pkgs = import nixpkgs { 
              inherit system;
              overlays = [ foundry.overlay ];
            };
          in
          {
            default = devenv.lib.mkShell {
              inherit inputs pkgs;
              modules = [
                {
                  languages.javascript = {
                    enable = true;
                  };

                  packages = with pkgs; [ foundry-bin solc ];

                  enterShell = ''
                    echo "VULT contracts shell activated!"
                  '';
                }
              ];
            };
          });
    };
}
