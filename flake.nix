{
  description = "twesterhout/halide-haskell: Running Halide pipelines from Haskell";

  # We have a patched Halide version, so we need cachix such that users don't
  # have to compile Halide locally
  nixConfig = {
    extra-experimental-features = "nix-command flakes";
    extra-substituters = "https://halide-haskell.cachix.org";
    extra-trusted-public-keys = "halide-haskell.cachix.org-1:cFPqtShCsH4aNjn2q4PHb39Omtd/FWRhrkTBcSrtNKQ=";
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nix-filter.url = "github:numtide/nix-filter";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      # don't look for a flake.nix file in this repository
      # this tells Nix to retrieve this input as just source code
      flake = false;
    };
    halide = {
      url = "github:halide/Halide";
      flake = false;
    };
    nixGL = {
      url = "github:guibou/nixGL";
      inputs.flake-utils.follows = "flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: inputs.flake-utils.lib.eachDefaultSystem (system:
    with builtins;
    let
      inherit (inputs.nixpkgs) lib;
      enableExceptions = drv: drv.overrideAttrs (attrs: {
        cmakeFlags = (attrs.cmakeFlags or [ ]) ++ [
          "-DLLVM_ENABLE_EH=ON"
        ];
      });
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [
          (self: super: {
            halide =
              (super.halide.override {
                llvmPackages = super.llvmPackages // {
                  libllvm = enableExceptions super.libllvm;
                  llvm = enableExceptions super.llvm;
                };
              }).overrideAttrs (attrs: {
                version = "16.0.0";
                src = inputs.halide;
                cmakeFlags = attrs.cmakeFlags ++
                  [
                    "-DWITH_TESTS=OFF"
                    "-DWITH_PYTHON_BINDINGS=OFF"
                    "-DWITH_DOCS=OFF"
                    "-DWITH_UTILS=OFF"
                    "-DWITH_TUTORIALS=OFF"
                    "-DHalide_ENABLE_RTTI=ON"
                    "-DHalide_ENABLE_EXCEPTIONS=ON"
                  ];
              });
          })
        ];
      };

      # only consider source dirs and package.yaml as source to our Haskell package
      # this allows the project to rebuild only when source files change, not e.g. readme
      src = inputs.nix-filter.lib {
        root = ./.;
        include = [
          "src"
          "example"
          "test"
          "halide-haskell.cabal"
          "README.md"
          "CHANGELOG.md"
          "LICENSE"
        ];
      };

      halide-haskell-for = haskellPackages:
        let
          builder =
            { withIntelOpenCL
            , withCuda
            , Halide
            }:
            (haskellPackages.callCabal2nix "halide-haskell" src { inherit Halide; }).overrideAttrs (attrs: {
              nativeBuildInputs = attrs.nativeBuildInputs
                ++ lib.optional withIntelOpenCL pkgs.makeWrapper;
              propagatedBuildInputs = with pkgs;
                attrs.propagatedBuildInputs
                ++ lib.optionals withIntelOpenCL [ clinfo intel-ocl ocl-icd ]
                ++ lib.optional withCuda inputs.nixGL.packages.${system}.nixGLDefault;
              postInstall = (attrs.postInstall or "")
                + (if withIntelOpenCL then ''
                wrapProgram $out/bin/halide-haskell \
                  --prefix LD_LIBRARY_PATH : ${pkgs.ocl-icd}/lib \
                  --prefix OCL_ICD_VENDORS : ${pkgs.intel-ocl}/etc/OpenCL/vendors
              '' else "")
                + (if withCuda then ''
                prog="$out/bin/halide-haskell"
                hidden="$(dirname "$prog")/.$(basename "$prog")"-wrapped
                mv "$prog" "$hidden"
                echo "#!${pkgs.stdenv.shell}" > "$prog"
                echo "exec ${inputs.nixGL.packages.${system}.nixGLDefault}/bin/nixGL $hidden \"\$@\"" >> "$prog"
                chmod +x "$prog"
              '' else "");
              # NOTE: This does not work... :(
              # setupHook = with pkgs; writeText "setup-hook.sh" ''
              #   setupOpenCL() {
              #     export PATH=${clinfo}/bin:$PATH
              #     export LD_LIBRARY_PATH=${ocl-icd}/lib:${Halide}/lib:$LD_LIBRARY_PATH
              #     export OCL_ICD_VENDORS="${pkgs.intel-ocl}/etc/OpenCL/vendors"
              #   }
              #   addEnvHooks "$hostOffset" setupOpenCL
              # '';
            });
        in
        lib.makeOverridable builder { withIntelOpenCL = false; withCuda = false; Halide = pkgs.halide; };

      # This allows us to build a Haskell package with any given GHC version.
      # It will also affects all dependent libraries.
      # overrides allows us to patch existing Haskell packages, or introduce new ones
      # see here for specifics: https://nixos.wiki/wiki/Overlays
      haskellPackagesOverride = ps:
        ps.override
          {
            overrides = self: super: {
              halide-haskell = halide-haskell-for self;
              # self.callCabal2nix "halide-haskell" src {
              #   Halide = pkgs.halide;
              # };
              #halide-haskell-cuda = self.halide-haskell.override { withCuda = true; };
              #halide-haskell-intelOcl = self.halide-haskell.overrideAttrs (attrs: {});
            };
          };

      outputsFor =
        { haskellPackages
        , name
        , package ? ""
        , ...
        }:
        let ps = haskellPackagesOverride haskellPackages; in
        rec {
          packages = {
            "${name}" = ps.${package} or ps;
            "${name}-cuda" = ps.${package}.override { withCuda = true; };
            "${name}-intel-ocl" = ps.${package}.override { withIntelOpenCL = true; };
          };
          devShells =
            let
              genericShell =
                { withIntelOpenCL ? false
                , withCuda ? false
                } @ args:
                ps.shellFor {
                  packages = ps: [ (ps.halide-haskell.override args) ];
                  withHoogle = true;
                  nativeBuildInputs = with pkgs; with ps; [
                    cabal-install
                    fourmolu
                    haskell-language-server
                    nixpkgs-fmt
                  ]
                  ++ lib.optional withIntelOpenCL clinfo
                  ++ lib.optional withCuda inputs.nixGL.packages.${system}.nixGLDefault;
                  shellHook = ''
                    export PROMPT_COMMAND=""
                    export PS1='(nix) GHC ${haskellPackages.ghc.version} \w $ '
                    export LD_LIBRARY_PATH=${pkgs.halide}/lib:$LD_LIBRARY_PATH
                  '' + (if withIntelOpenCL then ''
                    export LD_LIBRARY_PATH=${pkgs.ocl-icd}/lib:$LD_LIBRARY_PATH
                    export OCL_ICD_VENDORS="${pkgs.intel-ocl}/etc/OpenCL/vendors"
                  '' else "");
                };
            in
            {
              "${name}" = genericShell { };
              "${name}-cuda" = genericShell { withCuda = true; };
              "${name}-intel-ocl" = genericShell { withIntelOpenCL = true; };
            };
          # The formatter to use for .nix files (but not .hs files)
          # Allows us to run `nix fmt` to reformat nix files.
          formatter = pkgs.nixpkgs-fmt;
        };
    in
    foldl' (acc: conf: lib.recursiveUpdate acc (outputsFor conf)) { }
      (lib.mapAttrsToList (name: haskellPackages: { inherit name haskellPackages; }) pkgs.haskell.packages ++ [
        {
          haskellPackages = pkgs.haskellPackages;
          name = "defaultGhc";
        }
        {
          haskellPackages = pkgs.haskellPackages;
          name = "default";
          package = "halide-haskell";
        }
      ])
  );
}
