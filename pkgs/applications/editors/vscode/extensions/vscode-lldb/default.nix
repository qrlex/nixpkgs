{ pkgs, lib, stdenv, fetchFromGitHub, runCommand, rustPlatform, makeWrapper, llvmPackages
, nodePackages, cmake, nodejs, unzip, python3, pkg-config, libsecret
}:
assert lib.versionAtLeast python3.version "3.5";
let
  publisher = "vadimcn";
  pname = "vscode-lldb";
  version = "1.8.1";

  vscodeExtUniqueId = "${publisher}.${pname}";
  vscodeExtPublisher = publisher;
  vscodeExtName = pname;

  src = fetchFromGitHub {
    owner = "vadimcn";
    repo = "vscode-lldb";
    rev = "v${version}";
    sha256 = "sha256-5wrw8LNH14WAyIKIRGFbvrISb5RUXeD5Uh/weja9p4Q=";
  };

  # need to build a custom version of lldb and llvm for enhanced rust support
  lldb = (import ./lldb.nix { inherit fetchFromGitHub runCommand llvmPackages; });

  adapter = rustPlatform.buildRustPackage {
    pname = "${pname}-adapter";
    inherit version src;

    cargoSha256 = "sha256-Lpo2jaDMaZGwSrpQBvBCscVbWi2Db1Cx1Tv84v1H4Es=";

    nativeBuildInputs = [ makeWrapper ];

    buildAndTestSubdir = "adapter";

    buildFeatures = [ "weak-linkage" ];

    cargoBuildFlags = [
      "--lib"
      "--bin=codelldb"
    ];

    # Tests are linked to liblldb but it is not available here.
    doCheck = false;
  };

  nodeDeps = ((import ./build-deps/default.nix {
    inherit pkgs nodejs;
    inherit (stdenv.hostPlatform) system;
  }).nodeDependencies.override (old: {
    inherit src version;
    nativeBuildInputs = [ pkg-config ];
    buildInputs = [libsecret];
    dontNpmInstall = true;
  }));

  # debugservers on macOS require the 'com.apple.security.cs.debugger'
  # entitlement which nixpkgs' lldb-server does not yet provide; see
  # <https://github.com/NixOS/nixpkgs/pull/38624> for details
  lldbServer = if stdenv.isDarwin then
    "/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver"
  else
    "${lldb.out}/bin/lldb-server";

in stdenv.mkDerivation {
  pname = "vscode-extension-${publisher}-${pname}";
  inherit src version vscodeExtUniqueId vscodeExtPublisher vscodeExtName;

  installPrefix = "share/vscode/extensions/${vscodeExtUniqueId}";

  nativeBuildInputs = [ cmake nodejs unzip makeWrapper ];

  patches = [ ./cmake-build-extension-only.patch ];

  postConfigure = ''
    cp -r ${nodeDeps}/lib/{node_modules,package-lock.json} .
  '' + lib.optionalString stdenv.isDarwin ''
    mkdir -p "$(pwd)/home"
    export HOME="$(pwd)/home"
  '';

  cmakeFlags = [
    # Do not append timestamp to version.
    "-DVERSION_SUFFIX="
  ];
  makeFlags = [ "vsix_bootstrap" ];

  installPhase = ''
    ext=$out/$installPrefix
    runHook preInstall

    unzip ./codelldb-bootstrap.vsix 'extension/*' -d ./vsix-extracted

    mkdir -p $ext/{adapter,formatters}
    mv -t $ext vsix-extracted/extension/*
    cp -t $ext/adapter ${adapter}/{bin,lib}/* ../adapter/*.py
    cp -r -t $ext/adapter ../adapter/scripts
    wrapProgram $ext/adapter/codelldb \
      --prefix LD_LIBRARY_PATH : "$ext/lldb/lib" \
      --set-default LLDB_DEBUGSERVER_PATH "${lldbServer}"
    cp -t $ext/formatters ../formatters/*.py
    ln -s ${lldb.lib} $ext/lldb
    # Mark that all components are installed.
    touch $ext/platform.ok

    runHook postInstall
  '';

  # `adapter` will find python binary and libraries at runtime.
  postFixup = ''
    wrapProgram $out/$installPrefix/adapter/codelldb \
      --prefix PATH : "${python3}/bin" \
      --prefix LD_LIBRARY_PATH : "${python3}/lib"
  '';

  passthru = {
    inherit lldb adapter;
    updateScript = ./update.sh;
  };

  meta = with lib; {
    description = "A native debugger extension for VSCode based on LLDB";
    homepage = "https://github.com/vadimcn/vscode-lldb";
    license = with licenses; [ mit ];
    maintainers = with maintainers; [ nigelgbanks ];
    platforms = platforms.all;
  };
}
