{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  unzip,
  makeWrapper,
  makeDesktopItem,

  libgcc,
  glib,
  nspr,
  nss,
  dbus,
  at-spi2-atk,
  at-spi2-core,
  cups,
  cairo,
  gtk3,
  gtk4,
  pango,
  libdrm,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxrandr,
  libgbm,
  libxkbcommon,
  expat,
  alsa-lib,
  libnotify,
  libpulseaudio,
  libva,
  pipewire,
  xorg,
  vulkan-loader,
  mesa,
  libGL,
  systemd,

  position,
  hash,
  constants,
}:
let
  desktopItem = makeDesktopItem {
    name = "chromium-snapshot";
    desktopName = "Chromium Snapshot";
    genericName = "Web Browser";
    exec = "chromium-snapshot %U";
    icon = "chromium-snapshot";
    categories = [
      "Network"
      "WebBrowser"
    ];
    mimeTypes = [
      "text/html"
      "text/xml"
      "application/xhtml+xml"
      "x-scheme-handler/http"
      "x-scheme-handler/https"
    ];
    startupNotify = true;
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "chromium-snapshot";
  version = position;

  src = fetchurl {
    url = "${constants.snapshot_base}/${position}/chrome-linux.zip";
    inherit hash;
    name = "chromium-snapshot-${position}.zip";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    unzip
    makeWrapper
  ];

  buildInputs = [
    libgcc
    glib
    nspr
    nss
    dbus
    at-spi2-atk
    at-spi2-core
    cups
    cairo
    gtk3
    gtk4
    pango
    libdrm
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    libgbm
    libxkbcommon
    expat
    alsa-lib
    libnotify
    libpulseaudio
    libva
    pipewire
    xorg.libX11
    xorg.libxcb
    xorg.libXext
    xorg.libXi
    xorg.libXtst
    xorg.libXcursor
    xorg.libXScrnSaver
    vulkan-loader
    mesa
    libGL
    systemd
  ];

  autoPatchelfIgnoreMissingDeps = [
    "libQt5Core.so.5"
    "libQt5Gui.so.5"
    "libQt5Widgets.so.5"
    "libQt6Core.so.6"
    "libQt6Gui.so.6"
    "libQt6Widgets.so.6"
  ];

  dontBuild = true;
  dontConfigure = true;
  noDumpEnvVars = true;

  unpackPhase = ''
    unzip $src
  '';

  installPhase = ''
    runHook preInstall

    # Find the extracted directory (chrome-linux or chrome-linux64)
    chromeDir=""
    if [ -d chrome-linux ]; then
      chromeDir=chrome-linux
    elif [ -d chrome-linux64 ]; then
      chromeDir=chrome-linux64
    else
      echo "ERROR: Could not find chrome-linux directory in snapshot archive"
      exit 1
    fi

    mkdir -p $out/bin $out/opt/chromium-snapshot $out/share

    # Copy all files from the extracted directory
    cp -r "$chromeDir"/* $out/opt/chromium-snapshot/

    # Wrap the chrome binary
    makeWrapper "$out/opt/chromium-snapshot/chrome" "$out/bin/chromium-snapshot" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath finalAttrs.buildInputs}" \
      --add-flags "\''${NIXOS_OZONE_WL:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations}"

    # Install desktop file
    mkdir -p $out/share/applications
    cp ${desktopItem}/share/applications/*.desktop $out/share/applications/

    # Install icons if available
    for icon in $out/opt/chromium-snapshot/product_logo_*.png; do
      if [ -f "$icon" ]; then
        size=$(basename "$icon" | grep -oP '(?<=product_logo_)\d+')
        if [ -n "$size" ]; then
          install -Dm644 "$icon" \
            "$out/share/icons/hicolor/''${size}x''${size}/apps/chromium-snapshot.png"
        fi
      fi
    done

    runHook postInstall
  '';

  meta = {
    description = "Chromium Snapshot - latest CI builds (no Widevine/DRM support)";
    homepage = "https://www.chromium.org";
    license = lib.licenses.bsd3;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "chromium-snapshot";
  };
})
