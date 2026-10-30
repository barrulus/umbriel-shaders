{ lib, stdenv, cmake, ninja, pkg-config, nlohmann_json, tomlplusplus, openssl, curl, python3 }:
stdenv.mkDerivation {
  pname = "umbriel-shaders-native";
  version = "0.2.0";
  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: type:
      lib.cleanSourceFilter path type &&
      !(type == "directory" && (lib.hasPrefix "build" (baseNameOf path) ||
        baseNameOf path == "bin" || baseNameOf path == ".local"));
  };
  nativeBuildInputs = [ cmake ninja pkg-config ];
  buildInputs = [ nlohmann_json tomlplusplus openssl curl ];
  nativeCheckInputs = [ python3 ];
  doCheck = true;
  cmakeFlags = [ "-DBUILD_TESTING=ON" ];
  checkPhase = ''
    runHook preCheck
    ctest --output-on-failure
    runHook postCheck
  '';
  meta = {
    description = "Native backend for the Noctalia Umbriel Shaders plugin";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "umbriel-shaders-native";
  };
}
