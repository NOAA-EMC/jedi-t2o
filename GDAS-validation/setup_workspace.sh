#!/bin/bash
# setup_workspace.sh
# this script:
# - creates working directory
# - clones global-workflow
# - clones GDASApp
# - clones GSI
# - builds GDASApp + GSI
# - creates an experiment for a specified cycle/period
# - links input background files

usage() {
  set +x
  echo
  echo "Usage: $0 [-c] [-b] [-s]"
  echo
  echo "  -c  clone necessary repositories"
  echo "  -b  build GDASApp and GSI"
  echo "  -s  setup default experiment"
  echo "  -h  display this message and quit"
  echo
  exit 1
}

clone=NO
build=NO
setup=NO

while getopts "cbsh" opt; do
  case $opt in
    c)
      clone=YES
      ;;
    b)
      build=YES
      ;;
    s)
      setup=YES
      ;;
    h|\?|:)
      usage
      ;;
  esac
done

#--------------- User modified options below -----------------
EXPNAME="gdas_eval_satwind"
machine=${machine:-orion}
workdir=""
ICSDir=""

#-------------- User should not modify below here ----------
mydir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

#--- machine dependent paths
if [ $machine = orion ]; then
  workdir=${workdir:-/work2/noaa/da/$LOGNAME/gdas-validation}
  ICSDir=${ICSDir:-/work2/noaa/da/cmartin/UFO_eval/data/para/output_ufo_eval_aug2021}
elif [ $machine = hera ]; then
  workdir=${workdir:-/scratch1/NCEPDEV/stmp2/$LOGNAME/gdas-validation}
  ICSDir=${ICSDir:-/scratch1/NCEPDEV/da/Cory.R.Martin/UFO_eval/data/para/output_ufo_eval_aug2021}
else
   echo "Machine " $machine "not found"
   exit 1
fi

#--- create working directory
mkdir -p $workdir

#--- clone repositories ---
if [ $clone = "YES" ]; then
  cd $workdir
  echo "Cloning global-workflow at $workdir/global-workflow"
  git clone --recursive https://github.com/noaa-emc/global-workflow.git
  echo "Checkout GSI feature/gdas-validation"
  cd $workdir/global-workflow/sorc/gsi_enkf.fd
  git checkout feature/gdas-validation
  git submodule sync
  git submodule update
fi

#--- build GDASApp and GSI ---
if [ $build = "YES" ]; then
  logs_dir="${workdir}/global-workflow/sorc/logs"
  if [[ ! -d "${logs_dir}" ]]; then
      echo "Create logs folder, ${logs_dir}"
      mkdir "${logs_dir}" || exit 1
  fi
  sorc_dir="${workdir}/global-workflow/sorc"
  cd ${sorc_dir}
  echo "Building GSI in ${sorc_dir}/gsi_enkf.fd"
  echo "Build begin: `date`"
  echo "Build log: ${logs_dir}/build_gsi_enkf.log"
  ./build_gsi_enkf.sh > ${logs_dir}/build_gsi_enkf.log 2>&1
  err=0
  err=$?
  if (( err != 0 )); then
      echo "GSI build abnormal exit $err.  Check ${logs_dir}/build_gsi_enkf.log"
      exit $err
  fi
  echo "Build complete: `date`"
  echo "Building GDASApp in ${sorc_dir}/gdas.cd"
  echo "Build begin: `date`"
  echo "Build log: ${logs_dir}/build_gdas.log"
  ./build_gdas.sh > ${logs_dir}/build_gdas.log 2>&1
  err=$?
  if (( err != 0 )); then
      echo "GDASApp build abnormal exit $err.  Check ${logs_dir}/build_gdas.log"
      exit $err
  fi
  echo "Build complete: `date`"
  echo "Link workflow"
  ${sorc_dir}/link_workflow.sh
fi

#--- setup default experiment within workflow
if [ $setup = "YES" ]; then
  # copy workflow default config files
  echo "Staging configuration files"
  mkdir -p $workdir/gdas_config
  cp -rf $workdir/global-workflow/parm/config/gfs/* $workdir/gdas_config/.
  # copy files that need to be overwritted from default
  cp -rf $mydir/gdas_config/* $workdir/gdas_config/.
  # copy templated yamls that need to be overwritten for JEDI gdas-validation
  cp -rf $mydir/gdas_config/jcb-base.yaml.j2  $workdir/global-workflow/sorc/gdas.cd/parm/atm/
  cp -rf $mydir/gdas_config/3dvar_outer_loop_1.yaml.j2 $workdir/global-workflow/sorc/gdas.cd/parm/jcb-gdas/model/atmosphere/
  # copy scripts that need to be overwritten for GSI gdas-validation
  cp -rf $mydir/gdas_config/exglobal_atmos_analysis.sh $workdir/global-workflow/scripts/

  HOMEgfs=$workdir/global-workflow
  source $workdir/global-workflow/ush/module-setup.sh
  module use $workdir/global-workflow/modulefiles
  module load module_gwsetup.${MACHINE_ID}
  cd $workdir/global-workflow/workflow
  # setup_expt variables
  IDATE=2021080100
  EDATE=2021080200
  RESDETATMOS=768
  CDUMP=gdas
  PSLOT=${EXPNAME:-"gdas_eval"}
  CONFIGDIR=$workdir/gdas_config
  COMROOT=$workdir/comroot
  EXPDIR=$workdir/expdir
  ICSDIR=$ICSDir/$IDATE
  rm -rf $EXPDIR/${PSLOT}*
  rm -rf $COMROOT/${PSLOT}*
  # make two experiments, one GSI, one JEDI
  set -x
  ./setup_expt.py gfs cycled --idate $IDATE --edate $EDATE --app ATM --start warm --gfs_cyc 0 \
    --resdetatmos $RESDETATMOS  --nens 0 --cdump $CDUMP --pslot ${PSLOT}_GSI --configdir $CONFIGDIR \
    --comroot $COMROOT --expdir $EXPDIR --yaml $CONFIGDIR/config_gsi.yaml --icsdir $ICSDIR
  ./setup_expt.py gfs cycled --idate $IDATE --edate $EDATE --app ATM --start warm --gfs_cyc 0 \
    --resdetatmos $RESDETATMOS  --nens 0 --cdump $CDUMP --pslot ${PSLOT}_JEDI --configdir $CONFIGDIR \
    --comroot $COMROOT --expdir $EXPDIR --yaml $CONFIGDIR/config_jedi.yaml --icsdir $ICSDIR
  set +x
  # setup the two XMLs
  ./setup_xml.py $EXPDIR/${PSLOT}_GSI
  ./setup_xml.py $EXPDIR/${PSLOT}_JEDI
  # link run_job script to both EXPDIR
  ln -fs $mydir/run_job.sh $EXPDIR/${PSLOT}_GSI/run_job.sh
  ln -fs $mydir/run_job.sh $EXPDIR/${PSLOT}_JEDI/run_job.sh
  # copy run_job configuration to each EXPDIR
  cp $mydir/config_example_gsi.sh $EXPDIR/${PSLOT}_GSI/config_gsi.sh
  cp $mydir/config_example_jedi.sh $EXPDIR/${PSLOT}_JEDI/config_jedi.sh
  # link backgrounds
  # the ICSDIR links the restarts, we also need the GSI inputs
  PDY=${IDATE:0:8}
  cyc=${IDATE:8:2}
  FDATE=$(date --utc +%Y%m%d%H -d "${PDY} ${cyc} + 6 hours")
  sed -i "s/${FDATE}/${IDATE}/g" $EXPDIR/${PSLOT}_GSI/${PSLOT}_GSI.xml
  sed -i "s/${FDATE}/${IDATE}/g" $EXPDIR/${PSLOT}_JEDI/${PSLOT}_JEDI.xml
  GDATE=$(date --utc +%Y%m%d%H -d "${PDY} ${cyc} - 6 hours")
  gPDY=${GDATE:0:8}
  gcyc=${GDATE:8:2}
  mkdir -p ${COMROOT}/${PSLOT}_GSI/gdas.${gPDY}/${gcyc}/model_data/atmos/history/
  mkdir -p ${COMROOT}/${PSLOT}_GSI/gdas.${gPDY}/${gcyc}/analysis/atmos/
  # below assumes the old com structure for the input data
  echo "Linking backgrounds to ${COMROOT}/${PSLOT}_GSI/"
  # only f006, no FGAT in JEDI
  #ln -sf $ICSDIR/gdas.${gPDY}/${gcyc}/atmos/gdas*atmf* ${COMROOT}/${PSLOT}_GSI/gdas.${gPDY}/${gcyc}/model_data/atmos/history/.
  #ln -sf $ICSDIR/gdas.${gPDY}/${gcyc}/atmos/gdas*sfcf* ${COMROOT}/${PSLOT}_GSI/gdas.${gPDY}/${gcyc}/model_data/atmos/history/.
  ln -sf $ICSDIR/gdas.${gPDY}/${gcyc}/atmos/gdas*atmf006* ${COMROOT}/${PSLOT}_GSI/gdas.${gPDY}/${gcyc}/model_data/atmos/history/.
  ln -sf $ICSDIR/gdas.${gPDY}/${gcyc}/atmos/gdas*sfcf006* ${COMROOT}/${PSLOT}_GSI/gdas.${gPDY}/${gcyc}/model_data/atmos/history/.
  ln -sf $ICSDIR/gdas.${gPDY}/${gcyc}/atmos/gdas*abias* ${COMROOT}/${PSLOT}_GSI/gdas.${gPDY}/${gcyc}/analysis/atmos/.
  # this is so the gdasatmanlfinal job completes successfully
  sed -e '/FileHandler(inc_copy/s/^/#/g' -i $workdir/global-workflow/ush/python/pygfs/task/atm_analysis.py
fi
