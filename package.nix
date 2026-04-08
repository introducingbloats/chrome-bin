{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  dpkg,
  makeWrapper,

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
  channel ? "stable",
}:
let
  versions = lib.importJSON ./version.json;
  currentVersion = versions.${channel};
  channelSlug = {
    stable = "stable";
    beta = "beta";
    dev = "unstable";
    canary = "canary";
  }.${channel};
  pname = "google-chrome-${channel}";
  mainBin = "google-chrome-${channelSlug}";
  srcBin = {
    stable = "google-chrome";
    beta = "google-chrome-beta";
    dev = "google-chrome-unstable";
    canary = "google-chrome-canary";
  }.${channel};
  optDir = {
    stable = "chrome";
    beta = "chrome-beta";
    dev = "chrome-unstable";
    canary = "chrome-canary";
  }.${channel};
  constants = lib.importJSON ./constants.json;
  downloadUrl = "${constants.download_base}/google-chrome-${channelSlug}_current_amd64.deb";
in
stdenv.mkDerivation (finalAttrs: {
  inherit pname;
  version = currentVersion.version;

  src = fetchurl {
    url = downloadUrl;
    hash = currentVersion.hash;
    name = "google-chrome-${channelSlug}-${currentVersion.version}-amd64.deb";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
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
    dpkg-deb --fsys-tarfile $src | tar xf - --no-same-permissions --no-same-owner
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share $out/opt

    cp -r opt/google/${optDir} $out/opt/${optDir}

    # Wrap the source binary (srcBin) to the output binary name (mainBin)
    makeWrapper "$out/opt/${optDir}/${srcBin}" "$out/bin/${mainBin}" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath finalAttrs.buildInputs}" \
      --add-flags "\''${NIXOS_OZONE_WL:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations}"

    # For stable channel, also create a google-chrome symlink
    ${lib.optionalString (channel == "stable") ''
      ln -sf "$out/bin/${mainBin}" "$out/bin/google-chrome"
    ''}

    # Install icons
    for icon in $out/opt/${optDir}/product_logo_*.png; do
      if [ -f "$icon" ]; then
        size=$(basename "$icon" | grep -oP '(?<=product_logo_)\d+')
        if [ -n "$size" ]; then
          install -Dm644 "$icon" \
            "$out/share/icons/hicolor/''${size}x''${size}/apps/${pname}.png"
        fi
      fi
    done

    # Install upstream .desktop files, patching paths
    if [ -d usr/share/applications ]; then
      mkdir -p $out/share/applications
      for desktop_file in usr/share/applications/*.desktop; do
        if [ -f "$desktop_file" ]; then
          sed \
            -e "s|/usr/bin/${mainBin}|$out/bin/${mainBin}|g" \
            -e "s|^Icon=.*|Icon=${pname}|" \
            "$desktop_file" > "$out/share/applications/$(basename "$desktop_file")"
        fi
      done
    fi

    # Install man pages
    if [ -d usr/share/man ]; then
      mkdir -p $out/share/man
      cp -r usr/share/man/* $out/share/man/
    fi

    # Install appdata/metainfo
    if [ -d usr/share/appdata ]; then
      mkdir -p $out/share/metainfo
      cp -r usr/share/appdata/* $out/share/metainfo/
    fi

    runHook postInstall
  '';

  postFixup = ''
    # Remove chrome-sandbox (we use namespace sandboxing instead)
    if [ -f "$out/opt/${optDir}/chrome-sandbox" ]; then
      rm "$out/opt/${optDir}/chrome-sandbox"
    fi
  '';

  meta = {
    description = "Google Chrome - ${{
      stable = "Stable";
      beta = "Beta";
      dev = "Dev";
      canary = "Canary";
    }.${channel}} Channel";
    homepage = "https://www.google.com/chrome";
    license = lib.licenses.unfreeRedistributable;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = mainBin;
  };
})
