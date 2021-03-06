#!/bin/zsh

# Installomator
#
# Downloads and installs an Applications
# 2020 Armin Briegel - Scripting OS X
#
# https://github.com/scriptingosx/Installomator
#
# inspired by the download scripts from William Smith and Sander Schram
# with additional ideas and contribution from Isaac Ordonez, Mann consulting
#
# This branch by Søren Theilgaard (@theilgaard)
# -  Mostly to implement version checking before demanding app to close
#    but also to separate the labels.
# -  Not recommended for use in Jamf Pro.
# -  Testet with Mosyle Business and Manager.
# https://github.com/theile/Installomator

#set -o xtrace # outputting every command of the script
#set -x # Debug

VERSION='0.4.21' # This version branched by Søren Theilgaard
VERSIONDATE='2021-03-17'
VERSIONBRANCH='Søren Theilgaard'

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# NOTE: adjust these variables:

# set to 0 for production, 1 for debugging
# while debugging, items will be downloaded to the parent directory of this script
# also no actual installation will be performed
DEBUG=0


# notify behavior
NOTIFY=success
# options:
#   - success      notify the user on success
#   - silent       no notifications
#   - all          all notifications (great for Self Service installation)


# behavior when blocking processes are found
BLOCKING_PROCESS_ACTION=prompt_user_loop
# options:
#   - ignore       continue even when blocking processes are found
#   - silent_fail  exit script without prompt or installation
#   - prompt_user  show a user dialog for each blocking process found
#                  abort after three attempts to quit
#                  (only if user accepts to quit the apps, otherwise
#                  the update is cancelled).
#   - prompt_user_then_kill
#                  show a user dialog for each blocking process found,
#                  attempt to quit two times, kill the process finally
#   - prompt_user_loop
#                  Like prompt-user, but clicking "Not Now", will just wait an hour,
#                  and then it will ask again.
#   - tell_user    User will be showed a notification about the important update,
#                  but user is only allowed to quit and continue, and then we
#                  ask the app to quit.
#   - tell_user_then_kill
#                  Show dialog 2 times, and if the quitting fails, the
#                  blocking processes will be killed.
#   - kill         kill process without prompting or giving the user a chance to save


# logo-icon used in dialog boxes if app is blocking
LOGO=appstore
# options:
#   - appstore      Icon is Apple App Store (default)
#   - jamf          JAMF Pro
#   - mosyleb       Mosyle Business
#   - mosylem       Mosyle Manager (Education)
# path can also be set in the command call, and if file exists, it will be used, like 'LOGO="/System/Applications/App\ Store.app/Contents/Resources/AppIcon.icns"' (spaces are escaped).


# install behavior
INSTALL=""
# options:
#  -               When not set, software will only be installed
#                  if it is newer/different in version
#  - force         Install even if it’s the same version


# NOTE: How labels work

# Each workflow label needs to be listed in the case statement below.
# for each label these variables can be set:
#
# - name: (required)
#   Name of the installed app.
#   This is used to derive many of the other variables.
#
# - type: (required)
#   The type of the installation. Possible values:
#     - dmg
#     - pkg
#     - zip
#     - pkgInDmg
#     - pkgInZip (not yet tested)
#     - appInDmgInZip
#
# - packageID: (optional)
#   The package ID of a pkg
#   If given, will be used to find version of installed software, instead of searching for an app.
#   Usefull if a pkg does not install an app.
#   See label installomator_st
#
# - downloadURL: (required)
#   URL to download the dmg.
#   Can be generated with a series of commands (see BBEdit for an example).
#
# - appNewVersion: (optional)
#   Version of the downloaded software.
#   If given, it will be compared to installed version, to see if download is different.
#   It does not check for newer or not, only different.
#
# - expectedTeamID: (required)
#   10-digit developer team ID.
#   Obtain the team ID by running:
#
#   - Applications (in dmgs or zips)
#     spctl -a -vv /Applications/BBEdit.app
#
#   - Pkgs
#     spctl -a -vv -t install ~/Downloads/desktoppr-0.2.pkg
#
#   The team ID is the ten-digit ID at the end of the line starting with 'origin='
#
# - archiveName: (optional)
#   The name of the downloaded file.
#   When not given the archiveName is derived from the $name.
#
# - appName: (optional)
#   File name of the app bundle in the dmg to verify and copy (include .app).
#   When not given, the appName is derived from the $name.
#
# - targetDir: (optional)
#   dmg or zip:
#     Applications will be copied to this directory.
#     Default value is '/Applications' for dmg and zip installations.
#   pkg:
#     targetDir is used as the install-location. Default is '/'.
#
# - blockingProcesses: (optional)
#   Array of process names that will block the installation or update.
#   If no blockingProcesses array is given the default will be:
#     blockingProcesses=( $name )
#   When a package contains multiple applications, _all_ should be listed, e.g:
#     blockingProcesses=( "Keynote" "Pages" "Numbers" )
#   When a workflow has no blocking processes, use
#     blockingProcesses=( NONE )
#
# - pkgName: (optional, only used for pkgInDmg, dmgInZip, and appInDmgInZip)
#   File name of the pkg/dmg file _inside_ the dmg or zip
#   When not given the pkgName is derived from the $name
#
# - updateTool:
# - updateToolArguments:
#   When Installomator detects an existing installation of the application,
#   and the updateTool variable is set
#      $updateTool $updateArguments
#   Will be run instead of of downloading and installing a complete new version.
#   Use this when the updateTool does differential and optimized downloads.
#   e.g. msupdate
#
# - updateToolRunAsCurrentUser:
#   When this variable is set (any value), $updateTool will be run as the current user.
#


# MARK: Load the labels
SELF=$(basename $0)
SELFLOCATION=$(dirname $0)
labelFile="${SELFLOCATION}/InstallomatorLabels.sh"
source "${labelFile}"
if [ $? != 0 ]; then; echo "Label-file is missing, expected here: ${labelFile}"; exit $?; fi


# MARK: Functions

cleanupAndExit() { # $1 = exit code, $2 message
    if [[ -n $2 && $1 -ne 0 ]]; then
        printlog "ERROR: $2"
    fi
    if [ "$DEBUG" -eq 0 ]; then
        # remove the temporary working directory when done
        printlog "Deleting $tmpDir"
        rm -Rf "$tmpDir"
    fi

    if [ -n "$dmgmount" ]; then
        # unmount disk image
        printlog "Unmounting $dmgmount"
        hdiutil detach "$dmgmount"
    fi
    # If we closed any processes, reopen the app again
    #reopenClosedProcess
    printlog "################## End Installomator, exit code $1 \n\n"
    exit "$1"
}

runAsUser() {
    if [[ $currentUser != "loginwindow" ]]; then
        uid=$(id -u "$currentUser")
        launchctl asuser $uid sudo -u $currentUser "$@"
    fi
}

displaydialog() { # $1: message $2: title
    message=${1:-"Message"}
    title=${2:-"Installomator"}
    runAsUser osascript -e "button returned of (display dialog \"$message\" with  title \"$title\" buttons {\"Not Now\", \"Quit and Update\"} default button \"Quit and Update\" with icon POSIX file \"$LOGO\")"
}

displaydialogContinue() { # $1: message $2: title
    message=${1:-"Message"}
    title=${2:-"Installomator"}
    runAsUser osascript -e "button returned of (display dialog \"$message\" with  title \"$title\" buttons {\"Quit and Update\"} default button \"Quit and Update\" with icon POSIX file \"$LOGO\")"
}

displaynotification() { # $1: message $2: title
    message=${1:-"Message"}
    title=${2:-"Notification"}
    manageaction="/Library/Application Support/JAMF/bin/Management Action.app/Contents/MacOS/Management Action"

    if [[ -x "$manageaction" ]]; then
         "$manageaction" -message "$message" -title "$title"
    else
        runAsUser osascript -e "display notification \"$message\" with title \"$title\""
    fi
}


# MARK: Logging
log_location="/private/var/log/Installomator.log"

printlog(){

    timestamp=$(date +%F\ %T)
        
    if [[ "$(whoami)" == "root" ]]; then
        echo "$timestamp" "$label" "$1" | tee -a $log_location
    else
        echo "$timestamp" "$label" "$1"
    fi
    # Logging to system.log
    logger -t "$SELF" "$label $1"
}

# will get the latest release download from a github repo
downloadURLFromGit() { # $1 git user name, $2 git repo name
    gitusername=${1?:"no git user name"}
    gitreponame=${2?:"no git repo name"}
    
    if [[ $type == "pkgInDmg" ]]; then
        filetype="dmg"
    elif [[ $type == "pkgInZip" ]]; then
        filetype="zip"
    else
        filetype=$type
    fi
    
    if [ -n "$archiveName" ]; then
    downloadURL=$(curl --silent --fail "https://api.github.com/repos/$gitusername/$gitreponame/releases/latest" \
    | awk -F '"' "/browser_download_url/ && /$archiveName\"/ { print \$4; exit }")
    else
    downloadURL=$(curl --silent --fail "https://api.github.com/repos/$gitusername/$gitreponame/releases/latest" \
    | awk -F '"' "/browser_download_url/ && /$filetype\"/ { print \$4; exit }")
    fi
    if [ -z "$downloadURL" ]; then
        cleanupAndExit 9 "could not retrieve download URL for $gitusername/$gitreponame"
        #exit 9
    else
        echo "$downloadURL"
        return 0
    fi
}

versionFromGit() {
    # credit: Søren Theilgaard (@theilgaard)
    # $1 git user name, $2 git repo name
    gitusername=${1?:"no git user name"}
    gitreponame=${2?:"no git repo name"}
        
    appNewVersion=$(curl --silent --fail "https://api.github.com/repos/$gitusername/$gitreponame/releases/latest" | grep tag_name | cut -d '"' -f 4 | sed 's/[^0-9\.]//g')
    if [ -z "$appNewVersion" ]; then
        printlog "could not retrieve version number for $gitusername/$gitreponame"
        appNewVersion=""
    else
        echo "$appNewVersion"
        return 0
    fi
}


# Handling of differences in xpath between Catalina and Big Sur
xpath() {
    # the xpath tool changes in Big Sur and now requires the `-e` option
    if [[ $(sw_vers -buildVersion) > "20A" ]]; then
        /usr/bin/xpath -e $@
        # alternative: switch to xmllint (which is not perl)
        #xmllint --xpath $@ -
    else
        /usr/bin/xpath $@
    fi
}


getAppVersion() {
    # modified by: Søren Theilgaard (@theilgaard)
    # pkgs contains a version number, then we don't have to search for an app
    if [[ $packageID != "" ]]; then
        appversion="$(pkgutil --pkg-info-plist ${packageID} 2>/dev/null | grep -A 1 pkg-version | tail -1 | sed -E 's/.*>([0-9.]*)<.*/\1/g')"
        if [[ $appversion != "" ]]; then
            printlog "found packageID $packageID installed, version $appversion"
            return
        else
            printlog "No version found using packageID $packageID"
        fi
    fi
    
    # get all apps matching name
    applist=$(mdfind "kind:application $appName" -0 )
    if [[ $applist = "" ]]; then
        printlog "Spotlight not returning any app, trying manually in /Applications."
        if [[ -d "/Applications/$appName" ]]; then
            applist="/Applications/$appName"
        fi
    fi
     
    appPathArray=( ${(0)applist} )

    if [[ ${#appPathArray} -gt 0 ]]; then
        filteredAppPaths=( ${(M)appPathArray:#${targetDir}*} )
        if [[ ${#filteredAppPaths} -eq 1 ]]; then
            installedAppPath=$filteredAppPaths[1]
            #appversion=$(mdls -name kMDItemVersion -raw $installedAppPath )
            appversion=$(defaults read $installedAppPath/Contents/Info.plist CFBundleShortVersionString) #Not dependant on Spotlight indexing
            printlog "found app at $installedAppPath, version $appversion"
        else
            printlog "could not determine location of $appName"
        fi
    else
        printlog "could not find $appName"
    fi
}

checkRunningProcesses() {
    # don't check in DEBUG mode
    if [[ $DEBUG -ne 0 ]]; then
        printlog "DEBUG mode, not checking for blocking processes"
        return
    fi

    # try at most 3 times
    for i in {1..4}; do
        countedProcesses=0
        for x in ${blockingProcesses}; do
            if pgrep -xq "$x"; then
                printlog "found blocking process $x"
                appClosed=1
                
                case $BLOCKING_PROCESS_ACTION in
                    kill)
                      printlog "killing process $x"
                      pkill $x
                      sleep 5
                      ;;
                    prompt_user|prompt_user_then_kill)
                      button=$(displaydialog "Quit “$x” to continue updating? (Leave this dialogue if you want to activate this update later)." "The application “$x” needs to be updated.")
                      if [[ $button = "Not Now" ]]; then
                        cleanupAndExit 10 "user aborted update"
                      else
                        if [[ $i > 2 && $BLOCKING_PROCESS_ACTION = "prompt_user_then_kill" ]]; then
                          printlog "Changing BLOCKING_PROCESS_ACTION to kill"
                          BLOCKING_PROCESS_ACTION=kill
                        else
                          printlog "telling app $x to quit"
                          runAsUser osascript -e "tell app \"$x\" to quit"
                          # give the user a bit of time to quit apps
                          printlog "waiting 30 seconds for processes to quit"
                          sleep 30
                        fi
                      fi
                      ;;
                    prompt_user_loop)
                      button=$(displaydialog "Quit “$x” to continue updating? (Click “Not Now” to be asked in 1 hour, or leave this open until you are ready)." "The application “$x” needs to be updated.")
                      if [[ $button = "Not Now" ]]; then
                        if [[ $i < 2 ]]; then
                          printlog "user wants to wait an hour"
                          sleep 3600 # 3600 seconds is an hour
                        else
                          printlog "change of BLOCKING_PROCESS_ACTION to tell_user"
                          BLOCKING_PROCESS_ACTION=tell_user
                        fi
                      else
                        printlog "telling app $x to quit"
                        runAsUser osascript -e "tell app \"$x\" to quit"
                        # give the user a bit of time to quit apps
                        printlog "waiting 30 seconds for processes to quit"
                        sleep 30
                      fi
                      ;;
                    tell_user|tell_user_then_kill)
                      button=$(displaydialogContinue "Quit “$x” to continue updating? (This is an important update). Wait for notification of update before launching app again." "The application “$x” needs to be updated.")
                      printlog "telling app $x to quit"
                      runAsUser osascript -e "tell app \"$x\" to quit"
                      # give the user a bit of time to quit apps
                      printlog "waiting 30 seconds for processes to quit"
                      sleep 30
                      if [[ $i > 1 && $BLOCKING_PROCESS_ACTION = tell_user_then_kill ]]; then
                          printlog "Changing BLOCKING_PROCESS_ACTION to kill"
                          BLOCKING_PROCESS_ACTION=kill
                      fi
                      ;;
                    silent_fail)
                      cleanupAndExit 12 "blocking process '$x' found, aborting"
                      ;;
                esac

                countedProcesses=$((countedProcesses + 1))
            fi
        done

    done

    if [[ $countedProcesses -ne 0 ]]; then
        cleanupAndExit 11 "could not quit all processes, aborting..."
    fi

    printlog "no more blocking processes, continue with update"
}

reopenClosedProcess() {
    # If Installomator closed any processes, let's get the app opened again
    # credit: Søren Theilgaard (@theilgaard)
    
    # don't reopen in DEBUG mode
    if [[ $DEBUG -ne 0 ]]; then
        printlog "DEBUG mode, not reopening anything"
        return
    fi
    
    if [[ $appClosed == 1 ]]; then
        printlog "Telling app $name to open"
        runAsUser osascript -e "tell app \"$name\" to open"
    fi
}

installAppWithPath() { # $1: path to app to install in $targetDir
    # modified by: Søren Theilgaard (@theilgaard)
    appPath=${1?:"no path to app"}

    # check if app exists
    if [ ! -e "$appPath" ]; then
        cleanupAndExit 8 "could not find: $appPath"
    fi

    # verify with spctl
    printlog "Verifying: $appPath"
    if ! teamID=$(spctl -a -vv "$appPath" 2>&1 | awk '/origin=/ {print $NF }' | tr -d '()' ); then
        cleanupAndExit 4 "Error verifying $appPath"
    fi

    printlog "Team ID matching: $teamID (expected: $expectedTeamID )"

    if [ "$expectedTeamID" != "$teamID" ]; then
        cleanupAndExit 5 "Team IDs do not match"
    fi

    # versioncheck
    # credit: Søren Theilgaard (@theilgaard)
    appNewVersion=$(defaults read $appPath/Contents/Info.plist CFBundleShortVersionString)
    if [[ $appversion == $appNewVersion ]]; then
        printlog "Downloaded version of $name is $appNewVersion, same as installed."
        if [[ $INSTALL != "force" ]]; then
            message="$name, version $appNewVersion, is  the latest version."
            if [[ $currentUser != "loginwindow" && $NOTIFY == "all" ]]; then
                printlog "notifying"
                displaynotification "$message" "No update for $name!"
            fi
            cleanupAndExit 0 "No new version to install"
        else
            printlog "Using force to install anyway."
        fi
    else
        printlog "Downloaded version of $name is $appNewVersion (replacing version $appversion)."
    fi

    # skip install for DEBUG
    if [ "$DEBUG" -ne 0 ]; then
        printlog "DEBUG enabled, skipping remove, copy and chown steps"
        return 0
    fi

    # check for root
    if [ "$(whoami)" != "root" ]; then
        # not running as root
        cleanupAndExit 6 "not running as root, exiting"
    fi

    # remove existing application
    if [ -e "$targetDir/$appName" ]; then
        printlog "Removing existing $targetDir/$appName"
        rm -Rf "$targetDir/$appName"
    fi

    # copy app to /Applications
    printlog "Copy $appPath to $targetDir"
    if ! ditto "$appPath" "$targetDir/$appName"; then
        cleanupAndExit 7 "Error while copying"
    fi


    # set ownership to current user
    if [ "$currentUser" != "loginwindow" ]; then
        printlog "Changing owner to $currentUser"
        chown -R "$currentUser" "$targetDir/$appName"
    else
        printlog "No user logged in, not changing user"
    fi

}

mountDMG() {
    # mount the dmg
    printlog "Mounting $tmpDir/$archiveName"
    # always pipe 'Y\n' in case the dmg requires an agreement
    if ! dmgmount=$(echo 'Y'$'\n' | hdiutil attach "$tmpDir/$archiveName" -nobrowse -readonly | tail -n 1 | cut -c 54- ); then
        cleanupAndExit 3 "Error mounting $tmpDir/$archiveName"
    fi

    if [[ ! -e $dmgmount ]]; then
        printlog "Error mounting $tmpDir/$archiveName"
        cleanupAndExit 3
    fi

    printlog "Mounted: $dmgmount"
}

installFromDMG() {
    mountDMG

    installAppWithPath "$dmgmount/$appName"
}

installFromPKG() {
    # verify with spctl
    printlog "Verifying: $archiveName"
    
    if ! spctlout=$(spctl -a -vv -t install "$archiveName" 2>&1 ); then
        printlog "Error verifying $archiveName"
        cleanupAndExit 4
    fi
    
    teamID=$(echo $spctlout | awk -F '(' '/origin=/ {print $2 }' | tr -d '()' )

    # Apple signed software has no teamID, grab entire origin instead
    if [[ -z $teamID ]]; then
        teamID=$(echo $spctlout | awk -F '=' '/origin=/ {print $NF }')
    fi


    printlog "Team ID: $teamID (expected: $expectedTeamID )"

    if [ "$expectedTeamID" != "$teamID" ]; then
        printlog "Team IDs do not match!"
        cleanupAndExit 5
    fi

    # skip install for DEBUG
    if [ "$DEBUG" -ne 0 ]; then
        printlog "DEBUG enabled, skipping installation"
        return 0
    fi

    # check for root
    if [ "$(whoami)" != "root" ]; then
        # not running as root
        printlog "not running as root, exiting"
        cleanupAndExit 6
    fi

    # install pkg
    printlog "Installing $archiveName to $targetDir"
    if ! installer -pkg "$archiveName" -tgt "$targetDir" ; then
        printlog "error installing $archiveName"
        cleanupAndExit 9
    fi
}

installFromZIP() {
    # unzip the archive
    printlog "Unzipping $archiveName"
    
    # tar -xf "$archiveName"

    # note: when you expand a zip using tar in Mojave the expanded
    # app will never pass the spctl check

    # unzip -o -qq "$archiveName"
    
    # note: githubdesktop fails spctl verification when expanded
    # with unzip
    
    ditto -x -k "$archiveName" "$tmpDir"
    installAppWithPath "$tmpDir/$appName"
}

installFromTBZ() {
    # unzip the archive
    printlog "Unzipping $archiveName"
    tar -xf "$archiveName"
    installAppWithPath "$tmpDir/$appName"
}

installPkgInDmg() {
    mountDMG
    # locate pkg in dmg
    if [[ -z $pkgName ]]; then
        # find first file ending with 'pkg'
        findfiles=$(find "$dmgmount" -iname "*.pkg" -maxdepth 1  )
        filearray=( ${(f)findfiles} )
        if [[ ${#filearray} -eq 0 ]]; then
            cleanupAndExit 20 "couldn't find pkg in dmg $archiveName"
        fi
        archiveName="${filearray[1]}"
        printlog "found pkg: $archiveName"
    else
        # it is now safe to overwrite archiveName for installFromPKG
        archiveName="$dmgmount/$pkgName"
    fi

    # installFromPkgs
    installFromPKG
}

installPkgInZip() {
    # unzip the archive
    printlog "Unzipping $archiveName"
    tar -xf "$archiveName"

    # locate pkg in zip
    if [[ -z $pkgName ]]; then
        # find first file ending with 'pkg'
        findfiles=$(find "$tmpDir" -iname "*.pkg" -maxdepth 2  )
        filearray=( ${(f)findfiles} )
        if [[ ${#filearray} -eq 0 ]]; then
            cleanupAndExit 20 "couldn't find pkg in zip $archiveName"
        fi
        archiveName="${filearray[1]}"
        # it is now safe to overwrite archiveName for installFromPKG
        printlog "found pkg: $archiveName"
    else
        # it is now safe to overwrite archiveName for installFromPKG
        archiveName="$tmpDir/$pkgName"
    fi

    # installFromPkgs
    installFromPKG
}

installAppInDmgInZip() {
    # unzip the archive
    printlog "Unzipping $archiveName"
    tar -xf "$archiveName"

    # locate dmg in zip
    if [[ -z $pkgName ]]; then
        # find first file ending with 'dmg'
        findfiles=$(find "$tmpDir" -iname "*.dmg" -maxdepth 2  )
        filearray=( ${(f)findfiles} )
        if [[ ${#filearray} -eq 0 ]]; then
            cleanupAndExit 20 "couldn't find dmg in zip $archiveName"
        fi
        archiveName="$(basename ${filearray[1]})"
        # it is now safe to overwrite archiveName for installFromDMG
        printlog "found dmg: $tmpDir/$archiveName"
    else
        # it is now safe to overwrite archiveName for installFromDMG
        archiveName="$pkgName"
    fi

    # installFromDMG, DMG expected to include an app (will not work with pkg)
    installFromDMG
}

runUpdateTool() {
    if [[ -x $updateTool ]]; then
        printlog "running $updateTool $updateToolArguments"
        if [[ -n $updateToolRunAsCurrentUser ]]; then
            runAsUser $updateTool ${updateToolArguments}
        else
            $updateTool ${updateToolArguments}
        fi
        if [[ $? -ne 0 ]]; then
            cleanupAndExit 15 "Error running $updateTool"
        fi
    else
        printlog "couldn't find $updateTool, continuing normally"
        return 1
    fi
    return 0
}


# MARK: check minimal macOS requirement
autoload is-at-least

if ! is-at-least 10.14 $(sw_vers -productVersion); then
    printlog "Installomator requires at least macOS 10.14 Mojave."
    exit 98
fi

# MARK: argument parsing
if [[ $# -eq 0 ]]; then
    printlog "no label provided, printing labels, version $labelsVERSION:"
    #grep -E '^[a-z0-9\_-]*(\)|\|\\)$' "$0" | tr -d ')|\' | grep -v -E '^(broken.*|longversion|version|valuesfromarguments)$' | sort
    grep -E '^[a-z0-9\_-]*(\)|\|\\)$' "${labelFile}" | tr -d ')|\' | grep -v -E '^(broken.*|longversion|version|valuesfromarguments)$' | sort
    exit 0
elif [[ $1 == "/" ]]; then
    # jamf uses sends '/' as the first argument
    printlog "shifting arguments for Jamf"
    shift 3
    printlog "This version of Installomator is not compatible with Jamf"
    exit 1
fi

while [[ -n $1 ]]; do
    if [[ $1 =~ ".*\=.*" ]]; then
        # if an argument contains an = character, send it to eval
        printlog "setting variable from argument $1"
        eval $1
    else
        # assume it's a label
        label=$1
    fi
    # shift to next argument
    shift 1
done

# lowercase the label
label=${label:l}

printlog "################## Start Installomator v. $VERSION from $VERSIONDATE, branch $VERSIONBRANCH"
printlog "Labels file: ${labelFile}, version $labelsVERSION"
printlog "################## $label"

# get current user
currentUser=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ { print $3 }')

# MARK: labels moved to function caseLabel in InstallomatorLabels.sh
caseLabel

# MARK: application download and installation starts here

printlog "BLOCKING_PROCESS_ACTION=${BLOCKING_PROCESS_ACTION}"
printlog "NOTIFY=${NOTIFY}"

# Finding LOGO to use in dialogs
case $LOGO in
    appstore)
        # Apple App Store on Mac
        if [[ $(sw_vers -buildVersion) > "19" ]]; then
            LOGO="/System/Applications/App Store.app/Contents/Resources/AppIcon.icns"
        else
            LOGO="/Applications/App Store.app/Contents/Resources/AppIcon.icns"
        fi
        ;;
    jamf)
        # Jamf Pro
        LOGO="/Library/Application Support/JAMF/Jamf.app/Contents/Resources/AppIcon.icns"
        #LOGO="/Library/Application Support/JAMF/Logos/Logo512.png"
        ;;
    mosyleb)
        # Mosyle Business
        LOGO="/Applications/Business.app/Contents/Resources/AppIcon.icns"
        ;;
    mosylem)
        # Mosyle Manager (education)
        LOGO="/Applications/Manager.app/Contents/Resources/AppIcon.icns"
        ;;
esac
if [[ ! -a "${LOGO}" ]]; then
    if [[ $(sw_vers -buildVersion) > "19" ]]; then
        LOGO="/System/Applications/App Store.app/Contents/Resources/AppIcon.icns"
    else
        LOGO="/Applications/App Store.app/Contents/Resources/AppIcon.icns"
    fi
fi
printlog "LOGO=${LOGO}"

# MARK: extract info from data
if [ -z "$archiveName" ]; then
    case $type in
        dmg|pkg|zip|tbz)
            archiveName="${name}.$type"
            ;;
        pkgInDmg)
            archiveName="${name}.dmg"
            ;;
        *InZip)
            archiveName="${name}.zip"
            ;;
        *)
            printlog "Cannot handle type $type"
            cleanupAndExit 99
            ;;
    esac
fi

if [ -z "$appName" ]; then
    # when not given derive from name
    appName="$name.app"
fi

if [ -z "$targetDir" ]; then
    case $type in
        dmg|zip|tbz|app*)
            targetDir="/Applications"
            ;;
        pkg*)
            targetDir="/"
            ;;
        *)
            printlog "Cannot handle type $type"
            cleanupAndExit 99
            ;;
    esac
fi

if [[ -z $blockingProcesses ]]; then
    printlog "no blocking processes defined, using $name as default"
    blockingProcesses=( $name )
fi

# MARK: determine tmp dir
if [ "$DEBUG" -ne 0 ]; then
    # for debugging use script dir as working directory
    tmpDir=$(dirname "$0")
else
    # create temporary working directory
    tmpDir=$(mktemp -d )
fi

# MARK: change directory to temporary working directory
printlog "Changing directory to $tmpDir"
if ! cd "$tmpDir"; then
    printlog "error changing directory $tmpDir"
    #rm -Rf "$tmpDir"
    cleanupAndExit 1
fi

# MARK: check if this is an Update
getAppVersion
if [[ -n $appVersion ]]; then
    if [[ $DEBUG -eq 0 ]]; then
        if runUpdateTool; then
            cleanupAndExit 0
        fi # otherwise continue
    else
        printlog "DEBUG mode enabled, not running update tool"
    fi
fi

# MARK: Exit if new version is the same as installed version (appNewVersion specified)
# credit: Søren Theilgaard (@theilgaard)
if [[ -n $appNewVersion ]]; then
	printlog "Latest version of $name is $appNewVersion"
	if [[ $appversion == $appNewVersion ]]; then
	    if [[ $DEBUG -eq 0 ]]; then
			printlog "There is no newer version available."
            if [[ $INSTALL != "force" ]]; then
                message="$name, version $appNewVersion, is  the latest version."
                if [[ $currentUser != "loginwindow" && $NOTIFY == "all" ]]; then
                    printlog "notifying"
                    displaynotification "$message" "No update for $name!"
                fi
                cleanupAndExit 0 "No newer version."
            else
                printlog "Using force to install anyway."
            fi
	    else
	        printlog "DEBUG mode enabled, not exiting, but there is no new version of app."
	    fi
	fi
else
	printlog "Latest version not specified."
fi

# MARK: download the archive
if [ -f "$archiveName" ] && [ "$DEBUG" -ne 0 ]; then
    printlog "$archiveName exists and DEBUG enabled, skipping download"
else
    # download the dmg
    printlog "Downloading $downloadURL to $archiveName"
    if [[ $currentUser != "loginwindow" && $NOTIFY == "all" ]]; then
        printlog "notifying"
        displaynotification "Downloading $name update" "Download in progress …"
    fi
    if ! curl --location --fail --silent "$downloadURL" -o "$archiveName"; then
        printlog "error downloading $downloadURL"
        message="$name update/installation failed. This will be logged, so IT can follow up."
        if [[ $currentUser != "loginwindow" && $NOTIFY == "all" ]]; then
            printlog "notifying"
            displaynotification "$message" "Error installing/updating $name"
        fi
        cleanupAndExit 2
    fi
fi

# MARK: when user is logged in, and app is running, prompt user to quit app
if [[ $BLOCKING_PROCESS_ACTION == "ignore" ]]; then
    printlog "ignoring blocking processes"
else
    if [[ $currentUser != "loginwindow" ]]; then
        if [[ ${#blockingProcesses} -gt 0 ]]; then
            if [[ ${blockingProcesses[1]} != "NONE" ]]; then
                checkRunningProcesses
            fi
        fi
    fi
fi

# MARK: install the download
printlog "Installing $name"
if [[ $currentUser != "loginwindow" && $NOTIFY == "all" ]]; then
    printlog "notifying"
    displaynotification "Installing $name" "Installation in progress …"
fi

case $type in
    dmg)
        installFromDMG
        ;;
    pkg)
        installFromPKG
        ;;
    zip)
        installFromZIP
        ;;
    tbz)
        installFromTBZ
        ;;
    pkgInDmg)
        installPkgInDmg
        ;;
    pkgInZip)
        installPkgInZip
        ;;
    appInDmgInZip)
        installAppInDmgInZip
        ;;
    *)
        printlog "Cannot handle type $type"
        cleanupAndExit 99
        ;;
esac

# MARK: print installed application location and version
sleep 10 # wait a moment to let spotlight catch up
getAppVersion

if [[ -z $appversion ]]; then
    message="Installed $name"
else
    message="Installed $name, version $appversion"
fi

printlog "$message"

if [[ $currentUser != "loginwindow" && ( $NOTIFY == "success" || $NOTIFY == "all" ) ]]; then
    printlog "notifying"
    displaynotification "$message" "$name update/installation complete!"
fi

# all done!
cleanupAndExit 0
