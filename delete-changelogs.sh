#!/bin/bash

master_vol=""
sec_vol=""
dest_node=""
brick_path=""
DRYRUN=""

function cleanup {
	/usr/bin/env rm -f $changelog_file $delete_list $processed_changelogs
	/usr/bin/env umount /var/tmp/gluster_cleanup
	/usr/bin/env rmdir /var/tmp/gluster_cleanup
}

function validate {
if [ -z "$brick_path" ] || [ -z "$dest_node" ] || \
	[ -z "$master_vol" ] || [ -z "$sec_vol" ]
	
	then
		echo "One or more parameters are missing.Run $0 --help for details" >&2
		exit 2
fi
}

# Parse all parameters for later usage
while [[ $# -gt 0 ]]; do
	case $1 in 
		-b|--brick_path)
			brick_path="$2"
			shift # past argument
			shift # past value
			;;
		-d|--destination_node)
			dest_node="$2"
			shift # past argument
			shift # past value
			;;
		-m|--master_volume)
			master_vol="$2"
			shift # past argument
			shift # past value
			;;
		-n|--dry-run)
	                DRYRUN="/usr/bin/env echo"
			shift
			shift
	                ;;
		-s|--secondary_volume)
			sec_vol="$2"
			shift # past argument
			shift # past value
			;;
		*)
			echo "USAGE:"
			echo "-b|--brick_path         - Path to the locally mounted brick"
			echo "-d|--destination_node   - The name of the node that was used for establishing the geo-rep on the secondary site"
			echo "-m|--master_volume      - The name of the volume on the primary side (source)"
			echo "-s|--secondary_volume   - The name of the secondary volume (target side)"
			echo "-n|--dry-run            - Dry run mode makes all steps except the deletion"
	
			exit 0
			;;
	esac
done

# Assign the var after brick_path var was assigned
brick_path_dashes=$(/usr/bin/env echo $brick_path | /usr/bin/env sed 's#/##' | /usr/bin/env sed 's#/#-#g')

# Validate that all  parameters have a value
validate 


# We are using the processed files located at:
#/var/lib/misc/gluster/gsyncd/${master_vol}_${dest_node}_${sec_vol}/${brick_path_dashes}/.processed

# We are using tmpfs as processing is faster
/usr/bin/env mkdir /var/tmp/gluster_cleanup
#TMPFS is hardcoded to 100M as we don't need much space
/usr/bin/env mount -t tmpfs -o size=100M - /var/tmp/gluster_cleanup

# Temp files which will be cleaned up on exit, ctrl+C ,etc
changelog_file=$(mktemp /var/tmp/gluster_cleanup/changeloglist.XXXXXX)
delete_list=$(mktemp /var/tmp/gluster_cleanup/todelete.XXXXXX)
processed_changelogs=$(mktemp /var/tmp/gluster_cleanup/processed.XXXXXX)


# Actual code that captures exit/Ctrl+C,etc
trap cleanup EXIT SIGINT SIGKILL SIGQUIT SIGTERM

# Get all changelogs locally and store them into $changelog_file
# Changelogs are different per host
/usr/bin/env ionice -c 2 -n 7 /usr/bin/env find ${brick_path}/.glusterfs/changelogs/$(date '+%Y')/  -type f -name "CHANGELOG.*" -print > ${changelog_file}

#Obtain all processed changelogs
PROCESSED_LOCALLY=$(/usr/bin/env ionice -c 2 -n 7 /usr/bin/env find /var/lib/misc/gluster/gsyncd/${master_vol}_${dest_node}_${sec_vol}/${brick_path_dashes}/.processed/ -type f -name "archive*.tar" |  wc -l)

if [ "$PROCESSED_LOCALLY" -gt 0 ]; then

	/usr/bin/env tar -tvf /var/lib/misc/gluster/gsyncd/${master_vol}_${dest_node}_${sec_vol}/${brick_path_dashes}/.processed/archive_*.tar | /usr/bin/env awk '{print $6}' | /usr/bin/env head -n -5 >> ${processed_changelogs}

else
	/usr/bin/env echo "No changelogs were processed locally!" >&2
	exit 0
fi

# Iterating over the 2 lists will allow us to match the full path of the CHANGELOG without issuing multiple finds
# In the end if a changelog that was in the .proccessed/archive_<year><month>.tar, we can safely delete it
# So we add it to a list of files that can be deleted
while read changelog; do 
	/usr/bin/env grep $changelog ${changelog_file}
done < ${processed_changelogs}  >> ${delete_list}

# This is just for info in case you are interested how many changelogs we got and how many were processed
CHANGELOG_FILE_COUNT=$(wc -l $changelog_file | awk '{print $1}')
ENTRIES_TO_DELETE=$(wc -l $delete_list | awk '{print $1}')

/usr/bin/env echo "CHANGELOG FILE COUNT: $CHANGELOG_FILE_COUNT"
if [ -z "$DRYRUN" ]; then
	/usr/bin/env echo "ENTRIES THAT ARE NOW DELETED: $ENTRIES_TO_DELETE"
else
	/usr/bin/env echo "ENTRIES NOT DELETED: $ENTRIES_TO_DELETE"
fi

# If no logs have to be deleted , we skip
if [ "$ENTRIES_TO_DELETE" -gt 0 ]; then
	$DRYRUN	/usr/bin/env xargs --arg-file="$delete_list" rm
else
	/usr/bin/env echo "Nothing to do!"
fi
