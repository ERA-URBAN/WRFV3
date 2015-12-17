#!/bin/bash

# abort on any error (ie. non-zero exit status)
set -e

# setup the environment on the Cartesius
if [ `hostname | grep -i sara` ]; then
    module load python
    module load nco
    module load ncl
fi

# Uncomment following line for debug mode
#set -xv

###########################3
# Forecast config:

CYCLESTEP=6        # time between two forecast runs in hours
CYCLELEN=6         # length of a forecast run in hours
BOUNDARYINTERVAL=6  # time between boundaries, in hours

# Index in netCDF file to use for copy_cycle
CYCLEINDEX[01]=9
CYCLEINDEX[02]=25
CYCLEINDEX[03]=25
CYCLEINDEX[04]=25

# fields to cycle from previous run
URBANFIELDS="TC_URB,TR_URB,TB_URB,TG_URB,TS_URB,TRL_URB,TBL_URB,TGL_URB"
CYCLEFIELDS="TSLB,SMOIS,SH2O,SMCREL,CANWAT,TSK"

# location of configuration file
CONFIG=/home/WUR/haren009/forecast.config

# working directories
#DATDIR=/data/GFS
DATDIR=/home/WUR/haren009/sources/ERA_URBAN/scripts/boundaries/ERAI
WPSDIR=/home/WUR/haren009/sources/WPS
RUNDIR=/home/WUR/haren009/sources/WRFV3/run
#ARCDIR=/home/jattema/archive
ARCDIR=/home/WUR/haren009/data/archive
WRFDADIR=/home/WUR/haren009/sources/WRFDA
OBSDIR=/home/WUR/haren009/sources/ERA_URBAN/scripts/netcdf2littler
WORK_DIR=${WRFDADIR}/workdir
# location of external tools
NCDUMP=ncdump
NC3TONC4=nc3tonc4
TOOLS=/home/WUR/haren009/sources/WRFV3/tools/forecast
NAMELIST=$TOOLS/namelist.py
COPYSST=$TOOLS/copy_sst_init.sh
PREPSST=$TOOLS/prepare_sst.sh


##################################
# FIXME read from config file
##################################


MANUAL="
Control WRF forecast runs.

   $0 command option

download_gfs:  Download GFS boundaries from NCEP.

prepare:
  all          Runs all prepare steps in order, for cycling.
  date  <date> Set the datetime for the run, also accepts special date 'next', 
  boundaries   run ungrib, metgrid
  cycle <date> Copy cycle fields from the specified run, also accepts special date 'previous'
  sst <date>   Set river and sea surface temperature, defaults to yesterday

run:
  all
  real         Run real.exe
  wrf          Queue the run for execution

wrfda:
  preprocess <date>  Preprocess observations for data assimilation
  prepare <date>     Symlink all input files for data assimilation
  run                Run WRFDA
  updatebc           Update boundary conditions
  updatebc_lowbc <date> Update lower boundaries only

zip:
  all 
  ts           Zip TS files
  netcdf       Convert netCDF output to netCDF-4 format with compression
  log          Zip WRF log files

archive:
  all
  ts           Copy TS files to archive dir
  netcdf       Copy netCDF to archive dir
  log          Copy log file to archive dir

clean:
  all 
  input        Remove WRF boundaries
  output       Remove all WRF output files

plot:
  surface1     Make surface plots using script number one.

status         Print forecast status
"

# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
#                    U  T  I  L  I  T  Y     F  U  N  C  T  I  O  N  S 
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

######################################################################
# Repeat a string str count times, using. Output is comma separated: `repeat 'x' 3` = "x,x,x,"
# Arguments:
#    str       string to repeat
#    count     number of times to repeat it 
######################################################################
function repeat {
    str=$1
    count=$2
   
    printf "%${count}s" | sed "s/ /${str},/g"
}

######################################################################
# Write a log message to the CONFIG file
# Arguments:
#    message   Mesage to write
######################################################################
function log {
    message=$1

    stamp=`date -u +"[%s] %F %T"`
    printf '%s : %s\n' "$stamp" "$message" >> "$CONFIG"
}

######################################################################
# Split a date given as YYYY.MM.DD into year, month, and day
# Arguments:
#    date     Date to parse
#    year     (return) name of output variable for the year
#    month    (return) name of output variable for the month
#    day      (return) name of output variable for the day
######################################################################
function splitdate {
    dateregex="([0-9][0-9][0-9][0-9]).([0-9][0-9]).([0-9][0-9]).([0-9][0-9])"
    if [[ ! "$1" =~ $dateregex ]]; then
        printf "$0 [$LINENO]: No valid date given. Aborting.\n"
        exit 1
    fi
    if [[ $# != 5 ]]; then
        printf "$0 [$LINENO]: splitdate needs exactly 4 arguments, not $#. Aborting.\n"
        exit 1
    fi

    eval "$2='${BASH_REMATCH[1]}'"
    eval "$3='${BASH_REMATCH[2]}'"
    eval "$4='${BASH_REMATCH[3]}'"
    eval "$5='${BASH_REMATCH[4]}'"
}

######################################################################
# List all available tslist files for a given station and domain
# Required env:
#    RUNDIR
# Argument:
#    station
#    domain
######################################################################
function ls_tslist {
    station=$1
    domain=$2

    # suffixes for the ts files
    SX="(PH|QV|TH|TS|UU|VV)"

    RX=`printf '%s.d%02.0f.%s' $1 $2 $SX`

    ls -1 $RUNDIR | grep -P $RX || echo ""
}

######################################################################
# Return a list of boundary filenames for the ECMWF operational analysis
# Required env:
#    BOUNDARYINTERVAL, CYCLELEN
# Arguments:
#    DATE      starting date in a format accepted by date
#    FILES     (return) variable that will be set to required files
######################################################################
function boundary_list_ecmwf_opan {
    if [[ -z "$BOUNDARYINTERVAL" || -z "$CYCLELEN" ]]; then
        printf "$0 [$LINENO]: BOUNDARYINTERVAL or CYCLELEN not set. Aborting\n"
        exit -1
    fi;

    start=$1
    out=$2

    LIST=""
    for i in `seq 0 $BOUNDARYINTERVAL $CYCLELEN`; do

        YMD=`date --date "$start $i hours" +%Y%m%d`
        HM=`date --date "$start $i hours" +%_k | tr -d ' '`
        if [[ "$HM" != "0" ]]; then
            HM=${HM}00
        fi
        LIST="$LIST $DATDIR/AN${YMD}${HM}sig"
    done

    eval "$out='${LIST}'"
}

######################################################################
# Initialize the forecast script
# Parses the namelist file and sets NDOMS, DATESTART, and STATIONS
# Required env:
#    NAMELIST, RUNDIR 
######################################################################
function forecastinit {
    if [[ -z "$NAMELIST" || -z "$RUNDIR" ]]; then
        printf "$0 [$LINENO]: NAMELIST or RUNDIR not set. Aborting\n"
        exit -1
    fi;

    NDOMS=`$NAMELIST --get domains:max_dom "$RUNDIR/namelist.input"`
    START_Y=`$NAMELIST --get time_control:start_year:0  "$RUNDIR/namelist.input"`
    START_M=`$NAMELIST --get time_control:start_month:0 "$RUNDIR/namelist.input"`
    START_D=`$NAMELIST --get time_control:start_day:0   "$RUNDIR/namelist.input"`
    DATESTART=`printf '%4i-%02i-%02i' ${START_Y} ${START_M} ${START_D}`

    if [ -f $RUNDIR/tslist ]; then
        STATIONS=`cat $RUNDIR/tslist | awk '{print $2}'`
    else
        printf "$0 [$LINENO]: Can't open tslist file!\n"
        STATIONS=""
    fi
}

######################################################################
# Check GRIB edition number of ECMWF files, 
# and convert to GRIB1 if necessary
# This will overwrite the original file
# Arguments:
#    FILES  List of files to process
######################################################################
function check_grib_version {
    if [ -z "$1" ]; then
        printf "$0 [$LINENO]: No files given, aborting\n"
        exit -1
    fi;

    F=$1
    while [ ! -z "$F" ]; do
        if [ ! -f "$F" ]; then
            printf "$0 [$LINENO]: File not found: $F, aborting\n"
            exit -1
        fi
        if [[ `grib_ls "$F" | grep  -P '^2 *ecmf'` ]]; then
            # Convert to GRIB1
            grib_set -f -s editionNumber=1 "${F}" "${F}.grib1" > /dev/null 2>&1
            mv -f "${F}.grib1" "${F}"
        fi
        shift
        F=$1 
    done
}


######################################################################
# Create the archive dir for the given date; date as YYYY-MM-DD
# Dir is returned in the second argument $2, so use like this
# archivedir 2014-01-01 ARCDIR
######################################################################
function archivedir {

    # Construct archive directory name
    splitdate $1 YEAR MONTH DAY HOUR
    DEST=$ARCDIR/$YEAR/$MONTH/$DAY

    # Create it
    mkdir -p $DEST

    # return it in the second argument
    eval "$2='$DEST'"
}




# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
#                    F  o  r  e c  a  s  t     c  o  m  m  a  n  d  s 
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-



######################################################################
# Print help and exit
######################################################################
function help {
    printf '%s\n' "$MANUAL"
}


######################################################################
# Determine forecast status
######################################################################
function status {
    echo "Date start: $DATESTART"
    echo "NDOMS:      $NDOMS"

    # Check archive status
    archivedir $DATESTART ARCHIVE

    echo '------------------------------'
    echo 'Archive status'
    echo '------------------------------'
    echo -n "LOGS        "
    if [[ -f "$ARCHIVE/logs_${DATESTART}.zip" ]]; then
        echo done
    else
        if [[ -f "$RUNDIR/logs_${DATESTART}.zip" ]]; then
            echo "run archive log"
        else
            echo .
        fi
    fi

    # check if the wrfout*nc files are archived...
    echo -n "NETCDF:     " 
    if [[ `ls $ARCHIVE/wrfout*nc 2> /dev/null | wc -l` == $NDOMS ]]; then
        echo done
    else
        # ... or if we can do archive netcdf
        if [[ `ls $RUNDIR/wrfout*nc 2> /dev/null` ]]; then
            echo "run archive netcdf"
        else
            echo .
        fi
    fi

    # As the number of time series files depends on if the stations are within which nested sub domains
    # we cannot easily find out how many there should be
    echo -n "TS:         "
    if [ -f $RUNDIR/tslist ]; then
           
        # are there already some files archived?
        if [[ `ls $ARCHIVE/*.d??.zip 2>/dev/null` ]]; then

            # ...are there still files to archive?
            if [[ `ls $RUNDIR/*.d??.zip 2>/dev/null` ]]; then
                echo "run archive ts"
            else
                echo done
            fi
        else       
            # ...are there files to archive?
            if [[ `ls $RUNDIR/*.d??.zip 2>/dev/null` ]]; then
                echo "run archive ts"
            else
                echo .
            fi
        fi
    else
        echo "no tslist"
    fi

    echo '------------------------------'
    echo 'Zip status'
    echo '------------------------------'

    echo -n "LOGS:       "
    if [[ -f $RUNDIR/rsl.out.0000 || -f $RUNDIR/rsl.out ]]; then
         echo "run zip log"
    elif [[ -f "$RUNDIR/logs_${DATESTART}.zip" ]]; then
         echo done
    else
         echo .
    fi

    echo -n "NETCDF:     " 
    if [[ "$NDOMS" == `ls $RUNDIR/wrfout*nc 2>/dev/null | wc -l` ]]; then
        echo done
    else
        # check if the wrfout_d* files exist
        if [[ `ls $RUNDIR/wrfout_d* 2> /dev/null | grep -v nc` ]]; then
            echo "run zip netcdf"
        else
            echo .
        fi
    fi

    echo -n "TS:         "
    foundts="no"
    foundtszip="no"
    for s in $STATIONS; do
        for d in `seq 1 $NDOMS`; do

            # Check for un-zipped files
            FILES=`ls_tslist $s $d`
            for F in $FILES; do
                if [ -f $F ]; then
                    foundts="yes"
                fi
            done

            # Check for zip archive
            ZIPPED=${s}.d${d}.zip
            if [ -f $ZIPPED ]; then
                foundtszip="yes"
            fi

        done
    done
    if [ $foundts == "yes" ]; then
        echo "run zip ts"
    else
        if [ $foundtszip == "yes" ]; then
            echo "done"
        else
            echo .
        fi
    fi

    echo '------------------------------'
    echo 'Run status'
    echo '------------------------------'

    # output filename depends on parallel / serial run
    if [ -f rsl.out.0000 ]; then
        OUT="rsl.out.0000"
    elif [ -f rsl.out ]; then
        OUT="rsl.out"
    fi

    NEEDLE="SUCCESS COMPLETE REAL_EM INIT"
    BDY="not done"
    grep "${NEEDLE}" prepare_boundaries.log 1>/dev/null 2>&1 && BDY="done"

    # Test for the wrfbdy_d?? and wrfinput_d??.
    # They should always be present for d01, but it depends on the nesting feedback setup if they are required for the other domains.
    if [[ ! -f wrfbdy_d01  || ! -f wrfinput_d01 ]]; then
        BDY="not done"
    fi

    WRF="not done"
    NEEDLE="SUCCESS COMPLETE WRF"
    grep "SUCCESS COMPLETE WRF" "$OUT" 1>/dev/null 2>&1 && WRF="done"

    echo -n "REAL:       "
    if [ "$BDY" == "done" ]; then
        echo "done"
    else
        echo "."
    fi

    echo -n "WRF:        "
    if [ "$WRF" == "done" ]; then
        echo "done"
    else 
        if [ "$BDY" == "done" ]; then
            echo "run wrf"
        else
            echo "."
        fi
    fi

    echo '------------------------------'
    echo 'Boundary status'
    echo '------------------------------'

echo
    
}


######################################################################
# Move TS files to the archive
#
# Assumes:
#    tslist is in $RUNDIR
# Required env:
#    ARCDIR, RUNDIR, DATESTART, NDOMS
######################################################################
function archive_ts {
    if [[ -z "$NDOMS" || -z "$DATESTART" || ! -d "$ARCDIR" || ! -d "$RUNDIR" ]]; then
        printf "$0 [$LINENO]: NDOMS, DATESTART, ARCDIR, or RUNDIR not set. Aborting\n"
        exit -1
    fi;

    # Get the archive directory for this run
    archivedir $DATESTART DEST

    for d in `seq -f '%02.0f' 1 $NDOMS`; do
        for s in $STATIONS; do

            ZIPPED=${s}.d${d}.zip
            if [ -f $RUNDIR/$ZIPPED ]; then
                cp $RUNDIR/$ZIPPED $DEST
                rm -f $RUNDIR/$ZIPPED
            fi
        done
    done
}

######################################################################
# Move netCDF files to the archive
#
# Required env:
#    ARCDIR, RUNDIR, DATESTART, NDOMS
######################################################################
function archive_netcdf {
    if [[ -z "$NDOMS" || -z "$DATESTART" || ! -d "$ARCDIR" || ! -d "$RUNDIR" ]]; then
        printf "$0 [$LINENO]: NDOMS, DATESTART, ARCDIR, or RUNDIR not set. Aborting\n"
        exit -1
    fi;

    # Get the archive directory for this run
    archivedir $DATESTART DEST

    for d in `seq -f '%02.0f' 1 $NDOMS`; do
        NCDF4="wrfout_d${d}_${DATESTART}_00:00:00.nc" 
        cp $RUNDIR/$NCDF4 $DEST
        rm -f $RUNDIR/$NCDF4
    done
}

######################################################################
# Move log files to the archive
#
# Required env:
#    ARCDIR, RUNDIR, DATESTART, NDOMS
######################################################################
function archive_log {
    if [[ -z "$NDOMS" || -z "$DATESTART" || ! -d "$ARCDIR" || ! -d "$RUNDIR" ]]; then
        printf "$0 [$LINENO]: NDOMS, DATESTART, ARCDIR, or RUNDIR not set. Aborting\n"
        exit -1
    fi;

    # Get the archive directory for this run
    archivedir $DATESTART DEST

    LOGS="logs_${DATESTART}.zip"

    if [ -f $RUNDIR/$LOGS ]; then
        cp $RUNDIR/$LOGS $DEST
        rm -f $RUNDIR/$LOGS
    else
        printf "$0 [$LINENO]: Cannot archive logs. Aborting\n"
        exit -1
    fi
}

######################################################################
# Remove all input files from a WRF run,
# after a 'clean input', a 'prepare all' must be run
#
# Assumes:
#    CWD is the 'wrf' run directory
######################################################################
function clean_input {

    # starting state and boundaries
    # -----------------------------

    rm -f wrfinput*
    rm -f wrfbdy*    
    rm -f met_em.d??.????-??-??_??:??:??.nc

    # logs
    # ----

    rm -f prepare_boundaries.log
}

######################################################################
# Remove all output files from a WRF run,
# after a 'clean output' the WRF forecast can be resubmitted
#
# Assumes:
#    CWD is the 'wrf' run directory
######################################################################
function clean_output {
    FORCE=$1

    # log files
    # -------------------------

    rm -f rsl.out
    rm -f rsl.out.*
    rm -f rsl.error.*
    rm -f logs_${DATESTART}.zip

    # wrfout
    # ------------------------

    rm -f wrfout*

    # time series
    # -----------

    if [ -f tslist ]; then

        for d in `seq -f '%02.0f' 1 $NDOMS`; do
            for s in $STATIONS; do
                rm -f ${s}.d${d}.*
            done
        done
    else
        printf "$0 [$LINENO]: Can't open tslist file, time series not removed\n"
    fi
}

######################################################################
# Modifies the namelist.input and namelist.wps to for the requested date
# Arguments:
#      $1   The date as YYYY-MM-DD or 'next'
#
# When 'next' is given, CYCLESTEP is added to the start date from the namelist.
#
# Required env:
#    NDOMS
######################################################################
function prepare_date {
    if [[ -z "$NDOMS" ]]; then
        printf "$0 [$LINENO]: NDOMS not set, aborting\n"
        exit 1;
    fi

    if [ ! "$1" ]; then
        printf "$0 [$LINENO]: No valid date or 'next' given, aborting\n"
        exit 1;
    fi

    if [ "next" == $1 ]; then
        splitdate $DATESTART YEAR MONTH DAY HOUR
        DATESTART=`date --date "${YEAR}-${MONTH}-${DAY} ${HOUR} hours $CYCLESTEP hours" +%F.%H`
    elif [ "today" == $1 ]; then
        DATESTART=`date +%F%H`
    else
        DATESTART=$1
    fi
    
    # namelist.input 
    # namelist.wps   (Format: 2006-08-16_12:00:00)
    # --------------------------------------------

    # Start from a clean namelist
    cp "$RUNDIR/namelist.forecast" "$RUNDIR/namelist.input"

    # Set starting date

    splitdate $DATESTART YEAR MONTH DAY HOUR
    $NAMELIST --set time_control:start_year  `repeat $YEAR  $NDOMS` $RUNDIR/namelist.input
    $NAMELIST --set time_control:start_month `repeat $MONTH $NDOMS` $RUNDIR/namelist.input
    $NAMELIST --set time_control:start_day   `repeat $DAY   $NDOMS` $RUNDIR/namelist.input
    $NAMELIST --set time_control:start_hour   `repeat $HOUR   $NDOMS` $RUNDIR/namelist.input    
    $NAMELIST --set share:start_date `repeat ${YEAR}-${MONTH}-${DAY}_${HOUR}:00:00 $NDOMS` $WPSDIR/namelist.wps

    # Set ending date
    DATEEND=`date --date "${YEAR}-${MONTH}-${DAY} ${HOUR} hours $CYCLELEN hours" +%F.%H`
    splitdate $DATEEND YEAR MONTH DAY HOUR
    $NAMELIST --set time_control:end_year  `repeat $YEAR  $NDOMS` $RUNDIR/namelist.input
    $NAMELIST --set time_control:end_month `repeat $MONTH $NDOMS` $RUNDIR/namelist.input
    $NAMELIST --set time_control:end_day   `repeat $DAY   $NDOMS` $RUNDIR/namelist.input
    $NAMELIST --set time_control:end_hour   `repeat $HOUR   $NDOMS` $RUNDIR/namelist.input
    $NAMELIST --set share:end_date `repeat ${YEAR}-${MONTH}-${DAY}_${HOUR}:00:00 $NDOMS` $WPSDIR/namelist.wps
}

######################################################################
# Download GFS boundaries
# Arguments:
#     DATE     date to download, can be 'today'
######################################################################
function download_gfs {
    if [ x$1 == "x" ]; then
        when=today
    else
        when="$1"
    fi
    BDATE=`date -d "$when" +'%Y%m%d00'`
    mkdir -p $DATDIR/$BDATE
    $TOOLS/get_gfs.pl data ${BDATE} 0 48 6 all all $DATDIR/$BDATE
}

######################################################################
# Run the standard WRF commands to make input boundaries
# Required env:
#    WPSDIR, DATDIR, RUNDIR
######################################################################
function prepare_boundaries {

    if [[ ! -d "$WPSDIR"  || ! -d "$DATDIR" || ! -d "$RUNDIR" || -z "$DATESTART" ]]; then
        printf "$0 [$LINENO]: One of WPSDIR, DATDIR, RUNDIR, or DATESTART not set. Aborting\n"
        exit -1
    fi;

    # clean start
    rm -f $WPSDIR/GRIBFILE.???
    rm -f $WPSDIR/FILE:????-??-??_??
    rm -f $WPSDIR/PFILE:????-??-??_??
    rm -f $WPSDIR/PRES:????-??-??_??

    rm -f $RUNDIR/prepare_boundaries.log

    # starting from today's run hours 00 to 48:
    BDATE=`date -d "today $DATESTART" +'%Y%m%d00'`
    echo $DATESTART
    #FILES="gfs.t00z.pgrb2.0p25.f000 gfs.t00z.pgrb2.0p25.f006 gfs.t00z.pgrb2.0p25.f012 gfs.t00z.pgrb2.0p25.f018 gfs.t00z.pgrb2.0p25.f024 gfs.t00z.pgrb2.0p25.f030 gfs.t00z.pgrb2.0p25.f036 gfs.t00z.pgrb2.0p25.f042 gfs.t00z.pgrb2.0p25.f048"
    FILES="interim_pl.grib interim_sfc.grib"
    ALL_PRESENT="Yes"
    for f in $FILES; do
        if [ ! -f $DATDIR/$BDATE/$f ]; then
            echo $DATDIR/$BDATE
            echo "Missing: $f"
            ALL_PRESENT="No"
        fi
    done 

    if [ $ALL_PRESENT == "No" ]; then 
        printf "$0 [$LINENO]: Boundaries are missing, download them first\n"
    fi
    # convert to WRF input
    cd "$WPSDIR"
    $WPSDIR/link_grib.csh $DATDIR/$BDATE/  2>&1     >> $RUNDIR/prepare_boundaries.log
    $WPSDIR/ungrib.exe               2>&1 >> $RUNDIR/prepare_boundaries.log
    $WPSDIR/metgrid.exe             2>&1 >> $RUNDIR/prepare_boundaries.log

    # clean up
    rm -f $WPSDIR/GRIBFILE.???
    rm -f $WPSDIR/FILE:????-??-??_??

    # move results to RUNDIR
    mv -f $WPSDIR/met_em.d??.????-??-??_??:??:??.nc $RUNDIR
}

######################################################################
# Copy urban temperature fields TRL TBL TGL, and some surface fields for cycling
# When no date and index is given, try copying form DATESTART - CYCLESTEP
# Note that the index in the netcdf file (CYCLEINDEX) is hardcoded at the start
# of this file
#
# Arguments:
#    CYCLEDATE (optional)
# Required env:
#    RUNDIR, NDOMS
######################################################################
function prepare_cycle {
    if [[ -z "$NDOMS" || ! -d "$RUNDIR" ]]; then
        printf "$0 [$LINENO]: NDOMS or RUNDIR not set. Aborting\n"
        exit -1
    fi
    if [ "previous" == "$1" ]; then
        CYCLEDATE=`date --date "$DATESTART $CYCLESTEP hours ago" +%F`
    else
        CYCLEDATE=$1
    fi
    archivedir $CYCLEDATE ARCDIR

    CYCLEFILE="{ARCDIR}/wrfout_d${d}_${CYCLEDATE}_00:00:00.nc"

    if [ -f "${CYCLEFILE}" ]; then
       for d in `seq -f '%02.0f' 1 $NDOMS`; do
          ncks -C -A -o "${RUNDIR}/wrfinput_d${d}" -v ${URBANFIELDS} -d Time,${CYCLEINDEX[$d]} "${CYCLEFILE}" || echo "Cannot cycle urban $d"
          ncks -C -A -o "${RUNDIR}/wrfinput_d${d}" -v ${CYCLEFIELDS} -d Time,${CYCLEINDEX[$d]} "${CYCLEFILE}" || echo "Cannot cycle soil  $d"
       done
    else
        echo "Cannot find cycle file: $CYCLEFILE"
    fi
}

######################################################################
# Set sea-surface temperature
#
# Arguments:
#    SSTDATE  date to use for SST, defaults to: DATESTART - CYCLESTEP
#
# Required env:
#    RUNDIR, NDOMS
######################################################################
function prepare_sst {
    if [ x$1 == x ]; then
        SSTDATE=`date --date "$DATESTART $CYCLESTEP hours ago" +%F`
    else
        SSTDATE=$1
    fi

    cd $RUNDIR

    for d in 03 04; do
        echo "Domain $d: SSTDATE is $SSTDATE" >> prepare_boundaries.log
        $PREPSST "$SSTDATE" ~/SST/domain_d${d}.grid $RUNDIR/sst_d${d}.nc
        $COPYSST $RUNDIR/sst_d${d}.nc wrfinput_d${d}
        rm sst_d${d}.nc
    done
}

######################################################################
# Prepare WRFDA
#
# Requires:
######################################################################
function wrfda_preprocess {
    if [ x$1 == x ]; then
        OBSDATE=`date --date "$DATESTART $CYCLESTEP hours ago" +%F`
    else
        OBSDATE=$1
    fi
    # split date in $YEAR $MONTH $DAY
    splitdate $OBSDATE YEAR MONTH DAY HOUR
  
    cd $WRFDADIR/var/obsproc
    cp namelist.obsproc.3dvar.wrfvar-tut namelist.obsproc

    # TODO: copy over observation file to $WRFDADIR/var/obsproc
    cp ${OBSDIR}/results.txt ./fort.2
    
    ## modify namelist.obsproc
    # filename observation in LITTLE_R format
    $NAMELIST --set record1:obs_gts_filename "fort.2" namelist.obsproc
    # time window & analysis time
    $NAMELIST --set  record2:time_analysis "${YEAR}-${MONTH}-${DAY}_${HOUR}:00:00" namelist.obsproc
    # mindate
    DATEMIN=`date --date "${YEAR}-${MONTH}-${DAY} ${HOUR} hours 1 hours ago" +%F.%H` # - 1hr
    splitdate $DATEMIN YEAR MONTH DAY HOUR
    $NAMELIST --set  record2:time_window_min "${YEAR}-${MONTH}-${DAY}_${HOUR}:00:00" namelist.obsproc
    DATEMAX=`date --date "${YEAR}-${MONTH}-${DAY} ${HOUR} hours 2 hours" +%F.%H` # + 2hr
    splitdate $DATEMAX YEAR MONTH DAY HOUR
    $NAMELIST --set  record2:time_window_max "${YEAR}-${MONTH}-${DAY}_${HOUR}:00:00" namelist.obsproc
    # get domain information from  "$RUNDIR/namelist.input"
    nesti=$( $NAMELIST --get domains:i_parent_start "$RUNDIR/namelist.input" | sed -e 's/\[//g' -e 's/\]//g' )
    nestj=$( $NAMELIST --get domains:i_parent_start "$RUNDIR/namelist.input" | sed -e 's/\[//g' -e 's/\]//g' )
    esn=$( $NAMELIST --get domains:e_sn "$RUNDIR/namelist.input" | sed -e 's/\[//g' -e 's/\]//g' )
    ewe=$( $NAMELIST --get domains:e_we "$RUNDIR/namelist.input" | sed -e 's/\[//g' -e 's/\]//g' )
    dis=$( $NAMELIST --get domains:dx "$RUNDIR/namelist.input" | sed -e 's/\[//g' -e 's/\]//g'  ) # ?correct variable?
    numc=$( $NAMELIST --get domains:parent_id "$RUNDIR/namelist.input" | sed -e 's/\[//g' -e 's/\]//g'  )

    # write domain information in namelist.obsproc
    $NAMELIST --set record8:nesti "${nesti}" namelist.obsproc
    $NAMELIST --set record8:nestj "${nestj}" namelist.obsproc
    $NAMELIST --set record8:nestix "${ewe}" namelist.obsproc
    $NAMELIST --set record8:nestjx "${esn}" namelist.obsproc
    $NAMELIST --set record8:numc "${numc}" namelist.obsproc
    
    # convert dx to dist in km (divide by 1000) ? divide by 1 for now
    diskm=$( awk '{for(i=1;i<=NF;i++){$i=$i/1}}1' <<< ${dis} | sed -e 's/ /, /g' )
    $NAMELIST --set record8:dis "${diskm}" namelist.obsproc  # grid size in km

    # info on variables: 
    # http://www.nco.ncep.noaa.gov/pmb/codes/nwprod/sorc/wrf_shared.fd/var/obsproc/README.namelist
    # http://www2.mmm.ucar.edu/wrf/OnLineTutorial/Basics/WRF/namelist.input.htm

    # run obsproc.exe
    $WRFDADIR/var/obsproc/obsproc.exe
}

function wrfda_prepare {
    ## make sure we have a clean $WORK_DIR
    if [ -d $WORK_DIR ]; then
      rm -rf $WORK_DIR
    fi
    mkdir $WORK_DIR
    cd $WORK_DIR

    # copy namelist.input
    cp $WRFDADIR/var/test/tutorial/namelist.input .

    ## modify namelist.input
    # variables from obsproc namelist.input 
    tmax=$( $NAMELIST --get record2:time_window_max $WRFDADIR/var/obsproc/namelist.obsproc )
    tana=$( $NAMELIST --get record2:time_analysis $WRFDADIR/var/obsproc/namelist.obsproc )
    tmin=$( $NAMELIST --get record2:time_window_min $WRFDADIR/var/obsproc/namelist.obsproc )
    $NAMELIST --set wrfvar18:analysis_date ${tana} namelist.input
    $NAMELIST --set wrfvar21:time_window_min ${tmin} namelist.input
    $NAMELIST --set wrfvar22:time_window_max ${tmax} namelist.input
    $NAMELIST --set wrfvar7:cv_options 3 namelist.input

    # variables from WRF namelist.input
    for VAR in time_control:start_year time_control:start_month \
        time_control:start_day time_control:start_hour \
        time_control:end_year time_control:end_month time_control:end_day \
        time_control:end_hour \
        domains:e_we domains:e_sn domains:e_vert domains:dx domains:dy \
        physics:mp_physics physics:ra_lw_physics physics:ra_sw_physics \
        physics:radt physics:sf_sfclay_physics physics:sf_surface_physics \
        physics:bl_pbl_physics physics:cu_physics physics:cudt\
        physics:num_soil_layers; do
      VAR_value=$( $NAMELIST --get $VAR "$RUNDIR/namelist.input" )
      case $VAR in physics:num_soil_layers | \
          physics:sf_urban_use_wur_config | physics:sf_urban_init_from_file)
          $NAMELIST --set $VAR "${VAR_value}" namelist.input
      ;;
      *)
          STR_ARRAY=(`echo $VAR_value | sed -e 's/\[//g' -e 's/\]//g' -e 's/,/\n/g'`)
          $NAMELIST --set $VAR "${STR_ARRAY}" namelist.input
        #$NAMELIST --set $VAR "${VAR_value:1:-1}" namelist.input
      esac
    done

    ln -sf $WRFDADIR/run/LANDUSE.TBL .
    # output of obsproc
    ln -sf $WRFDADIR/var/obsproc/obs_gts_${tana}.3DVAR ./ob.ascii 
    ln -sf $WRFDADIR/var/run/be.dat.cv3 $WORK_DIR/be.dat
    ln -sf $WRFDADIR/var/da/da_wrfvar.exe .
}

function wrfda_run {
    cd $WORK_DIR
    # get dynamic domain information from WRF namelist.input
    domains=$( $NAMELIST --get domains:grid_id "$RUNDIR/namelist.input" )
    # loop over domains
#    for domain in ${domains:1:-1}; do
    for domain in 1; do
      # symlink output of real.exe for each domain
      ln -sf $RUNDIR/wrfinput_d0$( echo $domain | tr "," " " ) ./fg
      # set domain specific information in namelist
      for VAR in domains:e_we domains:e_sn domains:e_vert domains:dx domains:dy; do      
        VAR_value=$( $NAMELIST --get $VAR "$RUNDIR/namelist.input" )
        STR_ARRAY=(`echo $VAR_value | sed -e 's/\[//g' -e 's/\]//g' -e 's/,/\n/g'`)
        $NAMELIST --set $VAR ${STR_ARRAY[`expr $domain - 1`]} namelist.input
      done      
      # run da_wrfvar.exe for each domain
      ./da_wrfvar.exe >&! log.wrfda
    done
}

function wrfda_updatebc {
    # function to update lateral boundary conditions
    cd $WORK_DIR
    # copy over parame.in file
    #cp $WRFDADIR/var/test/update_bc/parame.in ./ # use install instead of cp
    cp $TOOLS/parame.in.latbc ./parame.in
    # symlink da_update_bc.exe
    cp $WRFDADIR/var/da/da_update_bc.exe ./
    # copy over wrf_bdy file
    cp ${RUNDIR}/wrfbdy_d01 ./
    # get dynamic domain information from WRF namelist.input
    #domains=$( $NAMELIST --get domains:grid_id "$RUNDIR/namelist.input" )
    # update lateral boundary conditions only needed for outer domain
    #$NAMELIST --set control_param:wrf_input "${RUNDIR}/wrfinput_d01" parame.in
    # run da_update_bc
    ./da_update_bc.exe
    # copy over lateral boundary conditions
    cp wrfbdy_d01 ${RUNDIR}/wrfbdy_d01    
}

function wrfda_updatebc_lowbc {
    if [ x$1 == x ]; then
        OBSDATE=`date --date "$DATESTART $CYCLESTEP hours ago" +%F`
    else
        OBSDATE=$1
    fi
    # split date in $YEAR $MONTH $DAY
    splitdate $OBSDATE YEAR MONTH DAY HOUR
    
    # function to update low boundary conditions
    if [ -d $WORK_DIR ]; then
      rm -rf $WORK_DIR
    fi
    mkdir $WORK_DIR
    cd $WORK_DIR
    # copy over parame.in file
    cp ${TOOLS}/parame.in.lowbc ${WORK_DIR}/parame.in
    # symlink da_update_bc.exe
    cp $WRFDADIR/var/da/da_update_bc.exe ./
    # copy over wrf_bdy file
    cp ${RUNDIR}/wrfbdy_d01 ./
    # copy over wrvar_input
    # get dynamic domain information from WRF namelist.input
    domains=$( $NAMELIST --get domains:grid_id "$RUNDIR/namelist.input" )
    # update lateral boundary conditions only needed for outer domain
    $NAMELIST --set control_param:wrf_input "${RUNDIR}/wrfinput_d01" parame.in
    $NAMELIST --set control_param:da_file "./fg" parame.in
    sed -i 's/low_bdy_only = .false./low_bdy_only = .true/' parame.in
    sed -i 's/update_lsm = .true./update_lsm = .false./' parame.in
    #$NAMELIST --set control_param:low_bdy_only 'true' parame.in
    #$NAMELIST --set control_param:update_lsm "false" parame.in 

    # get dynamic domain information from WRF namelist.input
    domains=$( $NAMELIST --get domains:grid_id "$RUNDIR/namelist.input" )
    # loop over domains
    echo $domains
    for domain in 1 2 3; do
      cp ${RUNDIR}/wrfvar_input_d0${domain}_${YEAR}-${MONTH}-${DAY}_${HOUR}:00:00 ./fg
      # set domain
      $NAMELIST --set control_param:domain_id ${domain} parame.in
      # set wrf_input
      $NAMELIST --set control_param:wrf_input ${RUNDIR}'/wrfinput_d0'${domain} parame.in
      # set wrfoutput file for domain
      $NAMELIST --set control_param:da_file './fg' parame.in
      #run da_update_bc
      ./da_update_bc.exe
      # copy wrfoutput to wrfinput
      cp ${WORK_DIR}/fg ${RUNDIR}/wrfinput_d0${domain}
    done
}

######################################################################
# Run real.exe
#
# Requires:
#    RUNDIR
######################################################################
function run_real {
    if [ ! -d "$RUNDIR" ]; then
        printf "$0 [$LINENO]: RUNDIR not set. Aborting\n"
        exit -1
    fi
    cd $RUNDIR 
    #sbatch job.real
    ./real.exe
}

######################################################################
# Run wrf.exe
#
# Requires:
#    RUNDIR
######################################################################
function run_wrf {
    if [ ! -d "$RUNDIR" ]; then
        printf "$0 [$LINENO]: RUNDIR not set. Aborting\n"
        exit -1
    fi
    cd $RUNDIR 
    #sbatch job.wrf
    ./wrf.exe
}


######################################################################
# Zip WRF timeseries files
#
#    station.d??.* -> station.d??.zip
#
# Required env:
#    NDOMS, STATIONS, RUNDIR
######################################################################
function zip_ts {
    if [[ -z "$NDOMS" || -z "$RUNDIR" || -z "$STATIONS" ]]; then
        printf "$0 [$LINENO]: NDOMS, RUNDIR, or STATIONS not set, aborting\n"
        exit 1;
    fi

    OLDPWD=$PWD
    cd $RUNDIR

    for d in `seq -f '%02.0f' 1 $NDOMS`; do
        for s in $STATIONS; do

            # if there are ts files for this station and domain to process,
            FILES=`ls_tslist $s $d`
            if [ ! -z "$FILES" ]; then

                ZIPPED=$RUNDIR/${s}.d${d}.zip
                WORKING=$RUNDIR/working.${s}.d${d}.zip

                # and there is no zip file yet
                if [ ! -f "$ZIPPED" ]; then

                    # ... remove old archive to be sure,
                    rm -f "$WORKING"

                    # ... zip,
                    zip "$WORKING" $FILES > /dev/null

                    # ... clean up
                    rm -f $FILES

                    # ... and copy archive
                    mv "$WORKING" "$ZIPPED"
                fi
            fi
            
        done
    done

    cd $OLDPWD
}

######################################################################
# Zip WRF log files, and remove unzipped logs on success
#
#     $LOGS: tslist namelist.input prepare_boundaries.log rsl.out|rsl.out.0000  
#
# FIXME: deps
######################################################################
function zip_log {

    OLDPWD=$PWD
    cd $RUNDIR

    FILES="tslist namelist.input prepare_boundaries.log"
    CLEANUP="prepare_boundaries.log"

    # output filename depends on parallel / serial run
    if [ -f rsl.out.0000 ]; then
        RSL="rsl.out.0000"
        RSLE="rsl.error.0000"
    elif [ -f rsl.out ]; then
        RSL="rsl.out"
        RSLE="rsl.error"
    else
        printf "$0 [$LINENO]: Can't find rsl.out or rsl.out.0000, aborting\n"
        exit 1
    fi
    FILES="$RSL $RSLE $FILES"
    CLEANUP="$RSL $RSLE $CLEANUP"

    # check if the log files exist
    for f in $FILES; do
        if [ ! -f $f ]; then
            printf "$0 [$LINENO]: Can't find %s, aborting\n", "$f"
            exit 1
        fi
    done

    # If there is no zip file yet
    LOGS="logs_${DATESTART}.zip"
    if [ ! -f "$LOGS" ]; then

        WORKING="${LOGS}.working"

        # ... remove old files,
        rm -rf "$WORKING"

        # ... zip,
        zip "$WORKING" $FILES > /dev/null || (
            printf "$0 [$LINENO]: Can't zip log files %s, aborting\n", "$FILES"
            exit 1
        )

        # ... and copy archive
        mv "$WORKING" "$LOGS"

        rm -f $CLEANUP
    fi

    cd $OLDPWD
}

######################################################################
# Zip WRF netCDF output by converting to netCDF4:
#
#      wrfout* -> wrfout*.nc
#
# Assumes:
#    CWD is the wrf 'run' directory    
# Required env:
#    NDOMS, DATESTART
######################################################################
function zip_netcdf {
    if [[ -z "$NDOMS" || -z "$DATESTART" ]]; then
        printf "$0 [$LINENO]: NDOMS or DATESTART not set, aborting\n"
        exit 1;
    fi

    for d in `seq -f '%02.0f' 1 $NDOMS`; do
        NCDF3="wrfout_d${d}_${DATESTART}_00:00:00"
        TMPFL="wrfout_d${d}_${DATESTART}.working"
        NCDF4="wrfout_d${d}_${DATESTART}_00:00:00.nc" 

        # if the output file exists
        if [ -f "${NCDF3}" ]; then

            # .. but the netCDF4 version does not exist
            if [ ! -f "${NCDF4}" ]; then

                # convert the file from netCDF3 to netCDF4
                $NC3TONC4 -o "${NCDF3}" "${TMPFL}" && mv -f "${TMPFL}" "${NCDF4}" > /dev/null
            fi

            # test if all went ok
            $NCDUMP -h "${NCDF3}" > "${NCDF3}.dump" 
            $NCDUMP -h "${NCDF4}" > "${NCDF4}.dump" 
            cmp "${NCDF3}.dump" "${NCDF4}.dump" || (
                printf "$0 [$LINENO]: Error in converting ${NCDF3}"
                exit 1 
            )

            # clean up
            rm -f "${NCDF3}" "${NCDF3}.dump" "${NCDF4}.dump" "${TMPFL}"
        fi
    done
}

######################################################################
# Make plots using NCL
# Plots are made from the archived NetCDF4 files,
# and placed in the archive directory
######################################################################
function plot_surface {
    if [ x$1 == "x" ]; then
        when=$DATESTART
    else
        when="$1"
    fi

    # Check archive status
    archivedir $when ARCHIVE

    for d in `seq -f '%02.0f' 1 $NDOMS`; do
        NCDF4="wrfout_d${d}_${when}_00:00:00.nc" 
        ncl $TOOLS/wrf_Surface2.ncl inputfile=\"$ARCHIVE/$NCDF4\" outputfile=\"$ARCHIVE/surface_$d.png\"
    done
}


# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
#                                           M A I N
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
log "$1 $2 $3"

# dont do parsing or processing for for those tasks
# but immediately execute and exit
case "$1" in
    download_gfs)
        download_gfs "$2"
        exit 0
        ;;
    help | -h | -? )
        help
        exit 0
    ;;
esac

# parse namelist file in the run directory
forecastinit

# extract options and their arguments into variables.
case "$1" in
    prepare)
        case "$2" in
            "all")        prepare_date next ; prepare_boundaries ; prepare_cycle previous ; prepare_sst ;;
            "date")       prepare_date $3 ;;
            "boundaries") prepare_boundaries ;;
            "cycle")      prepare_cycle $3 ;;
            "sst")        prepare_sst $3 ;;
        esac
    ;;
    run) 
        case "$2" in
            "real") run_real ;;
            "wrf")  run_wrf  ;;
        esac
    ;;
    wrfda)
        case "$2" in
            "preprocess") wrfda_preprocess  $3 ;;
            "prepare") wrfda_prepare $3 ;;
            "run") wrfda_run ;;
            "updatebc") wrfda_updatebc ;;
            "updatebc_lowbc") wrfda_updatebc_lowbc $3;;
        esac
    ;;
    zip)
        case "$2" in
            "all")     zip_netcdf ; zip_ts ; zip_log ;;
            "netcdf")  zip_netcdf ;;
            "ts")      zip_ts ;;
            "log")     zip_log ;;
            *)         echo "Internal error!" ; exit 1 ;;
        esac
    ;;
    clean)
        case "$2" in
            "all")     clean_input ; clean_output ;;
            "input")   clean_input ;;
            "output")  clean_output ;;
            *)         echo "Internal error!" ; exit 1 ;;
            esac
    ;;
    status) status ; exit
    ;;
    plot)
        case "$2" in
            "surface") plot_surface $3 ;;
            *)          echo "Plot not defined" ; exit 1 ;;
        esac
    ;;
    archive)
        case "$2" in
            "all")      archive_ts ; archive_netcdf ; archive_log ;;
            "ts")       archive_ts ;;
            "netcdf")   archive_netcdf ;;
            "log")      archive_log ;;
            *)         echo "Internal error!" ; exit 1 ;;
        esac ;;
    *)
        help
        printf "$0 [$LINENO]: Please indicate an action.\n"
        exit 1
    ;;
esac 

log "$1 $2 $3 - SUCCESS"
