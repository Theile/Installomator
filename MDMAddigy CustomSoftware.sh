#!/bin/zsh

# Specific settings in Addigy to configure Custom Software for installomator.
# Addigy has 3 parts to fill out for this, Installation script, Conditions, and Removal steps.

# Installation script
# Just click “Add” to the autogenerated script by clicking the “Add”-button next to the Installer PKG.

# Conditions
# Remember to fill out the correct “TARGET_VERSION” and click "Install on succes".
TARGET_VERSION="0.5.8"

APP="/usr/local/bin/Installomator.sh"
if [ ! -f ${APP} ]; then
    echo "Does not exist: ${APP}"
    exit 0
fi

INSTALLED_VERSION="$(/usr/local/bin/Installomator.sh version | tail -1 | awk '{print $4}')"
#if [[ "$TARGET_VERSION" != "$INSTALLED_VERSION" ]]; then
#    echo "Version mismatch"
#    echo "Found: $INSTALLED_VERSION"
#    echo "Expected: $TARGET_VERSION"
#    exit 0
#fi

vercomp () {
    if [[ $1 == $2 ]]
    then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

echo "Current Version: ${INSTALLED_VERSION}"

vercomp ${TARGET_VERSION} ${INSTALLED_VERSION}
COMP=$? # 0 means the same, 1 means TARGET is newer, 2 means INSTALLED is newer
echo "COMPARISON: ${COMP}"

if [ "${COMP}" -eq 1 ]
then
    echo "Installed version is older than ${TARGET_VERSION}."
    exit 0
else
    echo "Installed version is the same or newer than ${TARGET_VERSION}."
    exit 1
fi

# Removal steps
pkgutil --forget "dk.theilgaard.pkg.Installomator"
rm /usr/local/bin/Installomator.sh
rm /usr/local/bin/InstallomatorLabels.sh