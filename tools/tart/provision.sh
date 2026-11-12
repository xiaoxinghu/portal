#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Run INSIDE a disposable macOS guest, as root, after creating its test account.
# Usage: sudo bash /Volumes/My\ Shared\ Files/setup/provision.sh SHARED_DIRECTORY USER
set -euo pipefail
[[ $# == 2 && $EUID == 0 ]] || { echo 'Usage: sudo bash provision.sh SHARED_DIRECTORY USER' >&2; exit 1; }
[[ $(sysctl -n kern.hv_vmm_present) == 1 ]] || { echo 'Refusing to configure a physical Mac.' >&2; exit 1; }
share=$(cd -- "$1" && pwd)
user=$2
[[ $user =~ ^[a-z][a-z0-9_]*$ && $user != root ]] || exit 1
[[ $(stat -f %Su /dev/console) == "$user" ]] || { echo 'Log in to the guest desktop as the test user first.' >&2; exit 1; }
home=/Users/$user
[[ -d $home ]] || exit 1
(cd "$share" && shasum -a 256 -c SHA256SUMS)
# shellcheck source=tools/tart/recipe.conf
. "$share/recipe.conf"
[[ $(sw_vers -productVersion) == "$MACOS_VERSION" && $(sw_vers -buildVersion) == "$MACOS_BUILD" ]] || { echo 'Guest OS does not match recipe.conf.' >&2; exit 1; }
# Extract into an empty directory; copying over an existing Xcode can leave
# stale files that invalidate its signature. Refuse partial preinstallations.
if [[ ! -e /Applications/Xcode.app && ! -e /Applications/Emacs.app ]]; then
    stage=$(mktemp -d /Applications/.portal-tools.XXXXXX)
    trap 'rm -rf "$stage"' EXIT
    tar --no-xattrs -xpf "$share/apps.tar" -C "$stage"
    codesign --verify --deep --strict "$stage/Xcode.app"
    codesign --verify --deep --strict "$stage/Emacs.app"
    mv "$stage/Xcode.app" "$stage/Emacs.app" /Applications/
fi
[[ $(/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -version) == "Xcode $XCODE_VERSION"$'\n'"Build version $XCODE_BUILD" ]]
mkdir -p /opt/homebrew/{bin,opt,Cellar}
tar --no-xattrs -xpf "$share/cellar.tar" -C /opt/homebrew
while IFS= read -r package; do
    name=${package%%/*}
    ln -sfn "../Cellar/$package" "/opt/homebrew/opt/$name"
    for binary in /opt/homebrew/Cellar/"$package"/bin/*; do
        [[ -e $binary ]] || continue
        ln -sfn "../Cellar/$package/bin/${binary##*/}" "/opt/homebrew/bin/${binary##*/}"
    done
done < "$share/cellar.txt"
install -m 755 "$share/bun" /opt/homebrew/bin/bun
bash "$share/install-rex.sh" "$share"
xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -license accept
xcodebuild -runFirstLaunch
[[ $(sudo -H -u "$user" /Applications/Emacs.app/Contents/MacOS/Emacs --batch -Q --eval '(princ emacs-repository-version)') == "$EMACS_REVISION" ]]
pmset -a sleep 0 displaysleep 0 disksleep 0
sudo -H -u "$user" defaults -currentHost write com.apple.screensaver idleTime -int 0
sudo -H -u "$user" defaults write com.apple.screensaver askForPassword -int 0
sudo -H -u "$user" defaults write com.apple.CrashReporter DialogType none
# Keep user shell configuration, sourcing one managed file only once.
mkdir -p "$home/.config/portal-tart"
cat > "$home/.config/portal-tart/environment.zsh" <<'ENV'
export PATH=/opt/homebrew/bin:$PATH
export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
export LIBRARY_PATH="$(/usr/libexec/PlistBuddy -c Print:LSEnvironment:LIBRARY_PATH /Applications/Emacs.app/Contents/Info.plist)"
ENV
# The guest shell expands HOME when it reads this line.
# shellcheck disable=SC2016
line='source "$HOME/.config/portal-tart/environment.zsh"'
touch "$home/.zshenv"
grep -Fqx "$line" "$home/.zshenv" || printf '\n%s\n' "$line" >> "$home/.zshenv"
cp "$share"/{recipe.conf,cellar.txt,SHA256SUMS} "$home/.config/portal-tart/"
chown -R "$user":staff "$home/.config/portal-tart" "$home/.zshenv"
mkdir -p /etc/sudoers.d
printf '%s ALL=(root) NOPASSWD: /sbin/shutdown -h now\n' "$user" > /etc/sudoers.d/portal-vm-shutdown
chmod 440 /etc/sudoers.d/portal-vm-shutdown
visudo -cf /etc/sudoers.d/portal-vm-shutdown
sudo -H -u "$user" /bin/zsh -c 'exec bash "$1" "$2"' -- "$share/verify.sh" "$share"
