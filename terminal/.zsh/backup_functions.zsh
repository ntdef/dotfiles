#!/bin/zsh
# TODO:
# maybe don't backup with sntcvol if both volumes are same exact size
# add back full online soma backup
# test with veracrypt and maybe switch to (or tcplay)
# look at tomb and other front-ends
# maybe switch to something like borg or rsapshot (incremental backups)
# maybe use something like syncany or duplicity for online backup

# NOTES:
# - See ./completion/
# - Using unquoted ${*: -1} to get the last arg

# Help {{{
function bkhelp() {
	echo "
sntcvol          - backup a truecrypt volume to a directory
Takes two arguments corresponding to the path to the tc volume and the path of
the backup directory. If the volume does not exist in the backup directory, it
will be copied over (after being unmounted). Otherwise, both volumes will be
mounted (if they are not already mounted), and the contents of of the first
volume will be rsynced to the backup volume.
	Examples:
	  $ sntcvol <tc_volume> <bk_dir>
	  don't prompt to eject last mounted drive (with devmon):
	  $ sntcvol -n <tc_volume> <bk_dir>
	  $ sntcvol -h

sndb             - backup datab to directory under /media
	Takes one positional arg or -h.
	$ sndatab path/to/backup/dir/under/media

bahamut          - backup soma to directory under /media
	Same as sndb but for ~/soma.

snsmall          - small/quick online encrypted backup

snhome           - backup ~/ to a directory
	Takes one argument corresponding to the location of the backup directory.
	Also backs up soma and datab.
	$ snhome /path/to/backup/dir

snpsp            - backup mounted psp memcard to database
	Takes one argument corresponding to location of the memory stick.
	$ snpsp /path/to/psp/memcard
"
}

# }}}

function confirm_do() {
	if [[ $# -lt 1 ]]; then
		echo "An argument corresponding to the action to take is required."
		return 1
	fi
	# read is different for zsh
	read -q REPLY
	echo
	if [[ ! $REPLY =~ ^[Yy]$ ]]; then
		return 1
	else
		"$@"
	fi

}

# Unmounting External Drives {{{
# unmount most recent external drive
alias uned="devmon --unmount-recent"
# unmount all external
alias uneda="devmon -unmount-all"
# eject disk
alias ej="sudo eject /dev/sr0"
function maybe_eject() {
	echo "Unmount last mounted external drive? (y/n)"
	confirm_do devmon --unmount-recent || return 0
}

# }}}

# TC Mounting and Unmounting {{{
# create mount point if does not exist
# prevent non-zero return when a volume is already mounted
function mount_tc() {
	local tc_volume
	local mount_point
	tc_volume=$1
	mount_point=$2
	if [[ $# -ne 2 ]]; then
		echo "mount_tc takes two args: /path/to/tc_vol /path/to/mount_point"
		return 1
	elif [[ ! -f $tc_volume ]]; then
		echo "Error. The file $tc_volume does not exist."
		return 1
	elif truecrypt --text --list "$tc_volume" &> /dev/null; then
		echo "$tc_volume is already mounted."
		return 0
	elif [[ -e $mount_point ]] && [[ ! -d $mount_point ]]; then
		echo "Error. $mount_point exists but is not a directory."
		return 1
	elif [[ -d $mount_point ]] && \
			 [[ -n $(ls -A "$mount_point" 2> /dev/null) ]]; then
		echo "Error. Files exist in mount point ${mount_point}."
		return 1
	else
		mkdir -p "$mount_point" && \
			truecrypt --text --protect-hidden=no --keyfiles= \
			"$tc_volume" "$mount_point"
	fi
}

# prevent non-zero return when a volume is not mounted
function umount_tc() {
	if [[ -n $1 ]]; then
		local tc_volume
		tc_volume=$1
		if truecrypt --text --list "$tc_volume" &> /dev/null; then
			truecrypt --text --dismount "$tc_volume"
		else
			echo "$tc_volume is not mounted."
		fi
	else
		echo "Unmount all truecrypt containers? (y/n)"
		confirm_do truecrypt --text --dismount || return 1
	fi
}

# }}}

# zuluMount Mounting and Umounting {{{
# holding off on for now... may just switch to veracrypt instead of tc-play

# limitations:
# - Can't choose full path (only directly under $HOME (or /run/media/private/$USER))
function mount_z() {
	local volume
	local mount_point
	volume=$1
	mount_point=$2
	if [[ $# -ne 2 ]]; then
		echo "mount_z takes two args: /path/to/vol /path/to/mount_point"
		return 1
	elif [[ ! $mount_point =~ ^${HOME}/[^/]+/?$ ]]; then
		echo "Error. Mount point must be a full path directly under \$HOME."
		return 1
	elif [[ ! -f "$volume" ]]; then
		echo "Error. The volume $volume does not exist."
		return 1
	elif zuluMount-cli -l | grep -q "^$volume"; then
		# if try to mount an already mounted volume with zuluMout will get error:
		# "ERROR: Could not create mount point, invalid path or path already taken"
		# give an accurate message instead:
		echo "$volume is already mounted."
		return 0
	fi

	if [[ -d "$mount_point" ]]; then
		# zuluMount must make the mount point
		# (now a compile time switch to alter this)
		if ! rmdir "$mount_point" 2> /dev/null; then
			echo "Error. Files exist in mount point ${mount_point}."
			return 1
		fi
	elif [[ -e "$mount_point" ]]; then
		echo "Error. $mount_point exists and is not a directory."
		return 1
	fi

	# remove a trailing slash
	mount_point=$(echo "$mount_point" | sed "s;/$;;")
	# make up to the last dir of the mount path
	mkdir -p "${mount_point%/*}"
	# must be a member of zulumount group for -e
	# not actually necessary to remove $HOME
	# since zuluCrypt will only take last dir in the given path
	zuluMount-cli -m -e mount-prefix=home -d "$volume" \
		-z "${mount_point/$HOME\//}"
}

# give full path of volume as arg
# notes:
# get "ERROR: Close failed, volume is not open or was opened by a different user"
# when the reason is actually that the volume is in use
function umount_z() {
	if [[ -n "$1" ]]; then
		local volume
		local volume_full_path
		volume=$1
		volume_full_path=$(readlink -f "$volume")
		if zuluMount-cli -l | grep -q "^$volume_full_path"; then
			zuluMount-cli -u -d "$volume"
		else
			# prevent non-zero exit value if volume isn't mounted
			echo "$volume is not mounted."
		fi
	else
		echo "Unmount all non system volumes with zuluMount? (y/n)"
		confirm_do echo || return 1
		local non_system_volumes
		non_system_volumes=$(zuluMount-cli -N)
		while read -r volume; do
			zuluMount-cli -u -d "$volume"
		done <<< "$non_system_volumes"
	fi
}

# }}}

# Shared {{{
alias mountsoma='mount_tc ~/soma ~/ag-sys'
alias mountacct='mountsoma && mount_tc ~/ag-sys/else/ACCTS ~/blemish'
alias umountacct='umount_tc ~/ag-sys/else/ACCTS'
alias umountsoma='umount_tc ~/ag-sys/else/ACCTS && umount_tc ~/soma'

# sync ~/grive to google drive
alias sngdrive='cd ~/grive/ && grive --verbose'

# shared rsync flags
alias backup_rsync='rsync -avhmP --delete --delete-excluded --ignore-errors --prune-empty-dirs'

# minimal dotfiles/dev/school backup; for files that change quickly
function sndot() {
	 if mountsoma; then
		 backup_rsync --exclude={"musiclibrary.blb","bundle/*","elpa/*",".git/*","homepage/*",".mpd/log","mpdscribble.log",".mu/*",".mutt/cache/*","ppsspp/*","spacemacs/*",".vim/undo",".vim/thesaurus",".weechat/logs/*","windows/*",".zgen/*","*.gif","*.png"} ~/dotfiles ~/ag-sys/backup
		 backup_rsync ~/vimwiki ~/ag-sys/backup
		 backup_rsync --exclude={"old/*",".git/*"} ~/src/ ~/ag-sys/backup/src
		 backup_rsync ~/school/ ~/ag-sys/backup/current-school
	 else
		 return 1
	 fi
}

# }}}

# TC Volume Backup {{{

# get the path a tc volume is mounted to
# does not "return" directory with trailing slash
function get_tc_mount_point() {
	if [[ $# -ne 1 ]]; then
		echo "One argument is required:"
		echo "$ tc_volume_mounted_point /path/to/tc_vol"
		return 1
	fi
	local tc_volume
	tc_volume="$1"
	if [[ ! -f "$tc_volume" ]]; then
		echo "Error: file $tc_volume does not exist."
		return 1
	fi
	local tc_mount_dir
	tc_mount_dir=$(truecrypt --text --list --verbose "$tc_volume" | \
		awk -F ": " '/^Mount Directory/ {print $2}' 2> /dev/null)
	echo -n "$tc_mount_dir"
}

function sntcvol() {
	local no_eject
	no_eject=false
	while getopts :hn opt
	do
		case $opt in
			n) no_eject=true;;
			h) bkhelp ; return 0;;
			*) echo "invalid option" ; bkhelp ; return 1;;
		esac
	done
	if [[ $# -lt 2 ]]; then
		echo "Two positional arguments are required:"
		echo "$ sntcvol /path/to/tc_vol /path/to/backup_dir."
		return 1
	fi
	local tc_volume
	local backup_dir
	local tc_volume_name
	local backed_up_tc_volume
	tc_volume=${*: -2:1}
	backup_dir=${*: -1}
	# ensure trailing slash
	backup_dir=$(echo "$backup_dir" | sed -r "s;/?$;/;")
	tc_volume_name=$(basename "$tc_volume")
	backed_up_tc_volume=$backup_dir$tc_volume_name
	if [[ ! -f "$tc_volume" ]]; then
		echo "Error: file $tc_volume does not exist."
		return 1
	fi
	if [[ ! -d "$backup_dir" ]]; then
		echo "Error: directory $backup_dir does not exist."
		return 1
	fi
	echo "Using --delete with rsync. Continue? (y/n)"
	confirm_do echo "Continuing..." || return 1
	# if volume doesn't already exist, copy it over
	if [[ ! -f "$backed_up_tc_volume" ]]; then
		local tc_mount_dir
		tc_mount_dir=$(get_tc_mount_point "$tc_volume" 2> /dev/null)
		# unmount before copying entire container over
		umount_tc "$tc_volume" || return 1
		if backup_rsync "$tc_volume" "$backup_dir"; then
			echo "Backup of $tc_volume to $backup_dir completed succesfully."
		else
			echo "Backup of $tc_volume to $backup_dir failed."
			# don't return at this point
		fi
		# remount tc_volume if was previously mounted
		if [[ -n "$tc_mount_dir" ]]; then
			echo "Remounting $tc_volume to its previous mount point."
			mount_tc "$tc_volume" "$tc_mount_dir"
		fi
	else
		# don't remount volumes that are already mounted
		local tc_mount_dir
		local bk_tc_mount_dir
		local time_stamp
		local temp_backup_dir
		local unmount_main
		local unmount_backup
		tc_mount_dir=$(get_tc_mount_point "$tc_volume" 2> /dev/null)
		bk_tc_mount_dir=$(get_tc_mount_point "$backed_up_tc_volume" 2> /dev/null)
		time_stamp=$(date +%Y.%m.%d_%H:%M:%S)
		temp_backup_dir=$HOME/tc-backup-$time_stamp
		unmount_main=false
		unmount_backup=false
		if [[ -z "$tc_mount_dir" ]]; then
			tc_volume_full_path=$(readlink -f "$backed_up_tc_volume")
			tc_mount_dir=$temp_backup_dir$tc_volume_full_path
			mount_tc "$tc_volume" "$tc_mount_dir" || return 1
			unmount_main=true
		fi
		if [[ -z "$bk_tc_mount_dir" ]]; then
			bk_tc_volume_full_path=$(readlink -f "$backed_up_tc_volume")
			bk_tc_mount_dir=$temp_backup_dir$bk_tc_volume_full_path
			mount_tc "$backed_up_tc_volume" "$bk_tc_mount_dir" || return 1
			unmount_backup=true
		fi
		# add trailing slash (necessary for rsync source/from dir)
		if backup_rsync "${tc_mount_dir}/" "$bk_tc_mount_dir"; then
			echo "Backup of $tc_volume to $backup_dir completed succesfully."
			notify-send --icon=trophy-gold "Backup Notification" \
				"Backup of $tc_volume to $backup_dir completed succesfully."
		else
			echo "Backup of $tc_volume to $backup_dir failed."
			return 1
		fi
		# unmount volumes that weren't previously mounted
		if "$unmount_main"; then
			umount_tc "$tc_volume"
		fi
		if "$unmount_backup"; then
			umount_tc "$backed_up_tc_volume"
		fi
		# delete created mount point(s)
		find "$temp_backup_dir" -type d -empty -delete
	fi
	if ! $no_eject; then
		maybe_eject
	fi
}

# umountacct
alias snsoma='sndot && sntcvol ~/soma'
function bahamut() {
	if [[ $# -ne 1 ]]; then
		echo "One argument is required: "
		echo "$ bahamut <directory under /media to backup soma to>"
		return 1
	fi
	snsoma /media/"$1"
}

# }}}

# Database Backup {{{
alias mountdatab='mount_tc ~/datab ~/database'
alias umountdatab='umount_tc ~/datab'

alias sndatab='sntcvol ~/datab'
function sndb() {
	if [[ $# -ne 1 ]]; then
		echo "One argument is required:"
		echo "$ sndb <directory under /media/ to backup datab to>"
		return 1
	fi
	sndatab /media/"$1"
}

# }}}

# Online Backup {{{
# ~20mb volume
function snsmall() {
	mountsoma || return 1
	mount_tc ~/online_backup/small_soma ~/small_bk || return 1
	sndot
	backup_rsync --exclude={".Trash/*","gaming/*","large/*"} \
		--exclude={"chats/*","dotfiles/*","src/*"} \
		--include={"*/","*.txt","*.org","*.tex","*.md"}  \
		--exclude='*' ~/ag-sys/ ~/small_bk || return 1
	umount_tc ~/online_backup/small_soma || return 1
	# update modification time so will be accuate on places backed up to
	# using the timestamp mount option with truecrypt has no effect here (ext4)
	touch ~/online_backup/small_soma || return 1
	if SpiderOak --batchmode --backup="$HOME"/online_backup/small_soma; then
		echo "Minimal soma backup to Spideroak completed successfully."
		notify-send --icon=trophy-gold "Backup Notification" \
			"Minimal soma backup to Spideroak completed successfully."
	else
		echo "Minimal soma backup to Spideroak completed failed."
		notify-send --icon=error "Backup Notification" \
			"Minimal soma backup to Spideroak failed."
	fi
	# owncloud is pretty much instant for 20mb (in contrast to spideroak)
	if owncloudcmd ~/online_backup https://cloud.openmailbox.org/; then
		echo "Minimal soma backup to Spideroak completed successfully."
		notify-send --icon=trophy-gold "Backup Notification" \
			"Minimal soma backup to Openmailbox completed successfully."
	else
		echo "Minimal soma backup to Openmailbox failed."
		notify-send --icon=error "Backup Notification" \
			"Minimal soma backup to Openmailbox failed."
		return 1
	fi
}

# }}}

# home backup {{{
function snhome() {
	while getopts :h opt
	do
		case $opt in
			h) bkhelp ; return 0;;
			*) echo "invalid option" ; bkhelp ; return 1;;
		esac
	done
	if [[ $# -ne 1 ]]; then
		echo "One argument is required: /path/to/backup/dir"
		return 1
	fi
	echo "Using --delete with rsync. Continue? (y/n)"
	confirm_do echo "Continuing..." || return 1
	local backup_dir
	backup_dir="$1"
	# remove trailing slash
	backup_dir=$(echo "$backup_dir" | sed "s;/$;;")
	if [[ ! -d "$backup_dir" ]]; then
		echo "Error: directory $backup_dir does not exist."
		return 1
	fi
	local home_backup_dir
	home_backup_dir=$backup_dir/home_bk
	mkdir "$home_backup_dir" 2> /dev/null
	# if exclude *, won't transfer dir contents
	# by specifying /* (/ refering to the top of the from/source dir)
	# the contents of the included folders will be transferred (because of -r)
	backup_rsync --include-from="$HOME"/.zsh/rsync_home_dirs.txt \
		--exclude="/*" ~/ "$home_backup_dir"
	# not returning 1 for rsync because of possible failed to transfer att
	# and permission denied (to trash in .mozilla ..) errors

	# sync truecrypt volumes as well as well
	# don't sync under home_bk (so can keep --delete-excluded)
	sntcvol -n ~/soma "$backup_dir" || return 1
	sndatab "$backup_dir" || return 1
	echo "Home backup to $backup_dir completed successfully."
	notify-send --icon=trophy-gold "Backup Notification" \
		"Home backup to $backup_dir completed successfully."
 }

 # }}}

# psp backup {{{
# vita
alias cm="qcma --verbose"

# untested:
function snpsp() {
	while getopts :h opt
	do
		case $opt in
			h) bkhelp ; return 0;;
			*) echo "invalid option" ; bkhelp ; return 1;;
		esac
	done
	if [[ $# -ne 1 ]]; then
		echo "One argument is required:"
		echo "$ snpsp /path/to/psp/memcard"
		return 1
	fi
	echo "Using --delete with rsync. Continue? (y/n)"
	confirm_do echo "Continuing..." || return 1
	local psp_dir
	# remove trailing slash
	psp_dir=$(echo "$psp_dir" | sed "s;/$;;")
	if [[ ! -d $psp_dir ]];then
		echo "Error. Directory $psp_dir does not exist."
		return 1
	 fi
	mountdatab || return 1
	# don't backup large games but do backup their names
	tree "$psp_dir"/ISO > "$psp_dir"/isos.txt
	ls "$psp_dir"/PSP/GAME/PSX > "$psp_dir"/psx.txt
	# trailing slash is important
	if backup_rsync --exclude={"ISO/*","PSX/*"} \
		"$psp_dir"/ ~/database/gaming/psp/backup/; then
		echo "Backup of psp memcard at $psp_dir to database completed succesfully."
		notify-send --icon=trophy-gold "Backup Notification" \
			"Backup of psp memcard at $psp_dir to database completed succesfully."
	else
		echo "Backup of psp memcard at $psp_dir to database failed."
		notify-send --icon=trophy-gold "Backup Notification" \
			"Backup of psp memcard at $psp_dir to database failed."
		return 1
	fi
 }

 # }}}