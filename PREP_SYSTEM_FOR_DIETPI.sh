#!/bin/bash
{
	#------------------------------------------------------------------------------------------------
	# Optimise current Debian install and prepare for DietPi installation
	#------------------------------------------------------------------------------------------------
	# REQUIREMENTS
	# - Currently running Debian Buster or above, ideally minimal, eg: Raspbian Lite-ish =))
	# - systemd as system/init/service manager
	# - Either Ethernet connection or local (non-SSH) terminal access
	#------------------------------------------------------------------------------------------------
	# Dev notes:
	# Following items must be exported or assigned to DietPi scripts, if used, until dietpi-obtain_hw_model is executed:
	# - G_HW_MODEL
	# - G_HW_ARCH
	# - G_DISTRO
	# - G_DISTRO_NAME
	# - G_RASPBIAN
	#
	# The following environment variables can be set to automate this script (adjust example values to your needs):
	# - GITOWNER='MichaIng'			(optional, defaults to 'MichaIng')
	# - GITBRANCH='master'			(must be one of 'master', 'beta' or 'dev')
	# - IMAGE_CREATOR='Mr. Tux'
	# - PREIMAGE_INFO='Some GNU/Linux'
	# - HW_MODEL=0				(must match one of the supported IDs below)
	# - WIFI_REQUIRED=0			[01]
	# - DISTRO_TARGET=6			[567] (Buster: 5, Bullseye: 6, Bookworm: 7)
	#------------------------------------------------------------------------------------------------

	# Core globals
	G_PROGRAM_NAME='DietPi-PREP'

	#------------------------------------------------------------------------------------------------
	# Critical checks and requirements to run this script
	#------------------------------------------------------------------------------------------------
	# Exit path for non-root executions
	if (( $UID )); then

		echo -e '[FAILED] Root privileges required, please run this script with "sudo"\nIn case install the "sudo" package with root privileges:\n\t# apt install sudo\n'
		exit 1

	fi

	# Set locale
	# - Reset possibly conflicting environment for sub scripts
	> /etc/environment
	# - Apply override LC_ALL and default LANG for current script
	export LC_ALL='C.UTF-8' LANG='C.UTF-8'

	# Set $PATH variable to include all expected default binary locations, since we don't know the current system setup: https://github.com/MichaIng/DietPi/issues/3206
	export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

	# Make /tmp a tmpfs if it is not yet a dedicated mount
	if findmnt -M /tmp > /dev/null
	then
		(( $(findmnt -Ufnrbo SIZE -M /tmp) < 536870912 )) && mount -o remount,size=536870912 /tmp
	else
		mount -t tmpfs -o size=536870912 tmpfs /tmp
	fi

	# Work inside /tmp tmpfs to reduce disk I/O and speed up download and unpacking
	# - Save full script path beforehand: https://github.com/MichaIng/DietPi/pull/2341#discussion_r241784962
	FP_PREP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
	cd /tmp || exit 1

	# APT pre-configuration
	# - Remove unwanted APT configs
	#	RPi: Allow PDiffs since the "slow implementation" argument is outdated and PDiffs allow lower download size and less disk I/O
	[[ -f '/etc/apt/apt.conf.d/50raspi' ]] && rm -v /etc/apt/apt.conf.d/50raspi
	#	https://github.com/MichaIng/DietPi/issues/4083
	rm -fv /etc/apt/sources.list.d/vscode.list /etc/apt/trusted.gpg.d/microsoft.gpg /etc/apt/preferences.d/3rd_parties.pref
	#	Meveric: https://github.com/MichaIng/DietPi/issues/1285#issuecomment-355759321
	[[ -f '/etc/apt/sources.list.d/deb-multimedia.list' ]] && rm -v /etc/apt/sources.list.d/deb-multimedia.list
	[[ -f '/etc/apt/preferences.d/deb-multimedia-pin-99' ]] && rm -v /etc/apt/preferences.d/deb-multimedia-pin-99
	[[ -f '/etc/apt/preferences.d/backports' ]] && rm -v /etc/apt/preferences.d/backports
	#	OMV: https://dietpi.com/phpbb/viewtopic.php?t=2772
	[[ -f '/etc/apt/sources.list.d/openmediavault.list' ]] && rm -v /etc/apt/sources.list.d/openmediavault.list
	#	Conflicting configs
	rm -fv /etc/apt/apt.conf.d/*{recommends,armbian}*
	# - Apply wanted APT configs: Overwritten by DietPi code archive
	cat << '_EOF_' > /etc/apt/apt.conf.d/97dietpi # https://raw.githubusercontent.com/MichaIng/DietPi/dev/rootfs/etc/apt/apt.conf.d/97dietpi
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::AutoRemove::RecommendsImportant "false";
APT::AutoRemove::SuggestsImportant "false";
Acquire::Languages "none";
Dir::Cache::srcpkgcache "";
Acquire::GzipIndexes "true";
Acquire::IndexTargets::deb::Packages::KeepCompressedAs "xz";
Acquire::IndexTargets::deb::Translations::KeepCompressedAs "xz";
Acquire::IndexTargets::deb-src::Sources::KeepCompressedAs "xz";
_EOF_
	# - During PREP only: Force new DEB package config files and tmpfs lists + archives
	cat << '_EOF_' > /etc/apt/apt.conf.d/98dietpi-prep
#clear DPkg::options;
DPkg::options:: "--force-confmiss,confnew";
Dir::Cache "/tmp/apt";
Dir::Cache::archives "/tmp/apt/archives";
Dir::State "/tmp/apt";
Dir::State::extended_states "/var/lib/apt/extended_states";
Dir::State::status "/var/lib/dpkg/status";
Dir::Cache::pkgcache "";
_EOF_
	apt-get clean
	apt-get update

	# Check for/Install DEB packages required for this script to:
	aAPT_PREREQS=(

		'curl' # Download DietPi-Globals...
		'ca-certificates' # ...via HTTPS
		'whiptail' # G_WHIP

	)
	for i in "${aAPT_PREREQS[@]}"
	do
		dpkg-query -s "$i" &> /dev/null || apt-get -y install "$i" && continue
		echo -e "[FAILED] Unable to install $i, please try to install it manually:\n\t # apt install $i\n"
		exit 1
	done
	unset -v aAPT_PREREQS

	# Set Git owner
	GITOWNER=${GITOWNER:-MichaIng}

	# Select Git branch
	if ! [[ $GITBRANCH =~ ^(master|beta|dev)$ ]]; then

		aWHIP_BRANCH=(

			'master' ': Stable release branch (recommended)'
			'beta' ': Public beta testing branch'
			'dev' ': Unstable development branch'

		)
		if ! GITBRANCH=$(whiptail --title "$G_PROGRAM_NAME" --menu 'Please select the Git branch the installer should use:' --default-item 'master' --ok-button 'Ok' --cancel-button 'Exit' --backtitle "$G_PROGRAM_NAME" 12 80 3 "${aWHIP_BRANCH[@]}" 3>&1 1>&2 2>&3-); then

			echo -e '[ INFO ] Exit selected. Aborting...\n'
			exit 0

		fi
		unset -v aWHIP_BRANCH

	fi
	echo "[ INFO ] Selected Git branch: $GITOWNER/$GITBRANCH"

	#------------------------------------------------------------------------------------------------
	# DietPi-Globals
	#------------------------------------------------------------------------------------------------
	# NB: We have to manually handle errors, until DietPi-Globals are successfully loaded.
	# Download
	if ! curl -sSfL "https://raw.githubusercontent.com/$GITOWNER/DietPi/$GITBRANCH/dietpi/func/dietpi-globals" -o dietpi-globals; then

		echo -e '[FAILED] Unable to download dietpi-globals. Aborting...\n'
		exit 1

	fi

	# Assure no obsolete .hw_model is loaded
	rm -fv /boot/dietpi/.hw_model

	# Load
	if ! . ./dietpi-globals; then

		echo -e '[FAILED] Unable to load dietpi-globals. Aborting...\n'
		exit 1

	fi
	rm dietpi-globals

	# Reset G_PROGRAM_NAME, which was set to empty string by sourcing dietpi-globals
	readonly G_PROGRAM_NAME='DietPi-PREP'
	G_INIT

	# Apply Git info
	G_GITOWNER=$GITOWNER
	G_GITBRANCH=$GITBRANCH
	unset -v GITOWNER GITBRANCH

	# Detect the distro version of this operating system
	distro=$(</etc/debian_version)
	if [[ $distro == '10.'* || $distro == 'buster/sid' ]]; then

		G_DISTRO=5
		G_DISTRO_NAME='buster'

	elif [[ $distro == '11.'* || $distro == 'bullseye/sid' ]]; then

		G_DISTRO=6
		G_DISTRO_NAME='bullseye'

	elif [[ $distro == '12.'* || $distro == 'bookworm/sid' ]]; then

		G_DISTRO=7
		G_DISTRO_NAME='bookworm'

	else

		G_DIETPI-NOTIFY 1 "Unsupported distribution version: \"$distro\". Aborting...\n"
		exit 1

	fi
	unset -v distro
	G_DIETPI-NOTIFY 2 "Detected distribution version: ${G_DISTRO_NAME^} (ID: $G_DISTRO)"

	# Detect the hardware architecture of this operating system
	if grep -q '^ID=raspbian' /etc/os-release; then

		# Raspbian: Force ARMv6
		G_RASPBIAN=1 G_HW_ARCH=1 G_HW_ARCH_NAME='armv6l'

	else

		# Debian: ARMv6 is not supported here
		G_RASPBIAN=0
		G_HW_ARCH_NAME=$(uname -m)
		if [[ $G_HW_ARCH_NAME == 'armv7l' ]]; then

			G_HW_ARCH=2

		elif [[ $G_HW_ARCH_NAME == 'aarch64' ]]; then

			G_HW_ARCH=3

		elif [[ $G_HW_ARCH_NAME == 'x86_64' ]]; then

			G_HW_ARCH=10

		else

			G_DIETPI-NOTIFY 1 "Unsupported CPU architecture: \"$G_HW_ARCH_NAME\". Aborting...\n"
			exit 1

		fi

	fi
	G_DIETPI-NOTIFY 2 "Detected target CPU architecture: $G_HW_ARCH_NAME (ID: $G_HW_ARCH)"

	Main(){

		#------------------------------------------------------------------------------------------------
		# Init setup step headers
		SETUP_STEP=0
		readonly G_NOTIFY_3_MODE='Step'
		G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" "[$SETUP_STEP] Detecting existing DietPi system"; ((SETUP_STEP++))
		#------------------------------------------------------------------------------------------------
		if [[ -d '/DietPi' || -d '/boot/dietpi' ]]; then

			G_DIETPI-NOTIFY 2 'DietPi system found, uninstalling old instance...'

			# Stop services
			[[ -f '/boot/dietpi/dietpi-services' ]] && /boot/dietpi/dietpi-services stop
			[[ -f '/etc/systemd/system/dietpi-ramlog.service' ]] && systemctl stop dietpi-ramlog
			[[ -f '/etc/systemd/system/dietpi-ramdisk.service' ]] && systemctl stop dietpi-ramdisk # Includes (Pre|Post)Boot on pre-v6.29 systems
			[[ -f '/etc/systemd/system/dietpi-preboot.service' ]] && systemctl stop dietpi-preboot # Includes (Pre|Post)Boot on post-v6.28 systems

			# Disable DietPi services
			for i in /etc/systemd/system/dietpi-*
			do
				[[ -f $i ]] && systemctl disable --now "${i##*/}"
				rm -Rfv "$i"
			done

			# Delete any previous existing data
			# - Pre-v6.29: /DietPi mount point
			findmnt /DietPi > /dev/null && umount -R /DietPi
			[[ -d '/DietPi' ]] && rm -R /DietPi
			rm -Rfv /{boot,mnt,etc,var/lib,var/tmp,run}/*dietpi*
			rm -fv /etc{,/cron.*,/{bashrc,profile,sysctl,network/if-up,udev/rules}.d}/{,.}*dietpi*
			rm -fv /etc/apt/apt.conf.d/{99-dietpi-norecommends,98-dietpi-no_translations,99-dietpi-forceconf} # Pre-v6.32
			[[ -f '/boot/Automation_Format_My_Usb_Drive' ]] && rm -v /boot/Automation_Format_My_Usb_Drive

		else

			G_DIETPI-NOTIFY 2 'No DietPi system found, skipping old instance uninstall...'

		fi

		#------------------------------------------------------------------------------------------------
		G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" "[$SETUP_STEP] Target system inputs"; ((SETUP_STEP++))
		#------------------------------------------------------------------------------------------------

		# Image creator
		while :
		do
			if [[ $IMAGE_CREATOR ]]; then

				G_WHIP_RETURNED_VALUE=$IMAGE_CREATOR
				# unset to force interactive input if disallowed name is detected
				unset -v IMAGE_CREATOR

			else

				G_WHIP_BUTTON_CANCEL_TEXT='Exit'
				if ! G_WHIP_INPUTBOX 'Please enter your name. This will be used to identify the image creator within credits banner.\n\nYou can add your contact information as well for end users.\n\nNB: An entry is required.'; then

					G_DIETPI-NOTIFY 1 'Exit selected. Aborting...\n'
					exit 0

				fi

			fi

			# Disallowed names
			aDISALLOWED_NAMES=(

				'official'
				'fourdee'
				'daniel knight'
				'dan knight'
				'michaing'
				'diet'

			)

			for i in "${aDISALLOWED_NAMES[@]}"
			do
				[[ ${G_WHIP_RETURNED_VALUE,,} =~ $i ]] || continue
				G_WHIP_MSG "\"$G_WHIP_RETURNED_VALUE\" is reserved and cannot be used. Please try again."
				continue 2
			done
			unset -v aDISALLOWED_NAMES

			IMAGE_CREATOR=$G_WHIP_RETURNED_VALUE
			break

		done
		G_DIETPI-NOTIFY 2 "Entered image creator: $IMAGE_CREATOR"

		# Pre-image used/name: Respect environment variable
		if [[ ! $PREIMAGE_INFO ]]; then

			G_WHIP_BUTTON_CANCEL_TEXT='Exit'
			if ! G_WHIP_INPUTBOX 'Please enter the name or URL of the pre-image you installed on this system, prior to running this script. This will be used to identify the pre-image credits.\n\nEG: Debian, Raspberry Pi OS Lite, Meveric or "forum.odroid.com/viewtopic.php?t=123456" etc.\n\nNB: An entry is required.'; then

				G_DIETPI-NOTIFY 1 'Exit selected. Aborting...\n'
				exit 0

			fi
			PREIMAGE_INFO=$G_WHIP_RETURNED_VALUE

		fi
		G_DIETPI-NOTIFY 2 "Entered pre-image info: $PREIMAGE_INFO"

		# Hardware selection
		# - NB: PLEASE ENSURE HW_MODEL INDEX ENTRIES MATCH dietpi-obtain_hw_model and dietpi-survey_report
		# - NBB: DO NOT REORDER INDICES. These are now fixed and will never change (due to survey results etc)
		G_WHIP_BUTTON_CANCEL_TEXT='Exit'
		G_WHIP_DEFAULT_ITEM=0
		G_WHIP_MENU_ARRAY=(

			'' '●─ ARM '
			'0' ': Raspberry Pi (all models)'
			#'0' ': Raspberry Pi 1 (256 MiB)
			#'1' ': Raspberry Pi 1/Zero (512 MiB)'
			#'2' ': Raspberry Pi 2'
			#'3' ': Raspberry Pi 3/3+'
			#'4' ': Raspberry Pi 4'
			'13' ': Odroid U3'
			'10' ': Odroid C1'
			'11' ': Odroid XU3/XU4/MC1/HC1/HC2'
			'12' ': Odroid C2'
			'15' ': Odroid N2'
			'16' ': Odroid C4/HC4'
			'70' ': Sparky SBC'
			'52' ': ASUS Tinker Board'
			'40' ': PINE A64'
			'45' ': PINE H64'
			'43' ': ROCK64'
			'42' ': ROCKPro64'
			'44' ': Pinebook'
			'46' ': Pinebook Pro'
			'59' ': ZeroPi'
			'60' ': NanoPi NEO'
			'65' ': NanoPi NEO2'
			'56' ': NanoPi NEO3'
			'57' ': NanoPi NEO Plus2'
			'64' ': NanoPi NEO Air'
			'63' ': NanoPi M1/T1'
			'66' ': NanoPi M1 Plus'
			'61' ': NanoPi M2/T2'
			'62' ': NanoPi M3/T3/Fire3'
			'68' ': NanoPi M4/T4/NEO4'
			'58' ': NanoPi M4V2'
			'67' ': NanoPi K1 Plus'
			'54' ': NanoPi K2'
			'48' ': NanoPi R1'
			'55' ': NanoPi R2S'
			'47' ': NanoPi R4S'
			'72' ': ROCK Pi 4'
			'73' ': ROCK Pi S'
			'74' ': Radxa Zero'
			'' '●─ x86_64 '
			'21' ': x86_64 Native PC'
			'20' ': x86_64 Virtual Machine'
			'' '●─ Other '
			'29' ': Generic Amlogic S922X'
			'28' ': Generic Amlogic S905'
			'27' ': Generic Allwinner H6'
			'26' ': Generic Allwinner H5'
			'25' ': Generic Allwinner H3'
			'24' ': Generic Rockchip RK3399'
			'23' ': Generic Rockchip RK3328'
			'22' ': Generic Device'

		)

		while :
		do
			# Check for valid environment variabe
			[[ $HW_MODEL =~ ^[0-9]+$ ]] && for i in "${G_WHIP_MENU_ARRAY[@]}"
			do
				[[ $HW_MODEL == "$i" ]] && break 2
			done

			G_WHIP_BUTTON_CANCEL_TEXT='Exit'
			if ! G_WHIP_MENU 'Please select the current device this is being installed on:\n - NB: Select "Generic device" if not listed.\n - "Core devices": Fully supported by DietPi, offering full GPU acceleration + Kodi support.\n - "Limited support devices": No GPU acceleration guaranteed.'; then

				G_DIETPI-NOTIFY 0 'Exit selected. Aborting...\n'
				exit 0

			fi
			HW_MODEL=$G_WHIP_RETURNED_VALUE
			break
		done
		G_HW_MODEL=$HW_MODEL
		unset -v HW_MODEL

		G_DIETPI-NOTIFY 2 "Selected hardware model ID: $G_HW_MODEL"

		# WiFi selection
		if [[ $WIFI_REQUIRED != [01] ]]; then

			G_WHIP_MENU_ARRAY=(

				'0' ': I do not require WiFi functionality, skip related package install.'
				'1' ': I require WiFi functionality, install related packages.'

			)

			(( $G_HW_MODEL == 20 )) && G_WHIP_DEFAULT_ITEM=0 || G_WHIP_DEFAULT_ITEM=1
			G_WHIP_BUTTON_CANCEL_TEXT='Exit'
			if G_WHIP_MENU 'Please select an option:'; then

				WIFI_REQUIRED=$G_WHIP_RETURNED_VALUE

			else

				G_DIETPI-NOTIFY 0 'Exit selected. Aborting...\n'
				exit 0

			fi

		fi
		# shellcheck disable=SC2015
		(( $WIFI_REQUIRED )) && G_DIETPI-NOTIFY 2 'Marking WiFi as required' || G_DIETPI-NOTIFY 2 'Marking WiFi as NOT required'

		# Distro selection
		DISTRO_LIST_ARRAY=(

			'5' ': Buster (oldstable, if you must stay with an old release)'
			'6' ': Bullseye (current stable release, recommended)'
			'7' ': Bookworm (testing, if you want to live on bleeding edge)'

		)

		# - List supported distro versions up from currently installed one
		G_WHIP_MENU_ARRAY=()
		for ((i=0; i<${#DISTRO_LIST_ARRAY[@]}; i+=2))
		do
			(( ${DISTRO_LIST_ARRAY[$i]} < $G_DISTRO )) || G_WHIP_MENU_ARRAY+=("${DISTRO_LIST_ARRAY[$i]}" "${DISTRO_LIST_ARRAY[$i+1]}")
		done
		unset -v DISTRO_LIST_ARRAY

		while :
		do
			[[ $DISTRO_TARGET =~ ^[0-9]+$ ]] && for i in "${G_WHIP_MENU_ARRAY[@]}"
			do
				[[ $DISTRO_TARGET == "$i" ]] && break 2
			done

			G_WHIP_DEFAULT_ITEM=${G_WHIP_MENU_ARRAY[0]} # First item matches current distro version
			G_WHIP_BUTTON_CANCEL_TEXT='Exit'
			if G_WHIP_MENU "Please select a Debian version to install on this system.\n
Currently installed: $G_DISTRO_NAME (ID: $G_DISTRO)"; then

				DISTRO_TARGET=$G_WHIP_RETURNED_VALUE
				break

			fi
			G_DIETPI-NOTIFY 0 'Exit selected. Aborting...\n'
			exit 0
		done

		if (( $DISTRO_TARGET == 5 )); then

			DISTRO_TARGET_NAME='buster'

		elif (( $DISTRO_TARGET == 6 )); then

			DISTRO_TARGET_NAME='bullseye'

		else

			DISTRO_TARGET_NAME='bookworm'

		fi

		G_DIETPI-NOTIFY 2 "Selected Debian version: $DISTRO_TARGET_NAME (ID: $DISTRO_TARGET)"

		#------------------------------------------------------------------------------------------------
		G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" "[$SETUP_STEP] Downloading and installing DietPi source code"; ((SETUP_STEP++))
		#------------------------------------------------------------------------------------------------

		local url="https://github.com/$G_GITOWNER/DietPi/archive/$G_GITBRANCH.tar.gz"
		G_CHECK_URL_TIMEOUT=10 G_CHECK_URL_ATTEMPTS=2 G_CHECK_URL "$url"
		G_EXEC_DESC='Downloading DietPi sourcecode' G_EXEC curl -sSfL "$url" -o package.tar.gz

		[[ -d DietPi-$G_GITBRANCH ]] && G_EXEC_DESC='Cleaning previously extracted files' G_EXEC rm -R "DietPi-$G_GITBRANCH"
		G_EXEC_DESC='Extracting DietPi sourcecode' G_EXEC tar xf package.tar.gz
		rm package.tar.gz

		[[ -d '/boot' ]] || G_EXEC_DESC='Creating /boot' G_EXEC mkdir /boot

		G_DIETPI-NOTIFY 2 'Moving kernel and boot configuration to /boot'

		# HW specific config.txt, boot.ini uEnv.txt
		if (( $G_HW_MODEL < 10 )); then

			echo "root=PARTUUID=$(findmnt -Ufnro PARTUUID -M /) rootfstype=ext4 rootwait fsck.repair=yes net.ifnames=0 logo.nologo quiet console=serial0,115200 console=tty1" > /boot/cmdline.txt
			G_EXEC mv "DietPi-$G_GITBRANCH/config.txt" /boot/
			# Boot in 64-bit mode if this is a 64-bit image
			[[ $G_HW_ARCH == 3 ]] && G_CONFIG_INJECT 'arm_64bit=' 'arm_64bit=1' /boot/config.txt

		elif (( $G_HW_MODEL == 11 )); then

			G_EXEC mv "DietPi-$G_GITBRANCH/boot_xu4.ini" /boot/boot.ini
			G_EXEC sed -i "s/root=UUID=[^[:blank:]]*/root=UUID=$(findmnt -Ufnro UUID -M /)/" /boot/boot.ini

		elif [[ $G_HW_MODEL == 12 && -f '/boot/boot.ini' ]]; then

			G_EXEC mv "DietPi-$G_GITBRANCH/boot_c2.ini" /boot/boot.ini

		elif [[ $G_HW_MODEL == 15 && -f '/boot/boot.ini' ]]; then

			G_EXEC mv "DietPi-$G_GITBRANCH/boot_n2.ini" /boot/boot.ini
			G_EXEC sed -i "s/root=UUID=[^[:blank:]]*/root=UUID=$(findmnt -Ufnro UUID -M /)/" /boot/boot.ini

		fi

		G_EXEC mv "DietPi-$G_GITBRANCH/dietpi.txt" /boot/
		G_EXEC mv "DietPi-$G_GITBRANCH/README.md" /boot/dietpi-README.md
		G_EXEC mv "DietPi-$G_GITBRANCH/LICENSE" /boot/dietpi-LICENSE.txt

		# Reading version string for later use
		. "DietPi-$G_GITBRANCH/.update/version"
		G_DIETPI_VERSION_CORE=$G_REMOTE_VERSION_CORE
		G_DIETPI_VERSION_SUB=$G_REMOTE_VERSION_SUB
		G_DIETPI_VERSION_RC=$G_REMOTE_VERSION_RC

		# Remove server_version-6 / (pre-)patch_file (downloads fresh from dietpi-update)
		rm "DietPi-$G_GITBRANCH/dietpi/server_version-6"
		rm "DietPi-$G_GITBRANCH/dietpi/pre-patch_file"
		rm "DietPi-$G_GITBRANCH/dietpi/patch_file"

		G_EXEC_DESC='Copy DietPi scripts to /boot/dietpi' G_EXEC cp -Rf "DietPi-$G_GITBRANCH/dietpi" /boot/
		G_EXEC_DESC='Copy DietPi system files in place' G_EXEC cp -Rf "DietPi-$G_GITBRANCH/rootfs"/. /
		G_EXEC_DESC='Clean download location' G_EXEC rm -R "DietPi-$G_GITBRANCH"
		G_EXEC_DESC='Set execute permissions for DietPi scripts' G_EXEC chmod -R +x /boot/dietpi /var/lib/dietpi/services /etc/cron.*/dietpi

		G_DIETPI-NOTIFY 2 'Storing DietPi version info:'
		G_CONFIG_INJECT 'DEV_GITBRANCH=' "DEV_GITBRANCH=$G_GITBRANCH" /boot/dietpi.txt
		G_CONFIG_INJECT 'DEV_GITOWNER=' "DEV_GITOWNER=$G_GITOWNER" /boot/dietpi.txt
		G_VERSIONDB_SAVE

		# Apply live patches
		G_DIETPI-NOTIFY 2 'Applying DietPi live patches to fix known bugs in this version'
		for i in "${!G_LIVE_PATCH[@]}"
		do
			if eval "${G_LIVE_PATCH_COND[$i]}"
			then
				G_DIETPI-NOTIFY 2 "Applying live patch $i"
				eval "${G_LIVE_PATCH[$i]}"
				G_LIVE_PATCH_STATUS[$i]='applied'
			else
				G_LIVE_PATCH_STATUS[$i]='not applicable'
			fi

			# Store new status of live patch to /boot/dietpi/.version
			G_CONFIG_INJECT "G_LIVE_PATCH_STATUS\[$i\]=" "G_LIVE_PATCH_STATUS[$i]='${G_LIVE_PATCH_STATUS[$i]}'" /boot/dietpi/.version
		done

		G_EXEC cp /boot/dietpi/.version /var/lib/dietpi/.dietpi_image_version

		G_EXEC systemctl daemon-reload

		#------------------------------------------------------------------------------------------------
		G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" "[$SETUP_STEP] APT configuration"; ((SETUP_STEP++))
		#------------------------------------------------------------------------------------------------

		G_DIETPI-NOTIFY 2 "Setting APT sources.list: $DISTRO_TARGET_NAME $DISTRO_TARGET"

		# We need to forward $DISTRO_TARGET* to dietpi-set_software, as well as $G_HW_MODEL + $G_RASPBIAN for Debian vs Raspbian decision.
		G_DISTRO=$DISTRO_TARGET G_DISTRO_NAME=$DISTRO_TARGET_NAME G_HW_MODEL=$G_HW_MODEL G_RASPBIAN=$G_RASPBIAN G_EXEC /boot/dietpi/func/dietpi-set_software apt-mirror default

		# Meveric: Update repo to use our own mirror: https://github.com/MichaIng/DietPi/issues/1519#issuecomment-368234302
		sed -Ei 's|https?://oph\.mdrjr\.net|https://dietpi.com|' /etc/apt/sources.list.d/meveric*.list &> /dev/null

		# (Re)create DietPi runtime and logs dir, used by G_AGx
		G_EXEC mkdir -p /run/dietpi /var/tmp/dietpi/logs

		G_AGUP

		# @MichaIng https://github.com/MichaIng/DietPi/pull/1266/files
		G_DIETPI-NOTIFY 2 'Marking all packages as auto-installed first, to allow effective autoremove afterwards'
		local apackages
		mapfile -t apackages < <(apt-mark showmanual)
		[[ ${apackages[0]} ]] && G_EXEC apt-mark auto "${apackages[@]}"
		unset -v apackages

		# DietPi list of minimal required packages, which must be installed:
		aPACKAGES_REQUIRED_INSTALL=(

			'apt'			# Debian package manager
			'bash-completion'	# Auto completes a wide list of bash commands and options via <tab>
			'bzip2'			# (.tar).bz2 archiver
			'ca-certificates'	# Adds known ca-certificates, necessary to practically access HTTPS sources
			'console-setup'		# DietPi-Config keyboard configuration + console fonts
			'cron'			# Background job scheduler
			'curl'			# Web address testing, downloading, uploading etc.
			'ethtool'		# Force Ethernet link speed
			'fake-hwclock'		# Hardware clock emulation, to allow correct timestamps during boot before network time sync
			'fdisk'			# Partitioning tool used by DietPi-FS_partition_resize and DietPi-Imager
			'gnupg'			# apt-key add / gpg
			'htop'			# System monitor
			'ifupdown'		# Network interface configuration
			'iputils-ping'		# "ping" command
			'isc-dhcp-client'	# DHCP client
			'kmod'			# "modprobe", "lsmod", used by several DietPi scripts
			'locales'		# Support locales, used by dietpi-config > Language/Regional Options > Locale
			'nano'			# Simple text editor
			'p7zip'			# .7z archiver
			'parted'		# partprobe + drive partitioning, used by DietPi-Drive_Manager
			'procps'		# "kill", "ps", "pgrep", "sysctl", used by several DietPi scripts
			'psmisc'		# "killall", used by several DietPi scripts
			'rfkill' 		# Block/unblock WiFi and Bluetooth adapters, only installed once to unblock everything, purged afterwards!
			'sudo'			# Root permission wrapper for users permitted via /etc/sudoers(.d/)
			'systemd-sysv'		# Includes systemd and additional commands: "poweroff", "shutdown" etc.
			'tzdata'		# Time zone data for system clock, auto summer/winter time adjustment
			'udev'			# /dev/ and hotplug management daemon
			'unzip'			# .zip unpacker
			'usbutils'		# "lsusb", used by DietPi-Software + DietPi-Bugreport
			'wget'			# Download tool
			'whiptail'		# DietPi dialogs
			#'xz-utils'		# (.tar).xz archiver

		)

		# G_DISTRO specific
		# - Dropbear: DietPi default SSH-Client
		#   On Buster-, "dropbear" pulls in "dropbear-initramfs", which we don't need: https://packages.debian.org/dropbear
		# - apt-transport-https: Allows HTTPS sources for ATP
		#   On Buster+, it is included in "apt" package: https://packages.debian.org/apt-transport-https
		if (( $G_DISTRO > 5 )); then

			aPACKAGES_REQUIRED_INSTALL+=('dropbear')

		else

			aPACKAGES_REQUIRED_INSTALL+=('dropbear-run')

		fi
		# - systemd-timesyncd: Network time sync daemon
		#   Available as dedicated package since Bullseye: https://packages.debian.org/systemd-timesyncd
		#   While the above needs to be checked against "current" distro to not break SSH or APT before distro upgrade, this one should be checked against "target" distro version.
		(( $DISTRO_TARGET > 5 )) && aPACKAGES_REQUIRED_INSTALL+=('systemd-timesyncd')

		# G_HW_MODEL specific
		# - initramfs: Required for generic bootloader, but not required/used by RPi bootloader, on VM install tiny-initramfs with limited features but sufficient and much smaller + faster
		if (( $G_HW_MODEL == 20 )); then

			aPACKAGES_REQUIRED_INSTALL+=('tiny-initramfs')

		elif (( $G_HW_MODEL > 9 )); then

			aPACKAGES_REQUIRED_INSTALL+=('initramfs-tools')

		fi
		# - Entropy daemon: Use modern rng-tools5 on all devices where it has been proven to work, else haveged: https://github.com/MichaIng/DietPi/issues/2806
		if [[ $G_HW_MODEL -lt 10 || $G_HW_MODEL =~ ^(14|15|16|24|29|42|46|58|68|72|74)$ ]]; then # RPi, S922X, Odroid C4, RK3399 - 47 NanoPi R4S, Radxa Zero

			aPACKAGES_REQUIRED_INSTALL+=('rng-tools5')

		else

			aPACKAGES_REQUIRED_INSTALL+=('haveged')

		fi
		# - Drive power management control
		(( $G_HW_MODEL == 20 )) || aPACKAGES_REQUIRED_INSTALL+=('hdparm')

		# WiFi related
		if (( $WIFI_REQUIRED )); then

			aPACKAGES_REQUIRED_INSTALL+=('iw')			# Tools to configure WiFi adapters
			aPACKAGES_REQUIRED_INSTALL+=('wireless-tools')		# Same as "iw", deprecated but still required for non-nl80211 adapters
			aPACKAGES_REQUIRED_INSTALL+=('crda')			# Set WiFi frequencies according to local regulations, based on WiFi country code
			aPACKAGES_REQUIRED_INSTALL+=('wpasupplicant')		# Support for WPA-protected WiFi network connection

		fi

		# Install gdisk if root file system is on a GPT partition, used by DietPi-FS_partition_resize
		[[ $(blkid -s PTTYPE -o value -c /dev/null "$(lsblk -npo PKNAME "$(findmnt -Ufnro SOURCE -M /)")") == 'gpt' ]] && aPACKAGES_REQUIRED_INSTALL+=('gdisk')

		# Install file system tools required for file system resizing and fsck
		local ae2fsprogs=('--allow-remove-essential' 'e2fsprogs')
		while read -r line
		do
			if [[ $line == 'ext'[2-4] ]]
			then
				aPACKAGES_REQUIRED_INSTALL+=('e2fsprogs')
				ae2fsprogs=()

			elif [[ $line == 'vfat' ]]
			then
				aPACKAGES_REQUIRED_INSTALL+=('dosfstools')

			elif [[ $line == 'f2fs' ]]
			then
				aPACKAGES_REQUIRED_INSTALL+=('f2fs-tools')

			elif [[ $line == 'btrfs' ]]
			then
				aPACKAGES_REQUIRED_INSTALL+=('btrfs-progs')
			fi

		done < <(blkid -s TYPE -o value -c /dev/null | sort -u)

		# Kernel/bootloader/firmware
		# - We need to install those directly to allow G_AGA() autoremove possible older packages later: https://github.com/MichaIng/DietPi/issues/1285#issuecomment-354602594
		# - Assure that dir for additional sources is present
		[[ -d '/etc/apt/sources.list.d' ]] || G_EXEC mkdir /etc/apt/sources.list.d
		# - G_HW_ARCH specific
		#	x86_64
		if (( $G_HW_ARCH == 10 )); then

			local apackages=('linux-image-amd64' 'os-prober')

			# As linux-image-amd64 pulls initramfs already, pre-install the intended implementation here already
			(( $G_HW_MODEL == 20 )) && apackages+=('tiny-initramfs') || apackages+=('initramfs-tools')

			# Grub EFI with secure boot compatibility
			if [[ -d '/boot/efi' ]] || dpkg-query -s 'grub-efi-amd64' &> /dev/null; then

				apackages+=('grub-efi-amd64' 'grub-efi-amd64-signed' 'shim-signed')

			# Grub BIOS
			else

				apackages+=('grub-pc')

			fi

			# Skip creating kernel symlinks and remove existing ones
			echo 'do_symlinks=0' > /etc/kernel-img.conf
			G_EXEC rm -f /{,boot/}{initrd.img,vmlinuz}{,.old}

			# If /boot is on a FAT partition, create a kernel upgrade hook script to remove existing files first: https://github.com/MichaIng/DietPi/issues/4788
			if [[ $(findmnt -Ufnro FSTYPE -M /boot) == 'vfat' ]]
			then
				G_EXEC mkdir -p /etc/kernel/preinst.d
				cat << '_EOF_' > /etc/kernel/preinst.d/dietpi
#!/bin/sh -e
# Remove old kernel files if existing: https://github.com/MichaIng/DietPi/issues/4788
{
# Fail if the package name was not passed, which is done when being invoked by dpkg
if [ -z "$DPKG_MAINTSCRIPT_PACKAGE" ]
then
        echo 'DPKG_MAINTSCRIPT_PACKAGE was not set, this script must be invoked by dpkg.'
        exit 1
fi

# Loop through files in /boot, shipped by the package, and remove them, if existing
for file in $(dpkg -L "$DPKG_MAINTSCRIPT_PACKAGE" | grep '^/boot/')
do
        [ ! -f "$file" ] || rm "$file"
done
}
_EOF_
				G_EXEC chmod +x /etc/kernel/preinst.d/dietpi
			fi

			G_AGI "${apackages[@]}"
			unset -v apackages

			# Remove obsolete combined keyring
			[[ -f '/etc/apt/trusted.gpg' ]] && G_EXEC rm /etc/apt/trusted.gpg
			[[ -f '/etc/apt/trusted.gpg~' ]] && G_EXEC rm '/etc/apt/trusted.gpg~'

		# - G_HW_MODEL specific required firmware/kernel/bootloader packages
		#	Armbian grab currently installed packages
		elif [[ $(dpkg-query -Wf '${Package} ') == *'armbian'* ]]; then

			systemctl stop armbian-*

			local apackages=(

				'linux-image-'
				'linux-dtb-'
				'linux-u-boot-'

			)

			for i in "${apackages[@]}"
			do
				while read -r line
				do
					aPACKAGES_REQUIRED_INSTALL+=("$line")
					G_DIETPI-NOTIFY 2 "Armbian package detected and added: $line"

				done < <(dpkg-query -Wf '${Package}\n' | mawk -v pat="^$i" '$0~pat')
			done
			unset -v apackages

			# Add u-boot-tools, required to convert initramfs images into u-boot format
			aPACKAGES_REQUIRED_INSTALL+=('u-boot-tools')

			# Generate and cleanup uInitrd
			local arch='arm'
			(( $G_HW_ARCH == 3 )) && arch='arm64'
			G_EXEC mkdir -p /etc/initramfs/post-update.d
			cat << _EOF_ > /etc/initramfs/post-update.d/99-dietpi-uboot
#!/bin/dash
echo 'update-initramfs: Converting to U-Boot format' >&2
mkimage -A $arch -O linux -T ramdisk -C gzip -n uInitrd -d \$2 /boot/uInitrd-\$1 > /dev/null
ln -sf uInitrd-\$1 /boot/uInitrd > /dev/null 2>&1 || mv /boot/uInitrd-\$1 /boot/uInitrd
exit 0
_EOF_
			G_EXEC chmod +x /etc/initramfs/post-update.d/99-dietpi-uboot
			G_EXEC mkdir -p /etc/kernel/preinst.d
			cat << '_EOF_' > /etc/kernel/preinst.d/dietpi-initramfs_cleanup
#!/bin/dash

# skip if initramfs-tools is not installed
[ -x /usr/sbin/update-initramfs ] || exit 0

# passing the kernel version is required
version="$1"
if [ -z "$version" ]; then
        echo "W: initramfs-tools: ${DPKG_MAINTSCRIPT_PACKAGE:-kernel package} did not pass a version number" >&2
        exit 0
fi

# avoid running multiple times
if [ -n "$DEB_MAINT_PARAMS" ]; then
        eval set -- "$DEB_MAINT_PARAMS"
        if [ "$1" != 'upgrade' ]; then
                exit 0
        fi
fi

_EOF_
			# Bullseye: initramfs-tools' /var/lib/initramfs-tools state directory is not used anymore
			if (( $DISTRO_TARGET > 5 ))
			then
				cat << '_EOF_' >> /etc/kernel/preinst.d/dietpi-initramfs_cleanup
# delete unused initrd images
find /boot -name 'initrd.img-*' -o -name 'uInitrd-*' ! -name "*-$version" -printf 'Removing obsolete file %f\n' -delete

exit 0
_EOF_
			else
				cat << '_EOF_' >> /etc/kernel/preinst.d/dietpi-initramfs_cleanup
# loop through existing initramfs images
for v in $(ls -1 /var/lib/initramfs-tools | linux-version sort --reverse); do
        if ! linux-version compare $v eq $version; then
                # try to delete delete old initrd images via update-initramfs
                INITRAMFS_TOOLS_KERNEL_HOOK=y update-initramfs -d -k $v 2>/dev/null
                # delete unused state files
                find /var/lib/initramfs-tools -type f ! -name "$version" -printf 'Removing obsolete file %f\n' -delete
                # delete unused initrd images
                find /boot -name 'initrd.img-*' -o -name 'uInitrd-*' ! -name "*-$version" -printf 'Removing obsolete file %f\n' -delete
        fi
done

exit 0
_EOF_
			fi
			G_EXEC chmod +x /etc/kernel/preinst.d/dietpi-initramfs_cleanup

			# Remove obsolete components from Armbian list and connect via HTTPS
			G_EXEC eval "echo 'deb http://apt.armbian.com/ ${DISTRO_TARGET_NAME/bookworm/bullseye} main' > /etc/apt/sources.list.d/armbian.list"

			# Exclude doubled device tree files, shipped with the kernel package
			echo 'path-exclude /usr/lib/linux-image-current-*' > /etc/dpkg/dpkg.cfg.d/01-dietpi-exclude_doubled_devicetrees
			G_EXEC rm -Rf /usr/lib/linux-image-current-*

		#	RPi
		elif (( $G_HW_MODEL < 10 )); then

			# ARMv6/7: Add raspi-copies-and-fills
			local a32bit=()
			[[ $G_HW_ARCH == 3 ]] || a32bit=('raspi-copies-and-fills')
			G_AGI raspberrypi-bootloader raspberrypi-kernel libraspberrypi0 libraspberrypi-bin raspberrypi-sys-mods raspberrypi-archive-keyring "${a32bit[@]}"

			# https://github.com/RPi-Distro/raspberrypi-sys-mods/pull/60
			[[ -f '/etc/apt/trusted.gpg.d/microsoft.gpg' ]] && G_EXEC rm /etc/apt/trusted.gpg.d/microsoft.gpg
			[[ -f '/etc/apt/sources.list.d/vscode.list' ]] && G_EXEC rm /etc/apt/sources.list.d/vscode.list

			# Move Raspbian key to active place and remove obsolete combined keyring
			[[ -f '/usr/share/keyrings/raspbian-archive-keyring.gpg' ]] && G_EXEC ln -sf /usr/share/keyrings/raspbian-archive-keyring.gpg /etc/apt/trusted.gpg.d/raspbian-archive-keyring.gpg
			[[ -f '/etc/apt/trusted.gpg' ]] && G_EXEC rm /etc/apt/trusted.gpg
			[[ -f '/etc/apt/trusted.gpg~' ]] && G_EXEC rm '/etc/apt/trusted.gpg~'

		#	Odroid C4
		elif (( $G_HW_MODEL == 16 )); then

			G_AGI linux-image-arm64-odroid-c4 meveric-keyring u-boot # On C4, the kernel package does not depend on the U-Boot package

			# Apply kernel postinst steps manually, that depend on /proc/cpuinfo content, not matching when running in a container.
			[[ -f '/boot/Image' ]] && G_EXEC mv /boot/Image /boot/Image.gz
			[[ -f '/boot/Image.gz.bak' ]] && G_EXEC rm /boot/Image.gz.bak

			# Remove obsolete combined keyring
			[[ -f '/etc/apt/trusted.gpg' ]] && G_EXEC rm /etc/apt/trusted.gpg
			[[ -f '/etc/apt/trusted.gpg~' ]] && G_EXEC rm '/etc/apt/trusted.gpg~'

		#	Odroid N2
		elif (( $G_HW_MODEL == 15 )); then

			G_AGI linux-image-arm64-odroid-n2 meveric-keyring
			# Apply kernel postinst steps manually, that depend on /proc/cpuinfo content, not matching when running in a container.
			[[ -f '/boot/Image' ]] && G_EXEC mv /boot/Image /boot/Image.gz
			[[ -f '/boot/Image.gz.bak' ]] && G_EXEC rm /boot/Image.gz.bak

			# Remove obsolete combined keyring
			[[ -f '/etc/apt/trusted.gpg' ]] && G_EXEC rm /etc/apt/trusted.gpg
			[[ -f '/etc/apt/trusted.gpg~' ]] && G_EXEC rm '/etc/apt/trusted.gpg~'

		#	Odroid C2
		elif (( $G_HW_MODEL == 12 )); then

			G_AGI linux-image-arm64-odroid-c2 meveric-keyring

			# Remove obsolete combined keyring
			[[ -f '/etc/apt/trusted.gpg' ]] && G_EXEC rm /etc/apt/trusted.gpg
			[[ -f '/etc/apt/trusted.gpg~' ]] && G_EXEC rm '/etc/apt/trusted.gpg~'

		#	Odroid XU3/XU4/MC1/HC1/HC2
		elif (( $G_HW_MODEL == 11 )); then

			G_AGI linux-image-4.14-armhf-odroid-xu4 meveric-keyring

			# Remove obsolete combined keyring
			[[ -f '/etc/apt/trusted.gpg' ]] && G_EXEC rm /etc/apt/trusted.gpg
			[[ -f '/etc/apt/trusted.gpg~' ]] && G_EXEC rm '/etc/apt/trusted.gpg~'

		#	ROCK Pi S (official Radxa Debian image)
		elif (( $G_HW_MODEL == 73 )) && grep -q 'apt\.radxa\.com' /etc/apt/sources.list.d/*.list; then

			# Install Radxa APT repo cleanly: No Bullseye repo available yet
			G_EXEC rm -Rf /etc/apt/{trusted.gpg,sources.list.d/{,.??,.[^.]}*}
			G_EXEC eval "curl -sSfL 'https://apt.radxa.com/${DISTRO_TARGET_NAME/bullseye/buster}-stable/public.key' | gpg --dearmor -o /etc/apt/trusted.gpg.d/dietpi-radxa.gpg --yes"
			G_EXEC eval "echo 'deb https://apt.radxa.com/${DISTRO_TARGET_NAME/bullseye/buster}-stable/ ${DISTRO_TARGET_NAME/bullseye/buster} main' > /etc/apt/sources.list.d/dietpi-radxa.list"
			G_AGUP

			# Remove obsolete combined keyring
			[[ -f '/etc/apt/trusted.gpg' ]] && G_EXEC rm /etc/apt/trusted.gpg
			[[ -f '/etc/apt/trusted.gpg~' ]] && G_EXEC rm '/etc/apt/trusted.gpg~'

			# NB: rockpis-dtbo is not required as it doubles the overlays that are already provided (among others) with the kernel package
			G_AGI rockpis-rk-ubootimg linux-4.4-rock-pi-s-latest rockchip-overlay u-boot-tools

		#	Radxa Zero (official Radxa Debian image)
		elif (( $G_HW_MODEL == 74 )) && grep -q 'apt\.radxa\.com' /etc/apt/sources.list.d/*.list; then

			# Install Radxa APT repo cleanly: No Bullseye repo available yet
			G_EXEC rm -Rf /etc/apt/{trusted.gpg,sources.list.d/{,.??,.[^.]}*}
			G_EXEC eval "curl -sSfL 'https://apt.radxa.com/${DISTRO_TARGET_NAME/bullseye/buster}-stable/public.key' | gpg --dearmor -o /etc/apt/trusted.gpg.d/dietpi-radxa.gpg --yes"
			G_EXEC eval "echo 'deb https://apt.radxa.com/${DISTRO_TARGET_NAME/bullseye/buster}-stable/ ${DISTRO_TARGET_NAME/bullseye/buster} main' > /etc/apt/sources.list.d/dietpi-radxa.list"
			G_AGUP

			# Remove obsolete combined keyring
			[[ -f '/etc/apt/trusted.gpg' ]] && G_EXEC rm /etc/apt/trusted.gpg
			[[ -f '/etc/apt/trusted.gpg~' ]] && G_EXEC rm '/etc/apt/trusted.gpg~'

			# Preserve all installed kernel, device tree and bootloader packages, until fixed meta packages are available: https://github.com/radxa/apt
			# Additionally install bc, required to calculate the initramfs size via custom hook (by Radxa) which updates /boot/uEnv.txt accordingly on initramfs updates
			# And install "file" which is used to detect whether the kernel image is compressed and in case uncompress it
			# shellcheck disable=SC2046
			G_AGI $(dpkg-query -Wf '${Package}\n' | grep -E '^linux-(image|dtb|u-boot)-|^u-boot') bc file

		# - Generic kernel + device tree + U-Boot package auto detect
		else

			mapfile -t apackages < <(dpkg-query -Wf '${Package}\n' | grep -E '^linux-(image|dtb|u-boot)-|^u-boot')
			if [[ ${apackages[0]} ]]; then

				G_AGI "${apackages[@]}"

			else

				G_DIETPI-NOTIFY 2 'Unable to find kernel packages for installation. Assuming non-APT/.deb kernel installation.'

			fi
			unset -v apackages

		fi
		G_EXEC apt-get clean # Remove downloaded archives

		# - Firmware
		if dpkg-query -Wf '${Package}\n' | grep -q '^armbian-firmware'; then

			aPACKAGES_REQUIRED_INSTALL+=('armbian-firmware')

		# - Do not install additional firmware on Radxa Zero for now
		elif [[ $G_HW_MODEL != 74 ]]
		then

			# Usually no firmware should be necessary for VMs. If user manually passes though some USB device, user might need to install the firmware then.
			if (( $G_HW_MODEL != 20 )); then

				aPACKAGES_REQUIRED_INSTALL+=('firmware-realtek')		# Realtek Eth+WiFi+BT dongle firmware
				if (( $G_HW_ARCH == 10 )); then

					aPACKAGES_REQUIRED_INSTALL+=('firmware-linux')		# Misc free+nonfree firmware

				else

					aPACKAGES_REQUIRED_INSTALL+=('firmware-linux-free')	# Misc free firmware
					aPACKAGES_REQUIRED_INSTALL+=('firmware-misc-nonfree')	# Misc nonfree firmware + Ralink WiFi

				fi

			fi

			if (( $WIFI_REQUIRED )); then

				aPACKAGES_REQUIRED_INSTALL+=('firmware-atheros')		# Qualcomm/Atheros WiFi+BT dongle firmware
				aPACKAGES_REQUIRED_INSTALL+=('firmware-brcm80211')		# Broadcom WiFi dongle firmware
				aPACKAGES_REQUIRED_INSTALL+=('firmware-iwlwifi')		# Intel WiFi dongle+PCIe firmware
				if (( $G_HW_MODEL == 20 )); then

					aPACKAGES_REQUIRED_INSTALL+=('firmware-realtek')	# Realtek Eth+WiFi+BT dongle firmware
					aPACKAGES_REQUIRED_INSTALL+=('firmware-misc-nonfree')	# Misc nonfree firmware + Ralink WiFi

				fi

			fi

		fi

		G_DIETPI-NOTIFY 2 'Generating list of minimal packages, required for DietPi installation'

		local apackages
		mapfile -t apackages < <(dpkg --get-selections "${aPACKAGES_REQUIRED_INSTALL[@]}" 2> /dev/null | mawk '{print $1}')
		[[ ${apackages[0]} ]] && G_EXEC_DESC='Marking required packages as manually installed' G_EXEC apt-mark manual "${apackages[@]}"
		unset -v apackages

		# Purging additional packages, that (in some cases) do not get autoremoved:
		# - Purge the "important" e2fsprogs if no ext[2-4] filesystem is present on the root partition table
		# - dbus: Not required for headless images, but sometimes marked as "important", thus not autoremoved.
		#	+ Workaround for "The following packages have unmet dependencies: glib-networking libgtk-3-0" and alike
		# - dhcpcd5: https://github.com/MichaIng/DietPi/issues/1560#issuecomment-370136642
		# - mountall: https://github.com/MichaIng/DietPi/issues/2613
		# - initscripts: Pre-installed on Jessie systems (?), superseded and masked by systemd, but never autoremoved
		# - chrony: Found left with strange "deinstall ok installed" mark left on Armbian images
		G_AGP "${ae2fsprogs[@]}" dbus dhcpcd5 mountall initscripts chrony '*office*' '*xfce*' '*qt5*' '*xserver*' '*xorg*' glib-networking libgtk-3-0 libsoup2.4-1 libglib2.0-0
		# Remove any autoremove prevention
		rm -fv /etc/apt/apt.conf.d/*autoremove*
		G_AGA

		#------------------------------------------------------------------------------------------------
		G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" "[$SETUP_STEP] APT installations"; ((SETUP_STEP++))
		#------------------------------------------------------------------------------------------------

		G_AGDUG
		G_EXEC apt-get clean # Remove downloaded archives

		# Distro is now target (for APT purposes and G_AGX support due to installed binary, its here, instead of after G_AGUP)
		G_DISTRO=$DISTRO_TARGET
		G_DISTRO_NAME=$DISTRO_TARGET_NAME
		unset -v DISTRO_TARGET DISTRO_TARGET_NAME

		G_DIETPI-NOTIFY 2 'Installing core DietPi pre-req DEB packages'

		G_AGI "${aPACKAGES_REQUIRED_INSTALL[@]}"
		unset -v aPACKAGES_REQUIRED_INSTALL

		# Adjust Dropbear package marks when Buster was upgraded to Bullseye
		if (( $G_DISTRO > 5 )) && dpkg-query -s 'dropbear-run' &> /dev/null
		then
			G_EXEC apt-mark manual dropbear
			G_EXEC apt-mark auto dropbear-run
		fi

		G_EXEC apt-get clean

		G_AGA

		#------------------------------------------------------------------------------------------------
		G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" "[$SETUP_STEP] Applying DietPi tweaks and cleanup"; ((SETUP_STEP++))
		#------------------------------------------------------------------------------------------------

		# Remove old gcc-*-base packages, e.g. accumulated on Raspberry Pi OS images
		if [[ $G_DISTRO == 5 ]]
		then
			mapfile -t apackages < <(dpkg --get-selections 'gcc-*-base' | mawk '$1!~/^gcc-8-/{print $1}')
			[[ ${apackages[0]} ]] && G_AGP "${apackages[@]}"

		elif [[ $G_DISTRO == 6 ]]
		then
			mapfile -t apackages < <(dpkg --get-selections 'gcc-*-base' | mawk '$1!~/^gcc-10-/{print $1}')
			[[ ${apackages[0]} ]] && G_AGP "${apackages[@]}"

		elif [[ $G_DISTRO == 7 ]]
		then
			mapfile -t apackages < <(dpkg --get-selections 'gcc-*-base' | mawk '$1!~/^gcc-11-/{print $1}')
			[[ ${apackages[0]} ]] && G_AGP "${apackages[@]}"
		fi

		# https://github.com/jirka-h/haveged/pull/7 https://github.com/MichaIng/DietPi/issues/3689#issuecomment-678322767
		if [[ $G_DISTRO == 5 && $G_HW_ARCH == [23] && $G_HW_MODEL -gt 9 ]] && dpkg-query -s haveged &> /dev/null; then

			G_DIETPI-NOTIFY 2 'Upgrading haveged entropy daemon to fix an issue on ARM:'
			G_DIETPI-NOTIFY 2 ' - https://github.com/jirka-h/haveged/pull/7'
			G_EXEC curl -sSfLO "https://dietpi.com/downloads/binaries/buster/libhavege2_$G_HW_ARCH_NAME.deb"
			G_EXEC curl -sSfLO "https://dietpi.com/downloads/binaries/buster/haveged_$G_HW_ARCH_NAME.deb"
			G_AGI "./libhavege2_$G_HW_ARCH_NAME.deb" "./haveged_$G_HW_ARCH_NAME.deb"
			G_EXEC_NOHALT=1 G_EXEC rm "./libhavege2_$G_HW_ARCH_NAME.deb" "./haveged_$G_HW_ARCH_NAME.deb"
			G_AGA

		fi

		G_DIETPI-NOTIFY 2 'Restoring default base files:'
		# shellcheck disable=SC2114
		rm -Rfv /etc/{motd,profile,update-motd.d,issue{,.net}} /root /home /media /var/mail
		G_AGI --reinstall base-files # Restore /etc/{update-motd.d,issue{,.net}} /root /home
		G_EXEC /var/lib/dpkg/info/base-files.postinst configure # Restore /root/.{profile,bashrc} /etc/{motd,profile} /media /var/mail

		# Remove downloaded archives
		G_EXEC apt-get clean

		G_DIETPI-NOTIFY 2 'Deleting list of known users and groups, not required by DietPi'

		getent passwd pi > /dev/null && userdel -f pi # Raspberry Pi OS
		getent passwd test > /dev/null && userdel -f test # @Fourdee
		getent passwd odroid > /dev/null && userdel -f odroid
		getent passwd rock64 > /dev/null && userdel -f rock64
		getent passwd rock > /dev/null && userdel -f rock # Radxa images
		getent passwd linaro > /dev/null && userdel -f linaro # ASUS TB
		getent passwd dietpi > /dev/null && userdel -f dietpi # recreated below
		getent passwd openmediavault-webgui > /dev/null && userdel -f openmediavault-webgui # OMV (NanoPi NEO2)
		getent passwd admin > /dev/null && userdel -f admin # OMV (NanoPi NEO2)
		getent passwd fa > /dev/null && userdel -f fa # OMV (NanoPi NEO2)
		getent passwd colord > /dev/null && userdel -f colord # OMV (NanoPi NEO2)
		getent passwd saned > /dev/null && userdel -f saned # OMV (NanoPi NEO2)
		getent group openmediavault-config > /dev/null && groupdel openmediavault-config # OMV (NanoPi NEO2)
		getent group openmediavault-engined > /dev/null && groupdel openmediavault-engined # OMV (NanoPi NEO2)
		getent group openmediavault-webgui > /dev/null && groupdel openmediavault-webgui # OMV (NanoPi NEO2)

		G_EXEC_DESC='Creating DietPi user account' G_EXEC /boot/dietpi/func/dietpi-set_software useradd dietpi
		chpasswd <<< 'root:dietpi'

		G_DIETPI-NOTIFY 2 'Removing misc files/folders/services, not required by DietPi'

		[[ -d '/selinux' ]] && G_EXEC rm -R /selinux
		[[ -d '/var/cache/apparmor' ]] && G_EXEC rm -R /var/cache/apparmor
		[[ -d '/var/lib/udisks2' ]] && G_EXEC rm -R /var/lib/udisks2
		[[ -d '/var/lib/bluetooth' ]] && G_EXEC rm -R /var/lib/bluetooth
		G_EXEC rm -Rf /var/lib/dhcp/{,.??,.[^.]}*
		G_EXEC rm -f /var/lib/misc/*.leases
		G_EXEC rm -Rf /var/backups/{,.??,.[^.]}*
		G_EXEC rm -f /etc/*.org
		[[ -f '/etc/fs.resized' ]] && G_EXEC rm /etc/fs.resized
		# Armbian desktop images
		[[ -d '/usr/lib/firefox-esr' ]] && G_EXEC rm -R /usr/lib/firefox-esr
		[[ -d '/etc/chromium.d' ]] && G_EXEC rm -R /etc/chromium.d
		[[ -d '/etc/lightdm' ]] && G_EXEC rm -R /etc/lightdm

		# - www
		[[ -d '/var/www' ]] && G_EXEC rm -Rf /var/www/{,.??,.[^.]}*

		# - Source code and Linux headers
		[[ -d '/usr/src' ]] && G_EXEC rm -Rf /usr/src/{,.??,.[^.]}*

		# - Documentation dirs: https://github.com/MichaIng/DietPi/issues/3259
		#[[ -d '/usr/share/man' ]] && G_EXEC rm -R /usr/share/man
		#[[ -d '/usr/share/doc' ]] && G_EXEC rm -R /usr/share/doc
		#[[ -d '/usr/share/doc-base' ]] && G_EXEC rm -R /usr/share/doc-base
		[[ -d '/usr/share/calendar' ]] && G_EXEC rm -R /usr/share/calendar

		# - Unused DEB package config files
		find /etc \( -name '?*\.dpkg-dist' -o -name '?*\.dpkg-old' -o -name '?*\.dpkg-new' -o -name '?*\.dpkg-bak' \) -exec rm -v {} +

		# - Fonts
		[[ -d '/usr/share/fonts' ]] && G_EXEC rm -R /usr/share/fonts
		[[ -d '/usr/share/icons' ]] && G_EXEC rm -R /usr/share/icons

		# - Stop, disable and remove not required 3rd party services
		local aservices=(

			# Meveric
			'cpu_governor'
			# RPi
			'sshswitch'
			# Radxa
			'rockchip-adbd'
			'rtl8723ds-btfw-load'
			'install-module-hci-uart'
			# Armbian
			'chrony'
			'chronyd'
			'armbian-resize-filesystem'
			'bootsplash-hide-when-booted'
			'bootsplash-show-on-shutdown'
			'armbian-firstrun-config'
			'bootsplash-ask-password-console'

		)

		for i in "${aservices[@]}"
		do
			# Loop through known service locations
			for j in /etc/init.d/$i /{etc,lib,usr/lib,usr/local/lib}/systemd/system/{$i.service{,.d},*.wants/$i.service}
			do
				[[ -e $j || -L $j ]] || continue
				[[ -f $j ]] && G_EXEC systemctl disable --now "${j##*/}"
				# Remove if not attached to any DEB package, else mask
				if dpkg -S "$j" &> /dev/null; then

					G_EXEC systemctl mask "${j##*/}"

				else
					[[ -e $j || -L $j ]] && G_EXEC rm -R "$j"

				fi
			done
		done

		# - Remove obsolete SysV service entries
		aservices=(

			'fake-hwclock'
			'haveged'
			'hwclock.sh'
			'networking'
			'udev'
			'cron'
			'console-setup.sh'
			'sudo'
			'cpu_governor'
			'keyboard-setup.sh'
			'kmod'
			'procps'

		)

		for i in "${aservices[@]}"
		do
			G_EXEC update-rc.d -f "$i" remove
		done
		unset -v aservices

		# - Armbian specific
		[[ -d '/var/lib/apt-xapian-index' ]] && G_EXEC rm -R /var/lib/apt-xapian-index # ??
		umount /var/log.hdd 2> /dev/null
		[[ -d '/var/log.hdd' ]] && G_EXEC rm -R /var/log.hdd
		[[ -f '/etc/armbian-image-release' ]] && G_EXEC rm /etc/armbian-image-release
		[[ -f '/boot/armbian_first_run.txt.template' ]] && G_EXEC rm /boot/armbian_first_run.txt.template
		[[ -d '/etc/armbianmonitor' ]] && G_EXEC rm -R /etc/armbianmonitor
		G_EXEC rm -f /etc/{default,logrotate.d}/armbian*
		[[ -f '/lib/firmware/bootsplash.armbian' ]] && G_EXEC rm /lib/firmware/bootsplash.armbian
		[[ -L '/etc/systemd/system/sysinit.target.wants/bootsplash-ask-password-console.path' ]] && G_EXEC rm /etc/systemd/system/sysinit.target.wants/bootsplash-ask-password-console.path

		# - OMV: https://github.com/MichaIng/DietPi/issues/2994
		[[ -d '/etc/openmediavault' ]] && G_EXEC rm -R /etc/openmediavault
		G_EXEC rm -f /etc/cron.*/openmediavault*
		G_EXEC rm -f /usr/sbin/omv-*

		# - Meveric specific
		[[ -f '/usr/local/sbin/setup-odroid' ]] && G_EXEC rm /usr/local/sbin/setup-odroid
		G_EXEC rm -f /installed-packages*.txt

		# - RPi specific: https://github.com/MichaIng/DietPi/issues/1631#issuecomment-373965406
		[[ -f '/etc/profile.d/wifi-country.sh' ]] && G_EXEC rm /etc/profile.d/wifi-country.sh
		[[ -f '/etc/sudoers.d/010_pi-nopasswd' ]] && G_EXEC rm /etc/sudoers.d/010_pi-nopasswd
		[[ -d '/etc/systemd/system/dhcpcd.service.d' ]] && G_EXEC rm -R /etc/systemd/system/dhcpcd.service.d # https://github.com/RPi-Distro/pi-gen/blob/master/stage3/01-tweaks/00-run.sh
		#	Do not ship rc.local anymore. On DietPi /var/lib/dietpi/postboot.d should be used.
		#	WIP: Mask rc-local.service and create symlink postboot.d/rc.local => /etc/rc.local for backwards compatibility?
		[[ -f '/etc/rc.local' ]] && rm -v /etc/rc.local # https://github.com/RPi-Distro/pi-gen/blob/master/stage2/01-sys-tweaks/files/rc.local
		[[ -d '/etc/systemd/system/rc-local.service.d' ]] && G_EXEC rm -R /etc/systemd/system/rc-local.service.d # Raspberry Pi OS
		[[ -d '/etc/systemd/system/rc.local.service.d' ]] && G_EXEC rm -R /etc/systemd/system/rc.local.service.d
		#	Below required if DietPi-PREP is executed from chroot/container, so RPi firstrun scripts are not executed
		[[ -f '/etc/init.d/resize2fs_once' ]] && G_EXEC rm /etc/init.d/resize2fs_once # https://github.com/RPi-Distro/pi-gen/blob/master/stage2/01-sys-tweaks/files/resize2fs_once
		# - Remove all autologin configs for all TTYs: https://github.com/MichaIng/DietPi/issues/3570#issuecomment-648988475, https://github.com/MichaIng/DietPi/issues/3628#issuecomment-653693758
		G_EXEC rm -f /etc/systemd/system/*getty@*.service.d/*autologin*.conf

		# - make_nas_processes_faster cron job on ROCK64 + NanoPi + PINE A64(?) images
		[[ -f '/etc/cron.d/make_nas_processes_faster' ]] && G_EXEC rm /etc/cron.d/make_nas_processes_faster

		#-----------------------------------------------------------------------------------
		# https://www.debian.org/doc/debian-policy/ch-opersys.html#site-specific-programs
		G_DIETPI-NOTIFY 2 'Setting modern /usr/local permissions'
		[[ -f '/etc/staff-group-for-usr-local' ]] && G_EXEC rm /etc/staff-group-for-usr-local
		G_EXEC chown -R root:root /usr/local
		G_EXEC chmod -R 0755 /usr/local

		#-----------------------------------------------------------------------------------
		# Boot Logo
		[[ -f '/boot/boot.bmp' ]] && G_EXEC curl -sSfL "https://github.com/$G_GITOWNER/DietPi/raw/$G_GITBRANCH/.meta/images/dietpi-logo_boot.bmp" -o /boot/boot.bmp

		#-----------------------------------------------------------------------------------
		# Bash Profiles

		# - Enable /etc/bashrc.d/ support for custom interactive non-login shell scripts:
		sed -i '\#/etc/bashrc\.d/#d' /etc/bash.bashrc
		# shellcheck disable=SC2016
		echo 'for i in /etc/bashrc.d/*.sh /etc/bashrc.d/*.bash; do [ -r "$i" ] && . $i; done; unset -v i' >> /etc/bash.bashrc

		# - Enable bash-completion for non-login shells:
		#	- NB: It is called twice on login shells then, but breaks directly if called already once.
		ln -sfv /etc/profile.d/bash_completion.sh /etc/bashrc.d/dietpi-bash_completion.sh

		#-----------------------------------------------------------------------------------
		# UID bit for sudo: https://github.com/MichaIng/DietPi/issues/794
		G_DIETPI-NOTIFY 2 'Setting sudo UID bit'
		chmod 4755 "$(command -v sudo)"

		#-----------------------------------------------------------------------------------
		# Dirs
		G_DIETPI-NOTIFY 2 'Generating DietPi directories'
		mkdir -pv /var/lib/dietpi/{postboot.d,dietpi-software/installed}
		mkdir -pv /var/tmp/dietpi/logs/dietpi-ramlog_store
		mkdir -pv /mnt/{dietpi_userdata,samba,ftp_client,nfs_client}
		chown -R dietpi:dietpi /var/{lib,tmp}/dietpi /mnt/{dietpi_userdata,samba,ftp_client,nfs_client}
		find /var/{lib,tmp}/dietpi /mnt/{dietpi_userdata,samba,ftp_client,nfs_client} -type d -exec chmod 0775 {} +

		#-----------------------------------------------------------------------------------
		# Services
		G_DIETPI-NOTIFY 2 'Enabling DietPi services'
		G_EXEC systemctl enable dietpi-ramlog
		G_EXEC systemctl enable dietpi-preboot
		G_EXEC systemctl enable dietpi-postboot
		G_EXEC systemctl enable dietpi-kill_ssh

		#-----------------------------------------------------------------------------------
		# Cron jobs
		G_EXEC_DESC='Configuring Cron'
		G_EXEC eval 'cat << _EOF_ > /etc/crontab
# Please use dietpi-cron to change cron start times
SHELL=/bin/dash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=""

# m h dom mon dow user command
#*/0 * * * * root cd / && run-parts --report /etc/cron.minutely
17 * * * * root cd / && run-parts --report /etc/cron.hourly
25 1 * * * root test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.daily; }
47 1 * * 7 root test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.weekly; }
52 1 1 * * root test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.monthly; }
_EOF_'
		#-----------------------------------------------------------------------------------
		# Network
		G_DIETPI-NOTIFY 2 'Removing all rfkill soft blocks and the rfkill package'
		rfkill unblock all
		G_AGP rfkill
		[[ -d '/var/lib/systemd/rfkill' ]] && rm -Rv /var/lib/systemd/rfkill

		G_DIETPI-NOTIFY 2 'Configuring wlan/eth naming to be preferred for networked devices:'
		ln -sfv /dev/null /etc/systemd/network/99-default.link
		ln -sfv /dev/null /etc/udev/rules.d/80-net-setup-link.rules
		# - Armbian: Add cmdline entry, which was required on my Raspbian Bullseye system since last few APT updates
		[[ -f '/boot/armbianEnv.txt' ]] && G_CONFIG_INJECT 'extraargs=' 'extraargs="net.ifnames=0"' /boot/armbianEnv.txt

		G_DIETPI-NOTIFY 2 'Configuring DNS nameserver:'
		# Failsafe: Assure that /etc/resolv.conf is not a symlink and disable systemd-resolved + systemd-networkd
		systemctl disable --now systemd-{resolve,network}d
		rm -fv /etc/resolv.conf
		echo 'nameserver 9.9.9.9' > /etc/resolv.conf # Apply generic functional DNS nameserver, updated on next service start

		# ifupdown starts the daemon outside of systemd, the enabled systemd unit just throws an error on boot due to missing dbus and with dbus might interfere with ifupdown
		systemctl disable wpa_supplicant 2> /dev/null && G_DIETPI-NOTIFY 2 'Disabled non-required wpa_supplicant systemd unit'

		G_EXEC_DESC='Configuring network interfaces'
		G_EXEC eval 'cat << _EOF_ > /etc/network/interfaces
# Location: /etc/network/interfaces
# Please modify network settings via: dietpi-config
# Or create your own drop-ins in: /etc/network/interfaces.d/

# Drop-in configs
source interfaces.d/*

# Ethernet
#allow-hotplug eth0
iface eth0 inet dhcp
address 192.168.0.100
netmask 255.255.255.0
gateway 192.168.0.1
#dns-nameservers 9.9.9.9 149.112.112.112

# WiFi
#allow-hotplug wlan0
iface wlan0 inet dhcp
address 192.168.0.100
netmask 255.255.255.0
gateway 192.168.0.1
#dns-nameservers 9.9.9.9 149.112.112.112
wireless-power off
wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
_EOF_'
		# Wait for network at boot by default
		/boot/dietpi/func/dietpi-set_software boot_wait_for_network 1

		#-----------------------------------------------------------------------------------
		# MISC
		G_DIETPI-NOTIFY 2 'Disabling apt-daily services to prevent random APT cache lock'
		for i in apt-daily{,-upgrade}.{service,timer}
		do
			G_EXEC systemctl disable --now $i
			G_EXEC systemctl mask $i
		done

		if command -v e2scrub > /dev/null
		then
			G_DIETPI-NOTIFY 2 'Disabling e2scrub services which are for LVM and require lvm2/lvcreate being installed'
			G_EXEC systemctl disable --now e2scrub_{all.timer,reap}
		fi

		G_DIETPI-NOTIFY 2 'Enabling weekly TRIM'
		G_EXEC systemctl enable fstrim.timer

		(( $G_HW_MODEL > 9 )) && echo "$G_HW_MODEL" > /etc/.dietpi_hw_model_identifier
		G_EXEC_DESC='Generating /boot/dietpi/.hw_model' G_EXEC /boot/dietpi/func/dietpi-obtain_hw_model

		G_EXEC_DESC='Generating /etc/fstab' G_EXEC /boot/dietpi/dietpi-drive_manager 4

		# Create and navigate to "/tmp/$G_PROGRAM_NAME" working directory, now assured to be tmpfs
		G_EXEC mkdir -p /tmp/$G_PROGRAM_NAME
		G_EXEC cd /tmp/$G_PROGRAM_NAME

		local info_use_drive_manager='Can be installed and setup by DietPi-Drive_Manager.\nSimply run "dietpi-drive_manager" and select "Add network drive".'
		echo -e "Samba client: $info_use_drive_manager" > /mnt/samba/readme.txt
		echo -e "NFS client: $info_use_drive_manager" > /mnt/nfs_client/readme.txt

		G_DIETPI-NOTIFY 2 'Resetting and adding dietpi.com SSH pub host key for DietPi-Survey/Bugreport uploads:'
		G_EXEC mkdir -p /root/.ssh
		echo 'ssh.dietpi.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDE6aw3r6aOEqendNu376iiCHr9tGBIWPgfrLkzjXjEsHGyVSUFNnZt6pftrDeK7UX+qX4FxOwQlugG4fymOHbimRCFiv6cf7VpYg1Ednquq9TLb7/cIIbX8a6AuRmX4fjdGuqwmBq3OG7ZksFcYEFKt5U4mAJIaL8hXiM2iXjgY02LqiQY/QWATsHI4ie9ZOnwrQE+Rr6mASN1BVFuIgyHIbwX54jsFSnZ/7CdBMkuAd9B8JkxppWVYpYIFHE9oWNfjh/epdK8yv9Oo6r0w5Rb+4qaAc5g+RAaknHeV6Gp75d2lxBdCm5XknKKbGma2+/DfoE8WZTSgzXrYcRlStYN' > /root/.ssh/known_hosts

		# ASUS TB WiFi: https://github.com/MichaIng/DietPi/issues/1760
		(( $G_HW_MODEL == 52 )) && G_CONFIG_INJECT '8723bs' '8723bs' /etc/modules

		echo 'DietPi' > /etc/hostname
		G_EXEC_DESC='Configuring hostname and hosts'
		G_EXEC eval 'cat << _EOF_ > /etc/hosts
127.0.0.1 localhost
127.0.1.1 DietPi
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
_EOF_'

		G_EXEC_DESC='Configuring htop'
		G_EXEC eval 'cat << _EOF_ > /etc/htoprc
# DietPi default config for htop
# Location: /etc/htoprc
# NB: htop will create "~/.config/htop/htoprc" per-user based on this defaults, when opened the first time.
#     Use setup (F2) within htop GUI or edit "~/.config/htop/htoprc" to change settings according to your needs.
fields=0 48 39 18 46 49 1
sort_key=46
sort_direction=1
hide_threads=0
hide_kernel_threads=1
hide_userland_threads=1
shadow_other_users=0
show_thread_names=0
show_program_path=1
highlight_base_name=1
highlight_megabytes=1
highlight_threads=0
tree_view=1
header_margin=0
detailed_cpu_time=0
cpu_count_from_zero=1
update_process_names=0
account_guest_in_cpu_meter=0
color_scheme=0
delay=15
left_meters=AllCPUs CPU
left_meter_modes=1 1
right_meters=Memory Swap Tasks LoadAverage Uptime
right_meter_modes=1 1 2 2 2
_EOF_'
		G_DIETPI-NOTIFY 2 'Configuring serial login consoles:'
		# On virtual machines, serial consoles are not required
		if (( $G_HW_MODEL == 20 )); then

			/boot/dietpi/func/dietpi-set_hardware serialconsole disable

		else

			/boot/dietpi/func/dietpi-set_hardware serialconsole enable
			# On RPi the primary serial console depends on model, use "serial0" which links to the primary console, converts to correct device on first boot
			if (( $G_HW_MODEL < 10 )); then

				/boot/dietpi/func/dietpi-set_hardware serialconsole disable ttyAMA0
				# The actual serial console services need to be masked explicitly to ensure they are not autostarted when the image is created within a container or without both serial devices present, since masks are only placed by dietpi-set_hardware for existing devices: : https://github.com/MichaIng/DietPi/issues/5014
				G_EXEC systemctl mask serial-getty@ttyAMA0
				/boot/dietpi/func/dietpi-set_hardware serialconsole disable ttyS0
				G_EXEC systemctl mask serial-getty@ttyS0
				/boot/dietpi/func/dietpi-set_hardware serialconsole enable serial0

			# ROCK Pi S: Enable on ttyS0 only
			elif (( $G_HW_MODEL == 73 )); then

				/boot/dietpi/func/dietpi-set_hardware serialconsole disable
				/boot/dietpi/func/dietpi-set_hardware serialconsole enable ttyS0
				G_CONFIG_INJECT 'CONFIG_SERIAL_CONSOLE_ENABLE=' 'CONFIG_SERIAL_CONSOLE_ENABLE=1' /boot/dietpi.txt

			fi

		fi

		G_DIETPI-NOTIFY 2 'Disabling static and automatic login prompts on consoles tty2 to tty6:'
		G_EXEC systemctl mask --now getty-static
		# - logind features are usually not needed and (aside of automatic getty spawn) require the libpam-systemd package.
		# - It will be unmasked automatically if libpam-systemd got installed during dietpi-software install, e.g. with desktops.
		G_EXEC systemctl mask --now systemd-logind

		G_DIETPI-NOTIFY 2 'Configuring locales:'
		/boot/dietpi/func/dietpi-set_software locale 'C.UTF-8'

		G_DIETPI-NOTIFY 2 'Configuring time zone:'
		G_EXEC rm -f /etc/{localtime,timezone}
		G_EXEC ln -s /usr/share/zoneinfo/UTC /etc/localtime
		G_EXEC dpkg-reconfigure -f noninteractive tzdata

		G_DIETPI-NOTIFY 2 'Configuring keyboard:'
		echo -e 'XKBMODEL="pc105"\nXKBLAYOUT="gb"' > /etc/default/keyboard
		dpkg-reconfigure -f noninteractive keyboard-configuration # Keyboard must be plugged in for this to work!

		G_DIETPI-NOTIFY 2 'Configuring console:' # This can be wrong, e.g. when selecting a non-UTF-8 locale during Debian installer
		G_CONFIG_INJECT 'CHARMAP=' 'CHARMAP="UTF-8"' /etc/default/console-setup
		G_EXEC eval "debconf-set-selections <<< 'console-setup console-setup/charmap47 select UTF-8'"
		G_EXEC setupcon --save

		G_DIETPI-NOTIFY 2 'Applying architecture-specific tweaks:'
		if (( $G_HW_ARCH == 10 )); then

			G_EXEC_DESC='Removing foreign i386 DPKG architecture' G_EXEC dpkg --remove-architecture i386

			# Disable nouveau: https://github.com/MichaIng/DietPi/issues/1244 // https://dietpi.com/phpbb/viewtopic.php?p=9688#p9688
			rm -f /etc/modprobe.d/*nouveau*
			cat << '_EOF_' > /etc/modprobe.d/dietpi-disable_nouveau.conf
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
_EOF_
			# Fix grub install device: https://github.com/MichaIng/DietPi/issues/3700
			dpkg-query -s grub-pc &> /dev/null && G_EXEC eval "debconf-set-selections <<< 'grub-pc grub-pc/install_devices multiselect /dev/sda'"

			# Update initramfs with above changes
			if command -v update-tirfs > /dev/null; then

				G_EXEC_OUTPUT=1 G_EXEC update-tirfs

			else

				G_EXEC_OUTPUT=1 G_EXEC update-initramfs -u

			fi

		elif (( $G_HW_ARCH == 3 )); then

			G_EXEC_DESC='Removing foreign armhf DPKG architecture' G_EXEC dpkg --remove-architecture armhf

		fi

		G_DIETPI-NOTIFY 2 'Applying board-specific tweaks:'
		if (( $G_HW_MODEL != 20 )); then

			G_EXEC_DESC='Configuring hdparm'
			# Since Debian Bullseye, spindown_time is not applied if APM is not supported by the drive. force_spindown_time is required to override that.
			local spindown='spindown_time'
			(( $G_DISTRO > 5 )) && spindown='force_spindown_time'
			G_EXEC eval "cat << _EOF_ > /etc/hdparm.conf
apm = 127
$spindown = 120
_EOF_"
			unset -v spindown

		fi

		# - Sparky SBC
		if (( $G_HW_MODEL == 70 )); then

			# Install latest kernel/drivers
			G_EXEC curl -sSfL https://raw.githubusercontent.com/sparky-sbc/sparky-test/master/dragon_fly_check/uImage -o /boot/uImage
			G_EXEC curl -sSfLO https://raw.githubusercontent.com/sparky-sbc/sparky-test/master/dragon_fly_check/3.10.38.bz2
			G_EXEC tar -xf 3.10.38.bz2 -C /lib/modules/
			G_EXEC rm 3.10.38.bz2
			# - USB audio update
			G_EXEC curl -sSfL https://raw.githubusercontent.com/sparky-sbc/sparky-test/master/dsd-marantz/snd-usb-audio.ko -o /lib/modules/3.10.38/kernel/sound/usb/snd-usb-audio.ko
			# - Ethernet update
			G_EXEC curl -sSfL https://raw.githubusercontent.com/sparky-sbc/sparky-test/master/sparky-eth/ethernet.ko -o /lib/modules/3.10.38/kernel/drivers/net/ethernet/acts/ethernet.ko

			# Boot args
			cat << '_EOF_' > /boot/uenv.txt
uenvcmd=setenv os_type linux;
bootargs=earlyprintk clk_ignore_unused selinux=0 scandelay console=tty0 loglevel=1 real_rootflag=rw root=/dev/mmcblk0p2 rootwait init=/lib/systemd/systemd aotg.urb_fix=1 aotg.aotg1_speed=0 net.ifnames=0 systemd.unified_cgroup_hierarchy=0
_EOF_
			# Blacklist GPU and touch screen modules: https://github.com/MichaIng/DietPi/issues/699#issuecomment-271362441
			cat << '_EOF_' > /etc/modprobe.d/dietpi-disable_sparkysbc_touchscreen.conf
blacklist owl_camera
blacklist gsensor_stk8313
blacklist ctp_ft5x06
blacklist ctp_gsl3680
blacklist gsensor_bma222
blacklist gsensor_mir3da
_EOF_
			cat << '_EOF_' > /etc/modprobe.d/dietpi-disable_sparkysbc_gpu.conf
blacklist pvrsrvkm
blacklist drm
blacklist videobuf2_vmalloc
blacklist bc_example
_EOF_
			# Use performance gov for stability
			G_CONFIG_INJECT 'CONFIG_CPU_GOVERNOR=' 'CONFIG_CPU_GOVERNOR=performance' /boot/dietpi.txt

			# Install script to toggle between USB and onboard Ethernet automatically
			cat << '_EOF_' > /var/lib/dietpi/services/dietpi-sparkysbc_ethernet.sh
#!/bin/dash
# Called from: /etc/systemd/system/dietpi-sparkysbc_ethernet.service
# We need to wait until USB Ethernet is established on USB bus, which takes much longer than onboard init.
sleep 20
# Disable onboard Ethernet if USB Ethernet is found
if ip a s eth1 > /dev/null 2>&1; then

	echo 'blacklist ethernet' > /etc/modprobe.d/dietpi-disable_sparkysbc_ethernet.conf
	reboot

# Enable onboard Ethernet if no adapter is found
elif ! ip a s eth0 > /dev/null 2>&1; then

	rm -f /etc/modprobe.d/dietpi-disable_sparkysbc_ethernet.conf
	reboot

fi
_EOF_
			G_EXEC chmod +x /var/lib/dietpi/services/dietpi-sparkysbc_ethernet.sh
			cat << '_EOF_' > /etc/systemd/system/dietpi-sparkysbc_ethernet.service
[Unit]
Description=Sparky SBC auto detect and toggle onboard/USB Ethernet
Wants=network-online.target
After=network-online.target

[Service]
RemainAfterExit=yes
ExecStart=/var/lib/dietpi/services/dietpi-sparkysbc_ethernet.sh

[Install]
WantedBy=multi-user.target
_EOF_
			G_EXEC systemctl enable dietpi-sparkysbc_ethernet

		# - RPi
		elif (( $G_HW_MODEL < 10 )); then

			# Creating RPi-specific groups
			G_EXEC groupadd -rf spi
			G_EXEC groupadd -rf i2c
			G_EXEC groupadd -rf gpio

			# Apply minimum GPU memory split for server usage: This applies a custom dtoverlay to disable VCSM: https://github.com/MichaIng/DietPi/pull/3900
			/boot/dietpi/func/dietpi-set_hardware gpumemsplit 16

			# Disable RPi camera and codecs to add modules blacklist
			/boot/dietpi/func/dietpi-set_hardware rpi-camera disable
			/boot/dietpi/func/dietpi-set_hardware rpi-codec disable

			# Update USBridgeSig Ethernet driver via postinst kernel script, until it has been merged into official RPi kernel: https://github.com/allocom/USBridgeSig/tree/master/ethernet
			cat << '_EOF_' > /etc/kernel/postinst.d/dietpi-USBridgeSig
#!/bin/bash
# Only available for v7+
[[ $1 == *'-v7+' ]] || exit 0
# Only reasonable for USBridgeSig = CM 3+
grep -q '^Revision.*10.$' /proc/cpuinfo || exit 0
echo "[ INFO ] Updating ASIX AX88179 driver for kernel $1 with ARM-optimised build"
echo '[ INFO ] - by Allo: https://github.com/allocom/USBridgeSig/tree/master/ethernet'
echo '[ INFO ] Estimating required module layout...'
module_layout=$(modprobe --dump-modversions /lib/modules/$1/kernel/drivers/net/usb/asix.ko | mawk '/module_layout/{print $1;exit}') || exit 0
echo '[ INFO ] Downloading stable branch driver...'
if ! curl -#fL http://3.230.113.73:9011/Allocom/USBridgeSig/stable_rel/rpi-usbs-$1/ax88179_178a.ko -o /tmp/ax88179_178a.ko ||
	[[ $module_layout != $(modprobe --dump-modversions /tmp/ax88179_178a.ko | mawk '/module_layout/{print $1;exit}') ]]
then
	echo '[ INFO ] No matching stable branch driver found, trying master branch driver...'
	if ! curl -#fL http://3.230.113.73:9011/Allocom/USBridgeSig/rpi-usbs-$1/ax88179_178a.ko -o /tmp/ax88179_178a.ko ||
		[[ $module_layout != $(modprobe --dump-modversions /tmp/ax88179_178a.ko | mawk '/module_layout/{print $1;exit}') ]]
	then
		echo '[ INFO ] No matching driver found, cleaning up and aborting...'
		rm -fv /tmp/ax88179_178a.ko || :
		echo '[ INFO ] The default RPi kernel driver will be used instead, which might result in pops and ticks in your audio stream. If so, please try to rerun this script later:'
		echo " - /etc/kernel/postinst.d/dietpi-USBridgeSig $1"
		exit 0
	fi
fi
echo '[ INFO ] Installing driver...'
install -vpm 644 /tmp/ax88179_178a.ko /lib/modules/$1/kernel/drivers/net/usb || exit 0
echo '[ INFO ] Running depmod...'
depmod $1 || exit 0
echo '[ INFO ] All succeeded, cleaning up...'
rm -v /tmp/ax88179_178a.ko || exit 0
_EOF_
			G_EXEC chmod +x /etc/kernel/postinst.d/dietpi-USBridgeSig
			# Force upgrade now, regardless of current host machine
			G_EXEC sed -i 's/^grep/#grep/' /etc/kernel/postinst.d/dietpi-USBridgeSig
			for i in /lib/modules/*-v7+
			do
				[[ -d $i ]] || continue
				i=${i##*/}
				/etc/kernel/postinst.d/dietpi-USBridgeSig "$i"
			done
			G_EXEC sed -i 's/^#grep/grep/' /etc/kernel/postinst.d/dietpi-USBridgeSig

			# Create RPi Zero 2 W device tree if not existent
			[[ -f '/boot/bcm2710-rpi-zero-2.dtb' ]] || G_EXEC cp -a /boot/bcm2710-rpi-{3-b,zero-2}.dtb

			# For backwards compatibility with software compiled against older libraspberrypi0, create symlinks from old to new filenames
			if (( $G_HW_ARCH < 3 ))
			then
				G_DIETPI-NOTIFY 2 'Applying workaround for compiled against older libraspberrypi0'
				G_EXEC cd /usr/lib/arm-linux-gnueabihf
				while read -r line
				do
					[[ ! -f $line || -f ${line%.0} ]] && continue
					line=${line#/usr/lib/arm-linux-gnueabihf/}
					G_EXEC ln -sf "$line" "${line%.0}"

				done < <(dpkg -L 'libraspberrypi0' | grep '^/usr/lib/arm-linux-gnueabihf/.*\.so.0$')
			fi

		# - PINE A64 (and possibly others): Cursor fix for FB
		elif (( $G_HW_MODEL == 40 )); then

			cat << _EOF_ > /etc/bashrc.d/dietpi-pine64-cursorfix.sh
#!/bin/dash
# DietPi: Cursor fix for FB
infocmp > terminfo.txt
sed -i -e 's/?0c/?112c/g' -e 's/?8c/?48;0;64c/g' terminfo.txt
tic terminfo.txt
tput cnorm
_EOF_
			# Ensure WiFi module pre-exists
			G_CONFIG_INJECT '8723bs' '8723bs' /etc/modules

		# - Radxa Zero
		elif (( $G_HW_MODEL == 74 ))
		then
			# Use ondemand CPU governor since schedutil currently causes kernel errors and hangs
			G_CONFIG_INJECT 'CONFIG_CPU_GOVERNOR=' 'CONFIG_CPU_GOVERNOR=ondemand' /boot/dietpi.txt

			# uEnv.txt version (Radxa Debian image)
			if [[ -d '/boot/uEnv.txt' ]]
			then
				# Reduce console log verbosity to default 4 to mute regular USB detection info messages
				G_CONFIG_INJECT 'verbosity=' 'verbosity=4' /boot/uEnv.txt

				# Disable Docker optimisations, since this has some performance drawbacks, enable on Docker install instead
				G_CONFIG_INJECT 'docker_optimizations=' 'docker_optimizations=off' /boot/uEnv.txt
			fi

		# - NanoPi R1
		elif [[ $G_HW_MODEL == 48 && -f '/boot/armbianEnv.txt' ]]
		then
			# Enable second USB port by default
			local current=$(sed -n '/^[[:blank:]]*overlays=/{s/^[^=]*=//p;q}' /boot/armbianEnv.txt)
			[[ $current == *'usbhost2'* ]] || G_CONFIG_INJECT 'overlays=' "overlays=$current usbhost2" /boot/armbianEnv.txt
		fi

		# - Armbian special
		if [[ -f '/boot/armbianEnv.txt' ]]; then

			# Disable bootsplash logo, as we removed the file above: https://github.com/MichaIng/DietPi/issues/3932#issuecomment-852376681
			G_CONFIG_INJECT 'bootlogo=' 'bootlogo=false' /boot/armbianEnv.txt

			# Reset default kernel log verbosity, reduced to "1" on most Armbian images
			G_CONFIG_INJECT 'verbosity=' 'verbosity=4' /boot/armbianEnv.txt

			# Disable Docker optimisations, since this has some performance drawbacks, enable on Docker install instead
			G_CONFIG_INJECT 'docker_optimizations=' 'docker_optimizations=off' /boot/armbianEnv.txt

		fi

		# Apply cgroups-v2 workaround on Bullseye if the kernel does not support it: https://github.com/MichaIng/DietPi/issues/4705
		if (( $G_DISTRO > 5 )) && ! find /lib/modules -maxdepth 1 -type d -name '5.[0-9]*' > /dev/null
		then
			# Odroids
			if [[ $G_HW_MODEL -gt 9 && $G_HW_MODEL -le 16 && -f '/boot/boot.ini' ]]
			then
				G_DIETPI-NOTIFY 2 'Forcing legacy cgroups v1 hierarchy on old kernel device'
				grep -q 'systemd.unified_cgroup_hierarchy=0' /boot/boot.ini || G_EXEC sed -i '/^setenv bootargs "/s/"$/ systemd.unified_cgroup_hierarchy=0"/' /boot/boot.ini

			# Sparky SBC
			elif [[ $G_HW_MODEL == 70 && -f '/boot/uenv.txt' ]]
			then
				G_DIETPI-NOTIFY 2 'Forcing legacy cgroups v1 hierarchy on old kernel device'
				grep -q 'systemd.unified_cgroup_hierarchy=0' /boot/uenv.txt || G_EXEC sed -i '/^bootargs=/s/$/ systemd.unified_cgroup_hierarchy=0/' /boot/uenv.txt

			# ROCK Pi S
			elif [[ $G_HW_MODEL == 73 && -f '/boot/boot.cmd' ]]
			then
				G_DIETPI-NOTIFY 2 'Forcing legacy cgroups v1 hierarchy on old kernel device'
				grep -q 'systemd.unified_cgroup_hierarchy=0' /boot/boot.cmd || G_EXEC sed -i '/^setenv bootargs "/s/"$/ systemd.unified_cgroup_hierarchy=0"/' /boot/boot.cmd
				G_EXEC mkimage -C none -A arm64 -T script -d /boot/boot.cmd /boot/boot.scr
			fi
		fi

		#------------------------------------------------------------------------------------------------
		G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" "[$SETUP_STEP] Finalise system for first boot of DietPi"; ((SETUP_STEP++))
		#------------------------------------------------------------------------------------------------

		G_EXEC_DESC='Enable Dropbear autostart' G_EXEC sed -i '/NO_START=1/c\NO_START=0' /etc/default/dropbear
		G_EXEC systemctl unmask dropbear
		G_EXEC systemctl enable dropbear

		G_DIETPI-NOTIFY 2 'Configuring services'
		/boot/dietpi/dietpi-services stop
		/boot/dietpi/dietpi-services dietpi_controlled

		G_DIETPI-NOTIFY 2 'Mask cron until 1st run setup is completed'
		G_EXEC systemctl mask cron

		G_DIETPI-NOTIFY 2 'Removing swapfile from image'
		/boot/dietpi/func/dietpi-set_swapfile 0 /var/swap
		[[ -e '/var/swap' ]] && rm -v /var/swap # still exists on some images...
		# - Re-enable for next run
		G_CONFIG_INJECT 'AUTO_SETUP_SWAPFILE_SIZE=' 'AUTO_SETUP_SWAPFILE_SIZE=1' /boot/dietpi.txt
		# - Reset /tmp size to default (512 MiB)
		sed -i '\|/tmp|s|size=[^,]*,||' /etc/fstab

		G_DIETPI-NOTIFY 2 'Disabling Bluetooth by default'
		/boot/dietpi/func/dietpi-set_hardware bluetooth disable

		# - Set WiFi
		local tmp_info='Disabling'
		local tmp_mode='disable'
		if (( $WIFI_REQUIRED )); then

			G_DIETPI-NOTIFY 2 'Generating default wpa_supplicant.conf'
			/boot/dietpi/func/dietpi-wifidb 1
			# Move to /boot/ so users can modify as needed for automated
			G_EXEC mv /var/lib/dietpi/dietpi-wifi.db /boot/dietpi-wifi.txt

			tmp_info='Enabling'
			tmp_mode='enable'

		fi

		G_DIETPI-NOTIFY 2 "$tmp_info onboard WiFi modules by default"
		/boot/dietpi/func/dietpi-set_hardware wifimodules onboard_$tmp_mode

		G_DIETPI-NOTIFY 2 "$tmp_info generic WiFi by default"
		/boot/dietpi/func/dietpi-set_hardware wifimodules $tmp_mode

		# - x86_64: GRUB install and config
		if (( $G_HW_ARCH == 10 )); then

			G_EXEC_DESC='Detecting additional OS installed on system' G_EXEC_OUTPUT=1 G_EXEC os-prober

			# UEFI
			if [[ -d '/boot/efi' ]] && dpkg-query -s 'grub-efi-amd64' &> /dev/null
			then
				# Force GRUB installation to the EFI removable media path, if no (other) bootloader is installed there yet, which is checked via single case-insensitive glob
				shopt -s nocaseglob
				local efi_fallback=
				# shellcheck disable=SC2043
				for i in /boot/efi/EFI/boot/bootx64.efi
				do
					[[ -d $i ]] && break
					efi_fallback='--force-extra-removable'
					debconf-set-selections <<< 'grub-efi-amd64 grub2/force_efi_extra_removable boolean true'
				done
				shopt -u nocaseglob
				G_EXEC_DESC='Installing GRUB for UEFI' G_EXEC_OUTPUT=1 G_EXEC grub-install --recheck --target=x86_64-efi --efi-directory=/boot/efi $efi_fallback --uefi-secure-boot

			# BIOS
			else
				G_EXEC_DESC='Installing GRUB for BIOS' G_EXEC_OUTPUT=1 G_EXEC grub-install --recheck "$(lsblk -npo PKNAME "$(findmnt -Ufnro SOURCE -M /)")"
			fi

			# Update config
			G_CONFIG_INJECT 'GRUB_CMDLINE_LINUX_DEFAULT=' 'GRUB_CMDLINE_LINUX_DEFAULT="consoleblank=0 quiet"' /etc/default/grub
			G_CONFIG_INJECT 'GRUB_CMDLINE_LINUX=' 'GRUB_CMDLINE_LINUX="net.ifnames=0"' /etc/default/grub
			G_CONFIG_INJECT 'GRUB_TIMEOUT=' 'GRUB_TIMEOUT=0' /etc/default/grub
			G_EXEC_DESC='Regenerating GRUB config' G_EXEC_OUTPUT=1 G_EXEC grub-mkconfig -o /boot/grub/grub.cfg

			# Purge "os-prober" again
			G_AGP os-prober
		fi

		G_DIETPI-NOTIFY 2 'Disabling soundcards by default'
		/boot/dietpi/func/dietpi-set_hardware soundcard none

		G_DIETPI-NOTIFY 2 'Setting default CPU gov'
		/boot/dietpi/func/dietpi-set_cpu

		G_DIETPI-NOTIFY 2 'Resetting DietPi auto-generated settings and flag files'
		rm -v /boot/dietpi/.??*

		G_EXEC cp /var/lib/dietpi/.dietpi_image_version /boot/dietpi/.version

		G_DIETPI-NOTIFY 2 'Set init .install_stage to -1 (first boot)'
		echo -1 > /boot/dietpi/.install_stage

		G_DIETPI-NOTIFY 2 'Writing PREP information to file'
		echo -e "$IMAGE_CREATOR\n$PREIMAGE_INFO" > /boot/dietpi/.prep_info

		G_DIETPI-NOTIFY 2 'Generating GPLv2 license readme'
		cat << '_EOF_' > /var/lib/dietpi/license.txt
-----------------------
DietPi - GPLv2 License:
-----------------------
 - Use arrow keys to scroll
 - Press 'TAB' then 'ENTER' to continue

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 2 of the License, or any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, please see http://www.gnu.org/licenses/
_EOF_

		G_DIETPI-NOTIFY 2 'Disabling and clearing APT cache'
		G_EXEC rm /etc/apt/apt.conf.d/98dietpi-prep
		/boot/dietpi/func/dietpi-set_software apt-cache cache disable
		/boot/dietpi/func/dietpi-set_software apt-cache clean

		G_EXEC_DESC='Enabling automated partition and file system resize for first boot' G_EXEC systemctl enable dietpi-fs_partition_resize
		G_EXEC_DESC='Enabling first boot installation process' G_EXEC systemctl enable dietpi-firstboot

		G_DIETPI-NOTIFY 2 'Clearing lost+found'
		rm -Rfv /lost+found/{,.??,.[^.]}*

		G_DIETPI-NOTIFY 2 'Clearing DietPi logs, written during PREP'
		rm -Rfv /var/tmp/dietpi/logs/{,.??,.[^.]}*

		G_DIETPI-NOTIFY 2 'Clearing items below tmpfs mount points'
		G_EXEC mkdir -p /mnt/tmp_root
		G_EXEC mount "$(findmnt -Ufnro SOURCE -M /)" /mnt/tmp_root
		rm -vRf /mnt/tmp_root/{dev,proc,run,sys,tmp,var/log}/{,.??,.[^.]}*
		G_EXEC umount /mnt/tmp_root
		G_EXEC rmdir /mnt/tmp_root

		G_DIETPI-NOTIFY 2 'Running general cleanup of misc files'
		rm -Rfv /{root,home/*}/.{bash_history,nano_history,wget-hsts,cache,local,config,gnupg,viminfo,dbus,gconf,nano,vim,zshrc,oh-my-zsh} /etc/*- /var/{cache/debconf,lib/dpkg}/*-old /var/lib/dhcp/{,.??,.[^.]}*

		# Remove PREP script
		[[ -f $FP_PREP_SCRIPT ]] && rm -v "$FP_PREP_SCRIPT"

		sync

		G_DIETPI-NOTIFY 2 "The used kernel version is:\n\t- $(uname -a)"
		kernel_apt_packages=$(dpkg -l | grep -E '[[:blank:]]linux-(image|dtb)-[0-9]')
		[[ $kernel_apt_packages ]] && G_DIETPI-NOTIFY 2 "The following kernel DEB packages have been found:\n\e[0m$kernel_apt_packages"

		G_DIETPI-NOTIFY 2 'The following kernel images and modules have been found:'
		ls -lAh /boot /lib/modules

		G_DIETPI-NOTIFY 0 'Completed, disk can now be saved to .img for later use, or, reboot system to start first run of DietPi.'

		# shellcheck disable=SC2016
		G_DIETPI-NOTIFY 0 'To create an .img file, you can "poweroff" and run the following command from the host/external DietPi system:\n\t- bash -c "$(curl -sSfL https://github.com/MichaIng/DietPi/blob/master/.meta/dietpi-imager)"'

	}

	#------------------------------------------------------------------------------------------------
	Main
	#------------------------------------------------------------------------------------------------
}
