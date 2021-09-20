#!/bin/bash

source_vol="primevol"
dest_vol="slavevol"
dest_node="slave1"
brick_path="/gluster/brick1/brick1"
brick_path_dashes=$(echo $brick_path | sed 's#/##' | sed 's#/#-#g')


while [[ $# -gt 0 ]]; do
	case $1 in 
		-d|--dry-run)
	                DRYRUN="/bin/echo"
	                ;;
		*)
			echo "You can use -d or --dry-run to test the script without deleting any changelogs!"
			exit 0
			;;
	esac
done

# We are using the processed files located at:
#/var/lib/misc/gluster/gsyncd/${source_vol}_${dest_node}_${dest_vol}/${brick_path_dashes}/.processed

# We are using tmpfs as processing is faster
mkdir /var/tmp/gluster_cleanup
#TMPFS is hardcoded to 100M as we don't need much space
mount -t tmpfs -o size=100M - /var/tmp/gluster_cleanup

# Temp files which will be cleaned up on exit, ctrl+C ,etc
changelog_file=$(mktemp /var/tmp/gluster_cleanup/changeloglist.XXXXXX)
delete_list=$(mktemp /var/tmp/gluster_cleanup/todelete.XXXXXX)
processed_changelogs=$(mktemp /var/tmp/gluster_cleanup/processed.XXXXXX)

function cleanup {
	rm -f $changelog_file $delete_list $processed_changelogs
	umount /var/tmp/gluster_cleanup
	rmdir /var/tmp/gluster_cleanup
}

# Actual code that captures exit/Ctrl+C,etc
trap cleanup EXIT SIGINT SIGKILL SIGQUIT SIGTERM

# Get all changelogs locally and store them into $changelog_file
# Changelogs are different per host
ionice -c 2 -n 7 find ${brick_path}/.glusterfs/changelogs/$(date '+%Y')/  -type f -name "CHANGELOG.*" -print > ${changelog_file}

#Obtain all processed changelogs
PROCESSED_LOCALLY=$(ionice -c 2 -n 7 find /var/lib/misc/gluster/gsyncd/${source_vol}_${dest_node}_${dest_vol}/${brick_path_dashes}/.processed/ -type f -name "archive*.tar" |  wc -l)

if [ "$PROCESSED_LOCALLY" -gt 0 ]; then

	tar -tvf /var/lib/misc/gluster/gsyncd/${source_vol}_${dest_node}_${dest_vol}/${brick_path_dashes}/.processed/archive_*.tar | awk '{print $6}' | head -n -5 >> ${processed_changelogs}

else
	echo "No changelogs were processed locally!" >&2
	exit 0
fi

# Iterating over the 2 lists will allow us to match the full path of the CHANGELOG without issuing multiple finds
# In the end if a changelog that was in the .proccessed/archive_<year><month>.tar, we can safely delete it
# So we add it to a list of files that can be deleted
while read changelog; do 
	grep $changelog ${changelog_file}
done < ${processed_changelogs}  >> ${delete_list}

# This is just for info in case you are interested how many changelogs we got and how many were processed
CHANGELOG_FILE_COUNT=$(wc -l $changelog_file | awk '{print $1}')
ENTRIES_TO_DELETE=$(wc -l $delete_list | awk '{print $1}')

echo "CHANGELOG FILE COUNT: $CHANGELOG_FILE_COUNT"
echo "ENTRIES TO DELETE: $ENTRIES_TO_DELETE"

# If no logs have to be deleted , we skip
if [ "$ENTRIES_TO_DELETE" -gt 0 ]; then
	$DRYRUN	xargs --arg-file="$delete_list" rm
else
	echo "Nothing to do!"
fi
