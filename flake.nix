{
  description = "Lux Manifest Cache — precomputed rockspec JSON for luarocks.org packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      luaWithCjson = pkgs.lua5_4.withPackages (ps: [ ps.cjson ]);
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          luaWithCjson
          pkgs.curl
          pkgs.coreutils
        ];
      };

      packages.${system}.default = pkgs.stdenv.mkDerivation {
        name = "lux-manifest-cache";
        src = ./.;
        buildInputs = [
          luaWithCjson
          pkgs.curl
          pkgs.coreutils
        ];
        installPhase = ''
          mkdir -p $out
          cp build-cache.lua $out/
          cp -r src $out/
        '';
      };
    };
}
