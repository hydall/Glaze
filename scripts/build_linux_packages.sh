#!/bin/bash
set -e

# Change to the root of the project
cd "$(dirname "$0")/.."

APP_NAME="glaze-flutter"
# Executable name inside the Flutter bundle (BINARY_NAME in linux/CMakeLists.txt).
BINARY_NAME="Glaze"
# Extract version from pubspec.yaml (e.g. 0.7.0)
VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: //g' | cut -d '+' -f 1 | tr -d '\r')
ARCH=$(uname -m)

if [ -z "$VERSION" ]; then
    echo "Error: Could not determine version from pubspec.yaml"
    exit 1
fi

echo "Building $APP_NAME version $VERSION for architecture $ARCH..."

# Run the flutter build
echo "Running flutter build linux --release $@"
flutter build linux --release "$@"

BUNDLE_DIR="build/linux/x64/release/bundle"

if [ ! -d "$BUNDLE_DIR" ]; then
    echo "Error: Build directory '$BUNDLE_DIR' not found. Did the build fail?"
    exit 1
fi

# flutter_inappwebview_linux copies libWPEWebKit/libwpe into the bundle under
# their full version names (libWPEWebKit-2.0.so.1.6.9), not their sonames, so
# the loader never picks them up and the app always uses the system WPE WebKit.
# Drop the dead copies — libWPEWebKit alone is ~150 MB.
rm -f "$BUNDLE_DIR"/lib/libWPEWebKit-2.0.so* "$BUNDLE_DIR"/lib/libwpe-1.0.so*

# 1. Build Pacman Package (Arch / CachyOS)
if command -v makepkg &> /dev/null; then
    echo "Building pacman package..."
    ARCH_DIR="build/linux/arch"
    mkdir -p "$ARCH_DIR"
    
    # Generate PKGBUILD for pre-built binaries
    cat <<EOF > "$ARCH_DIR/PKGBUILD"
pkgname=$APP_NAME-bin
pkgver=$VERSION
pkgrel=1
pkgdesc="Native LLM frontend for AI roleplay (Flutter)"
arch=('x86_64')
url="https://github.com/hydall/Glaze"
license=('AGPL3')
depends=('gtk3' 'glib2' 'sqlite3' 'wpewebkit' 'libsecret')
options=('!strip' '!emptydirs')

package() {
    mkdir -p "\$pkgdir/opt/$APP_NAME"
    mkdir -p "\$pkgdir/usr/bin"
    mkdir -p "\$pkgdir/usr/share/applications"
    mkdir -p "\$pkgdir/usr/share/icons/hicolor/512x512/apps"

    # Copy from the flutter release bundle
    cp -r "\$srcdir/../../x64/release/bundle/"* "\$pkgdir/opt/$APP_NAME/"
    
    # Symlink binary
    ln -s "/opt/$APP_NAME/$BINARY_NAME" "\$pkgdir/usr/bin/$APP_NAME"
    
    # Copy icon
    if [ -f "\$srcdir/../../../../assets/logos/glaze.png" ]; then
        cp "\$srcdir/../../../../assets/logos/glaze.png" "\$pkgdir/usr/share/icons/hicolor/512x512/apps/$APP_NAME.png"
    fi

    # Create desktop file
    cat <<DESKTOP > "\$pkgdir/usr/share/applications/$APP_NAME.desktop"
[Desktop Entry]
Name=Glaze
Comment=Native LLM frontend for AI roleplay
Exec=$APP_NAME
Icon=$APP_NAME
Terminal=false
Type=Application
Categories=Utility;Chat;Network;
DESKTOP
}
EOF

    # Build the package using makepkg. --nodeps skips the depends=() check so
    # packaging never tries to install anything; a real `pacman -U` install
    # still enforces depends=() on the target machine. makepkg refuses to run
    # as root, so CI calls this script as an unprivileged user. Guarded so a
    # makepkg failure doesn't abort the script and lose the tarball below.
    cd "$ARCH_DIR"
    if makepkg -f --nodeps --noconfirm; then
        cd - > /dev/null
        echo "Pacman package created in $ARCH_DIR"
    else
        cd - > /dev/null
        echo "::warning::makepkg failed — no pacman package was produced. See the log above for the pacman/alpm error."
    fi
else
    echo "makepkg not found. Skipping pacman package creation."
fi

# 2. Build portable .tar.zst (Arch Linux native compression)
# A plain tarball of the bundle for users who want no package manager at all.
# The machine still needs WPE WebKit installed (e.g. `pacman -S wpewebkit`).
# zstd is in the CI dependency list; guarded anyway so a missing tool doesn't
# abort the script and lose packages that already built.
if command -v tar &> /dev/null && tar --help | grep -q zstd 2>/dev/null; then
    echo "Building .tar.zst archive..."
    TARZST_DIR="build/linux/tarzst"
    mkdir -p "$TARZST_DIR/glaze-${VERSION}"
    cp -r "$BUNDLE_DIR"/* "$TARZST_DIR/glaze-${VERSION}/"
    tar --zstd -cf "$TARZST_DIR/glaze-${VERSION}-linux-${ARCH}.tar.zst" -C "$TARZST_DIR" "glaze-${VERSION}"
    rm -rf "$TARZST_DIR/glaze-${VERSION}"
    echo "Tar.zst created at $TARZST_DIR/glaze-${VERSION}-linux-${ARCH}.tar.zst"
else
    echo "::warning::tar with zstd support not found — no .tar.zst archive was produced."
fi

echo "Packaging complete!"
