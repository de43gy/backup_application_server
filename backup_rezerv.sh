#!/bin/bash
#backup_mysql.sh v3.0 - Database backup files copied to the application and backup server

#==========
#VARIABLES
#==========

#variables to configure script
PATH_TO_BACKUP="/backUp/mysql_bases/" #the path to the backup archives
PATH_TO_LOGS="/var/log/backup_mysql/" #the path to the directory with logs
NUMBER_OF_COPIES="10" #number of files to backup, stored on the server

#over variables, constants and generated during launch script
FILE_BACKUP_STATUS="status_backup.inf" #file for information to Nagios
FILE_BACKUP_LOG=$PATH_TO_LOGS$(date +%Y%m)$HOSTNAME.log #name for the backup file 
PATH_FILE_BACKUP_STATUS=$PATH_TO_LOGS$FILE_BACKUP_STATUS #path to the file with the information for Nagios
VARIABLELIST=("COPY_TO_LTO" "FILEMARK" "NUM_BACKUP_FILES" "HOURS_LAST_FILE") #Variables for Nagios
BACKUP_FILE=$(date +%Y%m%d%H%M)$HOSTNAME".tar" #name of the archive backup

#==========================================
#DEFINITION OF FUNCTIONS
#==========================================

#change variables in status_backup.inf: $1 - name of variable, $2 value of variable
function change_status_file {
	PART1="perl -i -p -e "
	LINEFORPERL=$(echo "'s/"$1"=.*/"$1"="$2"/'")
	TORUN=$PART1$LINEFORPERL" "$PATH_FILE_BACKUP_STATUS
	eval $TORUN
} 

#send message to log: $1 0=INFO/1=WARNING/2=ERROR, $2 description, $3 result of the operation
function send_to_log {
	STATUS_TO_LOG=(INFO WARNING ERROR)
	echo $(date +%Y%m%d%H%M)":"${STATUS_TO_LOG[$1]}":"$2":"$3 >> $FILE_BACKUP_LOG
}

#tape recording
function file_to_LTO {
	STRIMER_FILES_NUM=$(mt -f /dev/st0 status | awk '/File/ {if(sub(/,/,""))if(sub(/number=/,"")){print $2}}') #position on the 
	if tar -cvf /dev/nst0 $PATH_TO_BACKUP$1 #copy file to LTO
	then
		FILEMARK=$(mt -f /dev/nst0 status | sed -rn 's/^File number=([0-9]+).*/\1/p')
		send_to_log "0" "tape recording OK" $1
		send_to_log "0" "File number=" $FILEMARK
		change_status_file "COPY_TO_LTO" "0"
		change_status_file "FILEMARK" $FILEMARK
	else
		FILEMARK=$(mt -f /dev/nst0 status | sed -rn 's/^File number=([0-9]+).*/\1/p')
		send_to_log "1" "tape recording ERROR" $1
		change_status_file "COPY_TO_LTO" "1"
		change_status_file "FILEMARK" $FILEMARK
	fi
}


#==========================================
#START BACKUP
#==========================================

send_to_log "0" "<<!!!BACKUP STARTING!!!>>"
change_status_file "COPY_TO_LTO" "1"

#=========================================
#CHECK THE NECESSARY FILES AND DIRECTORIES
#==========================================
  
#check the file status_backup.inf, check for variables and create file an variables if they do not
if [ -f $PATH_FILE_BACKUP_STATUS ];
then #if file exist
	NUM_ALL_VARIABLE=${#VARIABLELIST[@]}
	NUM_FIND_VARIABLE="0"
	while [ "$NUM_FIND_VARIABLE" -lt "$NUM_ALL_VARIABLE" ] #check if there the variables in it
	do
		WORLD="awk -F \"=\" '/"${VARIABLELIST[$NUM_FIND_VARIABLE]}"/ { print \$1 }' $PATH_FILE_BACKUP_STATUS"
		CHEC_VAR=$(eval $WORLD) #this null if variable not found
		if [ -z "$CHEC_VAR" ] #if CHEC_VAR = null, adding the line with a variable to a file
		then
			echo ${VARIABLELIST[$NUM_FIND_VARIABLE]}"=null" >> $PATH_FILE_BACKUP_STATUS
			send_to_log "1" "missing variable in file" ${VARIABLELIST[$NUM_FIND_VARIABLE]}
		fi
	let NUM_FIND_VARIABLE++ 
	done
else #if the file does not exist, it is created
	send_to_log "1" "missing file status_backup.inf"
	touch $PATH_FILE_BACKUP_STATUS #created empty file
	for i in ${VARIABLELIST[@]};
	do
		send_to_log "1" "missing variable in file" $i
		echo $i"=null" >> $PATH_FILE_BACKUP_STATUS
	done
fi

#==================================================================
#DELETING OLD FILES AND DETERMINING THE SIZE OF THE ENTIRE ARCHIVE
#==================================================================

#couting the number of files and delete old
FILELIST=($(ls -t $PATH_TO_BACKUP))
while [ "${#FILELIST[@]}" -gt "$NUMBER_OF_COPIES" ]
do
	if rm -f $PATH_TO_BACKUP${FILELIST[${#FILELIST[@]}-1]}
	then 
		send_to_log "0" "removed the old backup file" "${FILELIST[${#FILELIST[@]}-1]}"
		unset FILELIST[${#FILELIST[@]}-1]
	else
		send_to_log "2" "error when deleting a file" "${FILELIST[${#FILELIST[@]}-1]}"
		break 2
	fi
done

#check and record in the log
FILELIST=($(ls -t $PATH_TO_BACKUP)) #add backup files to the array
((HOURS_LAST_FILE=$(date -r $PATH_TO_BACKUP${FILELIST[0]} +%s)/3600)) #counting how many hours have passed since the file was created
change_status_file "HOURS_LAST_FILE" $HOURS_LAST_FILE
change_status_file "NUM_BACKUP_FILES" ${#FILELIST[@]}
send_to_log "0" "the number of backup files" ${#FILELIST[@]}
send_to_log "0" "directory size of backup" $(du -hs $PATH_TO_BACKUP)

#============================================
#STATUS OF THE TAPE DRIVE AND TAPE RECORDING
#============================================
if ERROR_CODE=$(mt -f /dev/nst0 status | egrep -o '\([0-9]{1,15}\)')
then
	case $ERROR_CODE in		
	"(41010000)" ) #Strimmer ONLINE, Tape is positioned at the beginning of the first filemark - WARNING
		file_to_LTO ${FILELIST[0]}
	;;
	"(50000)" ) #Strimmer ONLINE, Tape unloaded
		send_to_log "1" "file was not copied to LTO" $ERROR_CODE
		change_status_file "COPY_TO_LTO" "1"
	;;
	"(45010000)" ) #Strimmer ONLINE, Tape is write-protected check cartridge and use tape cleaner
		send_to_log "1" "file was not copied to LTO" $ERROR_CODE
		change_status_file "COPY_TO_LTO" "1"
	;;
	"(81010000)" ) #Strimmer ONLINE, Tape is positioned at the end of last filemark
		file_to_LTO ${FILELIST[0]}
	;;
	"(89010000)" ) #Strimmer ONLINE, Tape is positioned at the end of last filemark, at the end of data
		send_to_log "1" "file was not copied to LTO" $ERROR_CODE
		change_status_file "COPY_TO_LTO" "1"
	;;
	"(1010000)" ) #???
		send_to_log "1" " " $ERROR_CODE
		
	* ) #Uncnow ERROR
		send_to_log "1" "file was not copied to LTO" "Uncnow ERROR"
		change_status_file "COPY_TO_LTO" "1"
	;;
	esac
else #Uncnow ERROR or LTO offline
	send_to_log "2" "file was not copied to LTO" "LTO offline"
	change_status_file "COPY_TO_LTO" "1"
fi

#==========================================
#END BACKUP
#==========================================

send_to_log "0" "<<!!!BACKUP IS COMPLETE!!!>>"
DATEBACKUP=$(date +%d)"."$(date +%m)
change_status_file DATEBACKUP $DATEBACKUP

exit 0
